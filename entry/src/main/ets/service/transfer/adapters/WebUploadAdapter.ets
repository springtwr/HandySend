/**
 * WebUploadAdapter.ets — Web 上传适配器（浏览器 → 本机）
 *
 * 一次浏览器上传 = 一个统一会话（token 键，多浏览器不互踢）。
 * 与下载对称：服务端是决策与落盘的事实源，字节级进度经
 * `WebUploadProgress` 事件推进，终态判定策略：
 * - 静默窗口：全部已知文件完成后，静默期内无新文件/进度即判定成功终态；
 * - 接受后无活动超时：确认后长时间无任何文件活动则终结该会话。
 * 对端以客户端 IP 描述符兜底（网页来源由来源徽标表达）。
 * 落盘位置由服务端在完成事件中给出（暂存目录），归档到 Download
 * 与接收历史由仓库在终态后承接（见 WebShareRepository）。
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
import { MediaFileInfo } from '../../../model/Types';
import { getLogger } from '../../../utils/Logger';
import { LogDomains } from '../../../common/LogDomains';
import { redactSessionToken } from '../../../utils/LogRedaction';
import { getMimeForFileName, isImage, isMediaMime } from '../../../utils/MimeUtils';
import {
  appendFiles,
  createSession,
  finish,
  getSession,
  setStage,
  setStageProgress,
  updateFileProgress,
  updateSessionFilePath
} from '../TransferSessionRegistry';
import { SessionAdapter, emptyDisplayDescriptor, registerAdapter } from './SessionAdapter';

export const WEB_UPLOAD_KEY: string = 'web-upload';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionAdapter', '协议适配');

// 与下载侧同口径（待确认 60s / 等首包 120s / 传输中无活动 30s / 成功静默 3s）
const WEB_UPLOAD_QUIET_MS: number = 3000;
const PENDING_CONFIRM_TIMEOUT_MS: number = 60000;
const WAIT_FIRST_FILE_TIMEOUT_MS: number = 120000;
const UPLOAD_IDLE_TIMEOUT_MS: number = 2 * 60 * 1000;

interface KnownFile {
  size: number
  done: boolean
}

interface BurstContext {
  unifiedId: string
  // token 即协议会话标识（服务端事实源；同 token 复用，同 token 终态后重建）
  token: string
  // 对端 IP（仅展示与日志；终态判定一律按键，不按 IP）
  ip: string
  knownFiles: Map<string, KnownFile>
  quietTimer: number
  idleTimer: number
}

// 活跃会话（按 token 归属）
const bursts: Map<string, BurstContext> = new Map();
let burstSeq: number = 0;

let acceptInvoker: ((token: string) => void) | undefined = undefined;
let declineInvoker: ((token: string) => void) | undefined = undefined;
// 待确认超时：通知原生层结束决策通道，使浏览器收到 408 而非无限等待
let expireInvoker: ((token: string) => void) | undefined = undefined;

export function setWebUploadInvokers(
  accept: (token: string) => void,
  decline: (token: string) => void,
  expire?: (token: string) => void): void {
  acceptInvoker = accept;
  declineInvoker = decline;
  expireInvoker = expire;
}

function capabilities(): SessionCapabilities {
  return {
    canCancel: true,
    canRetry: false,
    needsConfirm: true,
    hasByteProgress: true,
    canSaveToGallery: true,
    hasVerify: false,
    cancelLabel: $r('app.string.session_end_web_access')
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

/**
 * 声明清单内的文件是否全部落盘完成。
 * 浏览器在建会话时一次性声明本批全部文件，服务端也会拒绝未声明的 fileId，
 * 故清单即完整集合，无需靠静默窗口猜测是否还有后续文件。
 */
function allDeclaredFilesDone(ctx: BurstContext): boolean {
  let session = getSession(ctx.unifiedId);
  if (session === undefined || session.files.length === 0) {
    return false;
  }
  for (let i = 0; i < session.files.length; i++) {
    let record = ctx.knownFiles.get(session.files[i].fileId);
    // 路径由完成事件回填：没有最终路径说明落盘事件尚未到齐，不能提前收口
    if (record === undefined || !record.done || session.files[i].path.length === 0) {
      return false;
    }
  }
  return true;
}

/** 声明清单全部落盘即成功终结（文件状态与路径均已定型，无需再等静默窗口）。 */
function finishIfAllDone(ctx: BurstContext): void {
  if (!allDeclaredFilesDone(ctx)) {
    return;
  }
  clearTimers(ctx);
  bursts.delete(ctx.token);
  finish(ctx.unifiedId, SessionStage.succeeded);
}

/** 安排静默窗口判定：窗口结束且文件全部完成则成功终态（归档由仓库承接）。 */
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
      bursts.delete(ctx.token);
    }
  }, WEB_UPLOAD_QUIET_MS);
}

/**
 * 安排无活动超时，窗口按当前阶段取：
 * - 待确认：等用户应答；
 * - 已授权但对方还没上传任何文件：等对方开始上传；
 * - 传输中：等对端继续产生数据。
 */
function scheduleIdleTimeout(ctx: BurstContext): void {
  if (ctx.idleTimer >= 0) {
    clearTimeout(ctx.idleTimer);
  }
  let session = getSession(ctx.unifiedId);
  let pending: boolean = session === undefined || session.stage === SessionStage.awaitingConfirmation;
  let notStarted: boolean = !pending && ctx.knownFiles.size === 0;
  let delay: number = pending ? PENDING_CONFIRM_TIMEOUT_MS :
    (notStarted ? WAIT_FIRST_FILE_TIMEOUT_MS : UPLOAD_IDLE_TIMEOUT_MS);
  ctx.idleTimer = setTimeout(() => {
    ctx.idleTimer = -1;
    let current = getSession(ctx.unifiedId);
    if (current === undefined) {
      return;
    }
    if (current.stage === SessionStage.awaitingConfirmation) {
      logger.debug('网页上传待确认超时 token=' + redactSessionToken(ctx.token));
      if (expireInvoker !== undefined) {
        expireInvoker(ctx.token);
      }
      finish(ctx.unifiedId, SessionStage.cancelled, '待确认超时', 'pending_timeout');
    } else if (ctx.knownFiles.size === 0) {
      logger.debug('网页上传等待对方开始超时 token=' + redactSessionToken(ctx.token));
      finish(ctx.unifiedId, SessionStage.cancelled, '对方未上传任何文件', 'peer_no_upload');
    } else {
      logger.debug('网页上传空闲超时 token=' + redactSessionToken(ctx.token));
      finish(ctx.unifiedId, SessionStage.failed, '对端长时间无数据', 'peer_idle');
    }
    bursts.delete(ctx.token);
  }, delay);
}

// 会话文本预览缓存（统一会话标识 → 文本内容）：进度刷新期间避免重复读盘。
const textPreviewCache: Map<string, string> = new Map();

/**
 * 解析会话文本预览内容：只有浏览器在 prepare-upload 中显式声明的文本消息才返回内容，
 * 其余（包含用户选择上传的单个 .txt 文件）返回空串，避免把文本文件误当文本消息。
 */
function resolveTextPreview(session: TransferSession): string {
  let cached: string | undefined = textPreviewCache.get(session.id);
  return cached !== undefined ? cached : '';
}

/** 该上传会话是否为浏览器声明的文本消息（仅显式携带 preview 的 message.txt）。 */
export function isWebUploadTextMessage(unifiedId: string): boolean {
  return textPreviewCache.has(unifiedId);
}

/**
 * 浏览器上传请求到达：创建（或复用）会话。
 *
 * `token` 为服务端下发的浏览器标识（同 key 复用，同 key 终态后重建）；
 * `peerIp` 为展示用对端 IP（缺省取 token）。
 * `offeredFiles` 为浏览器声明的文件清单：会话创建即登记，
 * 使确认弹窗与详情页在上传开始前即有完整的文件列表。
 * @returns 统一会话标识
 */
export function beginWebUploadBurst(token: string, needsConfirm: boolean,
  offeredFiles: Array<SessionFileDescriptor> = [], peerIp?: string, previewText: string = ''): string {
  let displayIp: string = (peerIp !== undefined && peerIp.length > 0) ? peerIp : token;
  let existing = bursts.get(token);
  if (existing !== undefined) {
    let session = getSession(existing.unifiedId);
    // 与全局终态口径一致（isTerminalStage）
    if (session !== undefined && !isTerminalStage(session.stage)) {
      return existing.unifiedId;
    }
    clearTimers(existing);
  }
  burstSeq++;
  let session = createSession({
    protocolKey: WEB_UPLOAD_KEY,
    protocolSessionId: token,
    dataFlow: SessionDataFlow.inbound,
    initiatedBy: SessionInitiator.remote,
    peer: {
      displayName: displayIp,
      ip: displayIp,
      deviceType: 'web',
      badges: []
    },
    files: offeredFiles,
    capabilities: capabilities(),
    stage: needsConfirm ? SessionStage.awaitingConfirmation : SessionStage.active,
    stageText: needsConfirm ? '' : $r('app.string.session_waiting_peer_upload'),
    // 仅浏览器显式声明 preview 的文本消息；普通 .txt 文件不带该标记
    textMessage: previewText.length > 0
  });
  let ctx: BurstContext = {
    unifiedId: session.id,
    token: token,
    ip: displayIp,
    knownFiles: new Map<string, KnownFile>(),
    quietTimer: -1,
    idleTimer: -1
  };
  bursts.set(token, ctx);
  if (previewText.length > 0) {
    // 文本消息在落盘前即可用浏览器声明的正文预览，避免先显示 message.txt
    textPreviewCache.set(session.id, previewText);
  }
  // 待确认与已接受阶段均安排无活动超时
  scheduleIdleTimeout(ctx);
  return session.id;
}

/** 会话内是否已登记该文件。 */
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

function resolveCtx(token: string): BurstContext | undefined {
  return bursts.get(token);
}

/**
 * 上传字节进度：更新会话文件进度，文件完成即标记（终值由完成事件确认）。
 * 未登记的文件按事件追加（服务端以声明清单为准，超声明的字节由服务端截断）。
 */
export function handleWebUploadProgress(token: string, fileId: string, receivedBytes: number,
  totalBytes: number): void {
  let ctx = resolveCtx(token);
  if (ctx === undefined) {
    return;
  }
  if (ctx.knownFiles.size === 0) {
    // 首个文件开始：清除「等待上传」阶段文案，改为字节进度展示
    setStageProgress(ctx.unifiedId, '');
  }
  updateFileProgress(ctx.unifiedId, fileId, receivedBytes, totalBytes);
  let record = ctx.knownFiles.get(fileId);
  if (record === undefined) {
    // 挂载清单已在创建时登记同一文件：仅登记字节状态
    if (sessionHasFile(ctx.unifiedId, fileId)) {
      ctx.knownFiles.set(fileId, { size: totalBytes, done: totalBytes > 0 && receivedBytes >= totalBytes });
    } else {
      let descriptor: SessionFileDescriptor = {
        fileId: fileId,
        fileName: fileId,
        fileType: getMimeForFileName(fileId),
        totalBytes: totalBytes
      };
      appendFiles(ctx.unifiedId, [descriptor]);
      ctx.knownFiles.set(fileId, { size: totalBytes, done: totalBytes > 0 && receivedBytes >= totalBytes });
    }
  } else if (totalBytes > 0 && receivedBytes >= totalBytes) {
    record.done = true;
  }
  scheduleIdleTimeout(ctx);
  scheduleQuietCheck(ctx);
}

/**
 * 上传完成事件：服务端落盘完毕（携带最终路径），回填本地路径并记完成。
 * 文本消息预览来自浏览器声明内容，落盘后继续保留，不回读文件（回读会把普通 .txt 也当成文本消息）。
 */
export function handleWebUploadDone(token: string, fileId: string, path: string): void {
  let ctx = resolveCtx(token);
  if (ctx === undefined) {
    return;
  }
  if (path.length > 0) {
    updateSessionFilePath(ctx.unifiedId, fileId, path);
  }
  let record = ctx.knownFiles.get(fileId);
  if (record !== undefined) {
    record.done = true;
  } else {
    let session = getSession(ctx.unifiedId);
    let total: number = 0;
    if (session !== undefined) {
      for (let i = 0; i < session.files.length; i++) {
        if (session.files[i].fileId === fileId) {
          total = session.files[i].totalBytes;
          break;
        }
      }
    }
    ctx.knownFiles.set(fileId, { size: total, done: true });
  }
  scheduleIdleTimeout(ctx);
  scheduleQuietCheck(ctx);
  finishIfAllDone(ctx);
}

/** 确认接受：经注册表推进为进行中（浏览器随即开始上传，无需等待文案）。 */
export function markWebUploadAccepted(token: string): void {
  let ctx = resolveCtx(token);
  if (ctx === undefined) {
    return;
  }
  let session = getSession(ctx.unifiedId);
  if (session !== undefined && session.stage === SessionStage.awaitingConfirmation) {
    setStage(ctx.unifiedId, SessionStage.active);
    setStageProgress(ctx.unifiedId, $r('app.string.session_waiting_peer_upload'));
  }
  scheduleIdleTimeout(ctx);
}

/** 拒绝：终态已拒绝。 */
export function markWebUploadDeclined(token: string): void {
  let ctx = resolveCtx(token);
  if (ctx === undefined) {
    return;
  }
  clearTimers(ctx);
  finish(ctx.unifiedId, SessionStage.declined);
  bursts.delete(token);
}

/**
 * 服务端终结通知：声明清单已全部落盘即按成功收尾。
 * 完成回执与惰性打扫都可能先于最后一次落盘事件到达，此时文件其实已经全部就绪。
 * @returns 是否已按成功终结
 */
export function finishWebUploadIfAllDone(token: string): boolean {
  let ctx = resolveCtx(token);
  if (ctx === undefined || !allDeclaredFilesDone(ctx)) {
    return false;
  }
  finishIfAllDone(ctx);
  return true;
}

const adapter: SessionAdapter = {
  key: WEB_UPLOAD_KEY,
  initialize: (): void => {
  },
  getCapabilities: capabilities,
  getDisplayDescriptor: (sessionId: string): SessionDisplayDescriptor => {
    let session = getSession(sessionId);
    if (session === undefined) {
      return emptyDisplayDescriptor();
    }
    let preview: string = resolveTextPreview(session);
    return {
      peerTitle: session.peer.displayName,
      peerSubtitle: '',
      badges: [],
      deviceType: session.peer.deviceType ?? 'mobile',
      directionLabel: $r('app.string.session_direction_receive'),
      supportsTextPreview: preview.length > 0,
      textPreview: preview
    };
  },
  confirm: (sessionId: string): void => {
    let session = getSession(sessionId);
    if (session !== undefined && acceptInvoker !== undefined) {
      acceptInvoker(session.protocolSessionId.length > 0 ? session.protocolSessionId :
        (session.peer.ip ?? ''));
    }
  },
  decline: (sessionId: string): void => {
    let session = getSession(sessionId);
    if (session !== undefined && declineInvoker !== undefined) {
      declineInvoker(session.protocolSessionId.length > 0 ? session.protocolSessionId :
        (session.peer.ip ?? ''));
    }
  },
  cancel: (sessionId: string): void => {
    let session = getSession(sessionId);
    if (session === undefined) {
      return;
    }
    let key: string = session.protocolSessionId.length > 0 ? session.protocolSessionId :
      (session.peer.ip ?? '');
    let ctx = bursts.get(key);
    if (ctx !== undefined && ctx.unifiedId === sessionId) {
      clearTimers(ctx);
      bursts.delete(key);
    }
    // 结束服务端上传会话：移除暂存会话并清理应用保留临时区里的半成品；
    // 正在写入的请求体会在下个读块发现会话已消失并中止。
    if (expireInvoker !== undefined) {
      expireInvoker(key);
    }
    textPreviewCache.delete(sessionId);
  },
  retry: (): void => {
  },
  getGalleryMediaFiles: (sessionId: string): Array<MediaFileInfo> => {
    let session = getSession(sessionId);
    if (session === undefined) {
      return [];
    }
    let mediaFiles: Array<MediaFileInfo> = [];
    for (let i = 0; i < session.files.length; i++) {
      let file = session.files[i];
      // 落盘路径由完成事件回填：没有路径的条目尚未交付，不参与相册保存
      if (file.path.length === 0) {
        continue;
      }
      let mime: string = file.fileType.length > 0 ? file.fileType : getMimeForFileName(file.fileName);
      if (!isMediaMime(mime)) {
        continue;
      }
      mediaFiles.push({
        filePath: file.path,
        fileName: file.fileName,
        fileType: mime,
        isImage: isImage(mime)
      });
    }
    return mediaFiles;
  },
  dispose: (sessionId: string): void => {
    // 会话回收：释放其文本预览缓存
    textPreviewCache.delete(sessionId);
    let session = getSession(sessionId);
    if (session === undefined) {
      return;
    }
    let key: string = session.protocolSessionId.length > 0 ? session.protocolSessionId :
      (session.peer.ip ?? '');
    let ctx = bursts.get(key);
    if (ctx !== undefined && ctx.unifiedId === sessionId) {
      clearTimers(ctx);
      bursts.delete(key);
    }
  }
};

registerAdapter(adapter);
