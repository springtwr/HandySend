/**
 * WebDownloadAdapter.ets — Web 分享下载适配器
 *
 * 一次浏览器下载突发 = 一个统一会话（burst 模型）：协议层的 IP 授权会话由
 * 适配器内部维护（同 IP 终态后再次下载创建新会话）。终态判定采用策略：
 * - 静默窗口：全部已知文件完成后，静默期内无新文件/进度即判定成功终态；
 * - 接受后无活动超时：确认后长时间无任何文件活动则终结该会话。
 * 对端以客户端 IP 描述符兜底（网页来源由来源徽标表达，不重复「网页客户端」前缀）。
 */

import {
  SessionCapabilities,
  SessionDataFlow,
  SessionDisplayDescriptor,
  SessionFileDescriptor,
  SessionFileStage,
  SessionInitiator,
  SessionStage,
  TransferSession,
  isTerminalStage
} from '../../../model/transfer/TransferSession';
import { getLogger } from '../../../utils/Logger';
import { LogDomains } from '../../../common/LogDomains';
import { getMimeForFileName, isTextFile } from '../../../utils/MimeUtils';
import { readTextOfLocation } from '../../../utils/FileTextUtil';
import {
  appendFiles,
  createSession,
  finish,
  getSession,
  markFileStage,
  setStage,
  setStageProgress,
  updateFileProgress,
  updateSessionFilePath
} from '../TransferSessionRegistry';
import { SessionAdapter, emptyDisplayDescriptor, registerAdapter } from './SessionAdapter';

export const WEB_DOWNLOAD_KEY: string = 'web-download';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionAdapter', '协议适配');

// 静默窗口（毫秒）：全部文件完成后无新活动即判定成功终态
const WEB_DOWNLOAD_QUIET_MS: number = 3000;
// 待确认超时（毫秒）：无人应答即终结会话，并让浏览器收到「等待确认超时」
const PENDING_CONFIRM_TIMEOUT_MS: number = 60000;
// 已授权但对方尚未请求任何文件（毫秒）：对方可能只是先打开了页面，
// 留出阅读与思考的时间，超时按「对方未下载」收尾而不是判失败
const WAIT_FIRST_FILE_TIMEOUT_MS: number = 120000;
// 传输中无活动超时（毫秒）：已开始下载后长时间无数据则按失败终结
const ACCEPT_IDLE_TIMEOUT_MS: number = 30000;

interface KnownFile {
  size: number
  done: boolean
}

interface BurstContext {
  unifiedId: string
  ip: string
  knownFiles: Map<string, KnownFile>
  quietTimer: number
  idleTimer: number
}

// 当前活跃突发（按 IP 归属；同 IP 终态后再次请求创建新突发）
const bursts: Map<string, BurstContext> = new Map();
let burstSeq: number = 0;

let acceptInvoker: ((ip: string) => void) | undefined = undefined;
let declineInvoker: ((ip: string) => void) | undefined = undefined;
// 待确认超时：通知原生层结束决策通道，使浏览器收到 408 而非无限等待
let expireInvoker: ((ip: string) => void) | undefined = undefined;

export function setWebDownloadInvokers(
  accept: (ip: string) => void,
  decline: (ip: string) => void,
  expire?: (ip: string) => void): void {
  acceptInvoker = accept;
  declineInvoker = decline;
  expireInvoker = expire;
}

function capabilities(): SessionCapabilities {
  return {
    canCancel: false,
    canRetry: false,
    needsConfirm: true,
    hasByteProgress: true,
    canSaveToGallery: false,
    hasVerify: false
  };
}

function clearTimers(ctx: BurstContext): void {
  if (ctx.quietTimer >= 0) {
    clearTimeout(ctx.quietTimer);
    ctx.quietTimer = -1;
  }
  if (ctx.idleTimer >= 0) {
    clearTimeout(ctx.idleTimer);
    ctx.idleTimer = -1;
  }
}

function allFilesDone(ctx: BurstContext): boolean {
  let known: number = 0;
  let done: number = 0;
  ctx.knownFiles.forEach((file: KnownFile) => {
    known++;
    if (file.done) {
      done++;
    }
  });
  return known > 0 && done === known;
}

/** 把挂载清单中从未开始下载的文件标记为已取消（成功终态只补齐真正发生过的文件）。 */
function markUnstartedFilesCancelled(ctx: BurstContext): void {
  let session = getSession(ctx.unifiedId);
  if (session === undefined) {
    return;
  }
  for (let i = 0; i < session.files.length; i++) {
    let file = session.files[i];
    if (ctx.knownFiles.get(file.fileId) === undefined && file.bytesSent === 0) {
      markFileStage(ctx.unifiedId, file.fileId, SessionFileStage.cancelled);
    }
  }
}

/** 安排静默窗口判定：窗口结束且文件全部完成则成功终态。 */
function scheduleQuietCheck(ctx: BurstContext): void {
  if (ctx.quietTimer >= 0) {
    clearTimeout(ctx.quietTimer);
  }
  ctx.quietTimer = setTimeout(() => {
    ctx.quietTimer = -1;
    let session = getSession(ctx.unifiedId);
    if (session === undefined) {
      return;
    }
    if (allFilesDone(ctx)) {
      // 挂载清单里未开始下载的文件按「未发生」收口，避免成功终态把它们标成已完成
      markUnstartedFilesCancelled(ctx);
      finish(ctx.unifiedId, SessionStage.succeeded);
      bursts.delete(ctx.ip);
    }
  }, WEB_DOWNLOAD_QUIET_MS);
}

/**
 * 安排无活动超时，窗口按当前阶段取：
 * - 待确认：等用户应答（用户可能不在应用内）；
 * - 已授权但对方还没请求任何文件：等对方开始下载；
 * - 传输中：等对端继续产生数据。
 *
 * 超时终态按「是否开始过下载」区分：一直没开始的按取消收尾（这次分享没被取用），
 * 已经开始后又没了数据的才按失败处理——把「对方没点下载」判成失败是错误归因。
 */
function scheduleIdleTimeout(ctx: BurstContext): void {
  if (ctx.idleTimer >= 0) {
    clearTimeout(ctx.idleTimer);
  }
  let session = getSession(ctx.unifiedId);
  let pending: boolean = session === undefined || session.stage === SessionStage.awaitingConfirmation;
  let notStarted: boolean = !pending && ctx.knownFiles.size === 0;
  let delay: number = pending ? PENDING_CONFIRM_TIMEOUT_MS :
    (notStarted ? WAIT_FIRST_FILE_TIMEOUT_MS : ACCEPT_IDLE_TIMEOUT_MS);
  ctx.idleTimer = setTimeout(() => {
    ctx.idleTimer = -1;
    let current = getSession(ctx.unifiedId);
    if (current === undefined) {
      return;
    }
    if (current.stage === SessionStage.awaitingConfirmation) {
      logger.debug('Web 下载待确认超时 ip=' + ctx.ip);
      // 先结束原生侧决策通道：浏览器据此提示「等待确认超时」，而不是一直转圈
      if (expireInvoker !== undefined) {
        expireInvoker(ctx.ip);
      }
      finish(ctx.unifiedId, SessionStage.cancelled, '待确认超时', 'pending_timeout');
    } else if (ctx.knownFiles.size === 0) {
      // 已授权但对方始终没有请求任何文件：不是传输失败，是这次分享没被取用
      logger.debug('Web 下载等待对方开始超时 ip=' + ctx.ip);
      finish(ctx.unifiedId, SessionStage.cancelled, '对方未下载任何文件', 'peer_no_download');
    } else {
      logger.debug('Web 下载空闲超时 ip=' + ctx.ip);
      finish(ctx.unifiedId, SessionStage.failed, '对端长时间无数据', 'peer_idle');
    }
    bursts.delete(ctx.ip);
  }, delay);
}

// 会话文本预览缓存（统一会话标识 → 文本内容）：进度刷新期间避免重复读盘。
// 读取结果按会话缓存（含读取失败时的空串，避免反复读盘）；文件集变化或本地位置
// 回填时失效对应缓存，使位置就绪后能重新读取。
const textPreviewCache: Map<string, string> = new Map();

/**
 * 解析会话文本预览内容：会话恰好包含一个文本类文件且其本地内容位置可读时返回内容，
 * 否则返回空串（不声明支持文本预览，按不可用降级）。读取结果按会话缓存。
 */
function resolveTextPreview(session: TransferSession): string {
  let cached: string | undefined = textPreviewCache.get(session.id);
  if (cached !== undefined) {
    return cached;
  }
  if (session.files.length !== 1) {
    return '';
  }
  let file = session.files[0];
  if (!isTextFile(file.fileType, file.fileName) || file.path.length === 0) {
    return '';
  }
  let text: string = readTextOfLocation(file.path) ?? '';
  textPreviewCache.set(session.id, text);
  return text;
}

/** 以真实文件名回填已有会话文件：名称变化时同步更新名称与派生 MIME。 */
function backfillFileMeta(unifiedId: string, fileId: string, fileName: string): void {
  let session = getSession(unifiedId);
  if (session === undefined) {
    return;
  }
  for (let i = 0; i < session.files.length; i++) {
    let f = session.files[i];
    if (f.fileId === fileId) {
      if (f.fileName !== fileName) {
        f.fileName = fileName;
        f.fileType = getMimeForFileName(fileName);
      }
      return;
    }
  }
}

/**
 * 浏览器下载请求到达：创建（或复用）突发会话。
 *
 * `offeredFiles` 为本次挂载可供下载的文件清单：会话创建即登记，
 * 使「新的传输请求」弹窗与详情页在浏览器尚未开始下载时就有完整的文件列表；
 * 实际开始下载的文件按事件更新进度，未开始的条目由终态补齐。
 * @returns 统一会话标识
 */
export function beginWebDownloadBurst(ip: string, needsConfirm: boolean,
  offeredFiles: Array<SessionFileDescriptor> = []): string {
  let existing = bursts.get(ip);
  if (existing !== undefined) {
    let session = getSession(existing.unifiedId);
    // 与全局终态口径一致（isTerminalStage）：含 partiallyFailed，
    // 手写比较曾漏掉它导致部分失败突发被错误复用
    if (session !== undefined && !isTerminalStage(session.stage)) {
      return existing.unifiedId;
    }
    clearTimers(existing);
  }
  burstSeq++;
  // 协议层只有「按客户端 IP 的授权会话」，无会话标识概念，故协议会话 ID 置空；
  // 内部突发身份仅保留在适配器内，不作为协议会话 ID。
  let session = createSession({
    protocolKey: WEB_DOWNLOAD_KEY,
    protocolSessionId: '',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.remote,
    peer: {
      displayName: ip,
      ip: ip,
      deviceType: 'web',
      badges: []
    },
    files: offeredFiles,
    capabilities: capabilities(),
    stage: needsConfirm ? SessionStage.awaitingConfirmation : SessionStage.active
  });
  let ctx: BurstContext = {
    unifiedId: session.id,
    ip: ip,
    knownFiles: new Map<string, KnownFile>(),
    quietTimer: -1,
    idleTimer: -1
  };
  bursts.set(ip, ctx);
  // 待确认与已接受阶段均安排无活动超时（前者无人处理、后者对端无数据时终结）
  scheduleIdleTimeout(ctx);
  return session.id;
}

/** 会话内是否已登记该文件（挂载清单在创建时即登记了全部可下载文件）。 */
function sessionHasFile(sessionId: string, fileId: string): boolean {
  let session = getSession(sessionId);
  if (session === undefined) {
    return false;
  }
  for (let i = 0; i < session.files.length; i++) {
    if (session.files[i].fileId === fileId) {
      return true;
    }
  }
  return false;
}

function resolveCtx(ip: string): BurstContext | undefined {
  return bursts.get(ip);
}

/**
 * 文件下载开始/完成事件：按真实文件名登记文件（推导类型、记录本地内容位置），
 * 并重置静默与活动定时器。
 * @param localPath 分享源文件的本地内容位置（可选）：供详情页文本内容预览读取
 */
export function handleWebFileDownload(ip: string, fileId: string, fileName: string, size: number,
  localPath?: string): void {
  let ctx = resolveCtx(ip);
  if (ctx === undefined) {
    // 等待窗口已过（会话按「对方未下载」收尾）后对方才开始下载：
    // 按一次新的下载重新建会话，使进度仍然可见
    beginWebDownloadBurst(ip, false, []);
    ctx = resolveCtx(ip);
    if (ctx === undefined) {
      return;
    }
  }
  if (ctx.knownFiles.size === 0) {
    // 首个文件到达：等待态结束，行内改按字节进度展示
    setStageProgress(ctx.unifiedId, '');
  }
  let realName: string = fileName.length > 0 ? fileName : fileId;
  let existing = ctx.knownFiles.get(fileId);
  if (existing === undefined) {
    // 挂载清单已在创建时登记同一文件：不重复追加，仅按事件回填本地位置
    if (sessionHasFile(ctx.unifiedId, fileId)) {
      ctx.knownFiles.set(fileId, { size: size, done: size <= 0 });
      if (size > 0) {
        // 以事件携带的真实大小校正登记值，保证进度分母与内容一致
        updateFileProgress(ctx.unifiedId, fileId, 0, size);
      }
      if (localPath !== undefined && localPath.length > 0) {
        updateSessionFilePath(ctx.unifiedId, fileId, localPath);
        textPreviewCache.delete(ctx.unifiedId);
      }
      scheduleIdleTimeout(ctx);
      scheduleQuietCheck(ctx);
      return;
    }
    let descriptor: SessionFileDescriptor = {
      fileId: fileId,
      fileName: realName,
      fileType: getMimeForFileName(realName),
      totalBytes: size
    };
    if (localPath !== undefined && localPath.length > 0) {
      descriptor.path = localPath;
    }
    appendFiles(ctx.unifiedId, [descriptor]);
    let record: KnownFile = { size: size, done: size <= 0 };
    ctx.knownFiles.set(fileId, record);
    // 文件集变化可能改变「单文本文件」判定：失效该会话的旧预览缓存
    textPreviewCache.delete(ctx.unifiedId);
  } else {
    if (size > 0) {
      existing.size = size;
    }
    // 已登记条目：事件携带真实文件名时回填名称与类型
    backfillFileMeta(ctx.unifiedId, fileId, realName);
    // 本地内容位置晚于登记到达时回填路径，供文本预览读取；同时失效旧预览缓存，
    // 使位置就绪后重新读取（首次登记即带位置的情形不走到这里）
    if (localPath !== undefined && localPath.length > 0) {
      updateSessionFilePath(ctx.unifiedId, fileId, localPath);
      textPreviewCache.delete(ctx.unifiedId);
    }
  }
  // 有文件活动即重排无活动超时：否则首个事件后守卫失效，
  // 对端中途断连时会话只能靠看门狗兜底
  scheduleIdleTimeout(ctx);
  scheduleQuietCheck(ctx);
}

/** 字节级进度：更新会话文件进度，文件完成即标记。 */
export function handleWebDownloadProgress(ip: string, fileId: string, sentBytes: number,
  totalBytes: number): void {
  let ctx = resolveCtx(ip);
  if (ctx === undefined) {
    return;
  }
  // 总大小缺失时仍推进已传字节：分母沿用挂载清单登记的大小，避免整段进度不更新
  updateFileProgress(ctx.unifiedId, fileId, sentBytes, totalBytes);
  let record = ctx.knownFiles.get(fileId);
  if (record === undefined) {
    ctx.knownFiles.set(fileId, { size: totalBytes, done: totalBytes > 0 && sentBytes >= totalBytes });
  } else if (totalBytes > 0 && sentBytes >= totalBytes) {
    record.done = true;
  }
  // 有字节进度即重排无活动超时（理由同 handleWebFileDownload）
  scheduleIdleTimeout(ctx);
  scheduleQuietCheck(ctx);
}

/** 确认接受：经注册表推进为进行中（补记 confirmed/started 时间线），并安排接受后无活动超时。 */
export function markWebDownloadAccepted(ip: string): void {
  let ctx = resolveCtx(ip);
  if (ctx === undefined) {
    return;
  }
  let session = getSession(ctx.unifiedId);
  // 幂等：仅待确认会话经注册表推进；确认流程已由注册表推进时不重复补记时间线
  if (session !== undefined && session.stage === SessionStage.awaitingConfirmation) {
    setStage(ctx.unifiedId, SessionStage.active);
    // 确认只代表放行，对方可能还没点下载：以阶段文案表达等待，
    // 不显示 0% 进度条（首个文件开始时清除）
    setStageProgress(ctx.unifiedId, $r('app.string.session_waiting_peer_download'));
  }
  scheduleIdleTimeout(ctx);
}

/** 拒绝：终态已拒绝。 */
export function markWebDownloadDeclined(ip: string): void {
  let ctx = resolveCtx(ip);
  if (ctx === undefined) {
    return;
  }
  clearTimers(ctx);
  finish(ctx.unifiedId, SessionStage.declined);
  bursts.delete(ip);
}

const adapter: SessionAdapter = {
  key: WEB_DOWNLOAD_KEY,
  initialize: (): void => {
  },
  getCapabilities: capabilities,
  getDisplayDescriptor: (sessionId: string): SessionDisplayDescriptor => {
    let session = getSession(sessionId);
    if (session === undefined) {
      return emptyDisplayDescriptor();
    }
    // 恰好一个文本类文件且内容可读时携带文本预览；不可读时不声明支持（按不可用降级）
    let preview: string = resolveTextPreview(session);
    return {
      peerTitle: session.peer.displayName,
      // 网页来源由来源徽标表达：副标题不再重复与标题相同的 IP
      peerSubtitle: '',
      badges: [],
      deviceType: session.peer.deviceType ?? 'mobile',
      directionLabel: $r('app.string.session_direction_send'),
      supportsTextPreview: preview.length > 0,
      textPreview: preview
    };
  },
  confirm: (sessionId: string): void => {
    let session = getSession(sessionId);
    if (session !== undefined && acceptInvoker !== undefined) {
      acceptInvoker(session.peer.ip ?? '');
    }
  },
  decline: (sessionId: string): void => {
    let session = getSession(sessionId);
    if (session !== undefined && declineInvoker !== undefined) {
      declineInvoker(session.peer.ip ?? '');
    }
  },
  cancel: (): void => {
  },
  retry: (): void => {
  },
  dispose: (sessionId: string): void => {
    // 会话回收：释放其文本预览缓存
    textPreviewCache.delete(sessionId);
    let session = getSession(sessionId);
    if (session === undefined) {
      return;
    }
    let ip: string = session.peer.ip ?? '';
    let ctx = bursts.get(ip);
    if (ctx !== undefined && ctx.unifiedId === sessionId) {
      clearTimers(ctx);
      bursts.delete(ip);
    }
  }
};

registerAdapter(adapter);
