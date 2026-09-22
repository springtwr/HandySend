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
  setStage,
  updateFileProgress,
  updateSessionFilePath
} from '../TransferSessionRegistry';
import { SessionAdapter, emptyDisplayDescriptor, registerAdapter } from './SessionAdapter';

export const WEB_DOWNLOAD_KEY: string = 'web-download';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionAdapter', '协议适配');

// 静默窗口（毫秒）：全部文件完成后无新活动即判定成功终态
const WEB_DOWNLOAD_QUIET_MS: number = 3000;
// 接受后无活动超时（毫秒）：确认后对端始终不产生数据则终结会话
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

export function setWebDownloadInvokers(
  accept: (ip: string) => void,
  decline: (ip: string) => void): void {
  acceptInvoker = accept;
  declineInvoker = decline;
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
      finish(ctx.unifiedId, SessionStage.succeeded);
      bursts.delete(ctx.ip);
    }
  }, WEB_DOWNLOAD_QUIET_MS);
}

/**
 * 安排无活动超时：
 * - 待确认阶段：无人处理 → 按撤回处理并终结；
 * - 已接受阶段：对端长时间无文件活动 → 按失败终结。
 */
function scheduleIdleTimeout(ctx: BurstContext): void {
  if (ctx.idleTimer >= 0) {
    clearTimeout(ctx.idleTimer);
  }
  ctx.idleTimer = setTimeout(() => {
    ctx.idleTimer = -1;
    let session = getSession(ctx.unifiedId);
    if (session === undefined) {
      return;
    }
    if (session.stage === SessionStage.awaitingConfirmation) {
      logger.debug('web download pending timeout, ip=' + ctx.ip);
      finish(ctx.unifiedId, SessionStage.cancelled, '待确认超时', 'pending_timeout');
    } else {
      logger.debug('web download idle timeout, ip=' + ctx.ip);
      finish(ctx.unifiedId, SessionStage.failed, '对端长时间无数据', 'peer_idle');
    }
    bursts.delete(ctx.ip);
  }, ACCEPT_IDLE_TIMEOUT_MS);
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
 * @returns 统一会话标识
 */
export function beginWebDownloadBurst(ip: string, needsConfirm: boolean): string {
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
    files: [],
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
    return;
  }
  let realName: string = fileName.length > 0 ? fileName : fileId;
  let existing = ctx.knownFiles.get(fileId);
  if (existing === undefined) {
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
  if (totalBytes > 0) {
    updateFileProgress(ctx.unifiedId, fileId, sentBytes, totalBytes);
  }
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
