/**
 * WebDownloadAdapter.ets — Web 分享下载适配器
 *
 * 一次浏览器下载突发 = 一个统一会话（burst 模型）：协议层的 IP 授权会话由
 * 适配器内部维护（同 IP 终态后再次下载创建新会话）。终态判定采用策略：
 * - 静默窗口：全部已知文件完成后，静默期内无新文件/进度即判定成功终态；
 * - 接受后无活动超时：确认后长时间无任何文件活动则终结该会话。
 * 对端以「网页客户端 · IP」描述符兜底（匿名对端）。
 */

import {
  SessionCapabilities,
  SessionDataFlow,
  SessionDisplayDescriptor,
  SessionInitiator,
  SessionStage
} from '../../../model/transfer/TransferSession';
import { getLogger } from '../../../utils/Logger';
import { LogDomains } from '../../../common/LogDomains';
import { getStringSyncFromContext } from '../../../utils/ResourceUtil';
import { getAppContext } from '../../repository/AppCore';
import {
  appendFiles,
  createSession,
  finish,
  getSession,
  setStage,
  updateFileProgress
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
  protocolSessionId: string
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

/**
 * Web 对端展示名：本地化前缀资源 + IP 拼接（如「网页客户端 · 192.168.1.3」）。
 * 前缀取自三语言资源以避免在适配器内硬编码；应用上下文缺失或资源读取失败时回退为纯 IP。
 * `SessionPeer.displayName` 为可持久化字符串，IP 无法与 `ResourceStr` 直接相加，故在此解析后拼接。
 */
function buildWebClientDisplayName(ip: string): string {
  let prefix: string = getStringSyncFromContext(getAppContext(), $r('app.string.session_peer_web_client'));
  return prefix.length > 0 ? prefix + ' · ' + ip : ip;
}

/**
 * 浏览器下载请求到达：创建（或复用）突发会话。
 * @returns 统一会话标识
 */
export function beginWebDownloadBurst(ip: string, needsConfirm: boolean): string {
  let existing = bursts.get(ip);
  if (existing !== undefined) {
    let session = getSession(existing.unifiedId);
    if (session !== undefined && session.stage !== SessionStage.succeeded &&
      session.stage !== SessionStage.failed && session.stage !== SessionStage.cancelled &&
      session.stage !== SessionStage.declined) {
      return existing.unifiedId;
    }
    clearTimers(existing);
  }
  burstSeq++;
  let protocolSessionId: string = ip + '#' + burstSeq;
  let session = createSession({
    protocolKey: WEB_DOWNLOAD_KEY,
    protocolSessionId: protocolSessionId,
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.remote,
    peer: { displayName: buildWebClientDisplayName(ip), ip: ip, deviceType: 'web', badges: [], anonymous: true },
    files: [],
    capabilities: capabilities(),
    stage: needsConfirm ? SessionStage.awaitingConfirmation : SessionStage.active
  });
  let ctx: BurstContext = {
    unifiedId: session.id,
    ip: ip,
    protocolSessionId: protocolSessionId,
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

/** 文件下载开始/完成事件：登记文件大小并重置静默与活动定时器。 */
export function handleWebFileDownload(ip: string, fileId: string, size: number): void {
  let ctx = resolveCtx(ip);
  if (ctx === undefined) {
    return;
  }
  let existing = ctx.knownFiles.get(fileId);
  if (existing === undefined) {
    appendFiles(ctx.unifiedId, [{ fileId: fileId, fileName: fileId, fileType: '', totalBytes: size }]);
    let record: KnownFile = { size: size, done: size <= 0 };
    ctx.knownFiles.set(fileId, record);
  } else if (size > 0) {
    existing.size = size;
  }
  if (ctx.idleTimer >= 0) {
    clearTimeout(ctx.idleTimer);
    ctx.idleTimer = -1;
  }
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
  if (ctx.idleTimer >= 0) {
    clearTimeout(ctx.idleTimer);
    ctx.idleTimer = -1;
  }
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
    return {
      peerTitle: session.peer.displayName,
      peerSubtitle: session.peer.ip ?? '',
      badges: [],
      deviceType: session.peer.deviceType ?? 'mobile',
      directionLabel: $r('app.string.session_direction_send'),
      supportsTextPreview: false
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
