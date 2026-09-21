/**
 * LocalSendReceiveAdapter.ets — LocalSend 接收适配器
 *
 * 把 LocalSend 入站事件翻译为注册表操作：prepareUpload 创建待确认/进行中会话，
 * uploadProgress 驱动字节进度，sessionEnd / cancelReceived / prepareUploadAborted
 * 分别决定成功/失败/取消终态。确认与拒绝经注入的响应入口下发。
 */

import {
  SessionCapabilities,
  SessionDataFlow,
  SessionDisplayDescriptor,
  SessionFileDescriptor,
  SessionInitiator,
  SessionPeer,
  SessionStage
} from '../../../model/transfer/TransferSession';
import { nativeCancelLocalSession } from '../../NativeBridge';
import { getLogger } from '../../../utils/Logger';
import { LogDomains } from '../../../common/LogDomains';
import {
  createSession,
  finish,
  getSession,
  setStage,
  updateFileProgress
} from '../TransferSessionRegistry';
import { SessionAdapter, emptyDisplayDescriptor, registerAdapter } from './SessionAdapter';

export const LOCAL_RECEIVE_KEY: string = 'localsend-receive';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionAdapter', '协议适配');

// 协议会话标识（接收方 UUID）→ 统一会话标识
const unifiedByProtocol: Map<string, string> = new Map();
// 协议会话标识 → 文本消息内容（仅文本消息会话有值，供详情页文本预览插槽）
const textPreviewByProtocol: Map<string, string> = new Map();
// 待确认超时定时器（协议会话标识 → timer id）：无人处理时终结为已取消
const pendingTimeouts: Map<string, number> = new Map();

// 待确认请求超时（毫秒）：无人确认/拒绝时按发送方撤回处理并释放资源
const PENDING_TIMEOUT_MS: number = 60000;

// 确认/拒绝/清理入口（由 ReceiveRepository 注入）
let confirmInvoker: ((protocolSessionId: string) => void) | undefined = undefined;
let declineInvoker: ((protocolSessionId: string) => void) | undefined = undefined;
let cleanupInvoker: ((protocolSessionId: string) => void) | undefined = undefined;

export function setLocalReceiveInvokers(
  confirm: (protocolSessionId: string) => void,
  decline: (protocolSessionId: string) => void,
  cleanup: (protocolSessionId: string) => void): void {
  confirmInvoker = confirm;
  declineInvoker = decline;
  cleanupInvoker = cleanup;
}

function cancelPendingTimeout(protocolSessionId: string): void {
  let timer = pendingTimeouts.get(protocolSessionId);
  if (timer !== undefined) {
    clearTimeout(timer);
    pendingTimeouts.delete(protocolSessionId);
  }
}

function schedulePendingTimeout(protocolSessionId: string): void {
  cancelPendingTimeout(protocolSessionId);
  let timer: number = setTimeout(() => {
    pendingTimeouts.delete(protocolSessionId);
    let unifiedId = unifiedByProtocol.get(protocolSessionId);
    if (unifiedId === undefined) {
      return;
    }
    let session = getSession(unifiedId);
    if (session === undefined || session.stage !== SessionStage.awaitingConfirmation) {
      return;
    }
    // 无人处理：按撤回处理并释放已预创建的资源
    finish(unifiedId, SessionStage.cancelled, '待确认超时', 'pending_timeout');
    if (cleanupInvoker !== undefined) {
      cleanupInvoker(protocolSessionId);
    }
  }, PENDING_TIMEOUT_MS);
  pendingTimeouts.set(protocolSessionId, timer);
}

function capabilities(): SessionCapabilities {
  return {
    canCancel: true,
    canRetry: false,
    needsConfirm: true,
    hasByteProgress: true,
    canSaveToGallery: true,
    hasVerify: true
  };
}

function buildPeer(senderAlias: string, senderIp: string, senderFingerprint: string,
  senderDeviceType: string, senderDeviceModel: string): SessionPeer {
  return {
    displayName: senderAlias,
    ip: senderIp,
    fingerprint: senderFingerprint,
    deviceType: senderDeviceType,
    badges: senderDeviceModel.length > 0 ? [senderDeviceModel] : [],
    anonymous: senderAlias.length === 0
  };
}

/**
 * 摄入一次入站请求：创建统一会话（自动接收时为进行中，否则为待确认）。
 * `textPreview` 为文本消息内容（非文本消息传空串），供详情页文本预览。
 * 返回统一会话标识。
 */
export function ensureReceiveSession(protocolSessionId: string, senderAlias: string, senderIp: string,
  senderFingerprint: string, senderDeviceType: string, senderDeviceModel: string,
  files: Array<SessionFileDescriptor>, needsConfirm: boolean, textPreview: string): string {
  let existing = unifiedByProtocol.get(protocolSessionId);
  if (existing !== undefined && getSession(existing) !== undefined) {
    return existing;
  }
  if (textPreview.length > 0) {
    textPreviewByProtocol.set(protocolSessionId, textPreview);
  }
  let session = createSession({
    protocolKey: LOCAL_RECEIVE_KEY,
    protocolSessionId: protocolSessionId,
    dataFlow: SessionDataFlow.inbound,
    initiatedBy: SessionInitiator.remote,
    peer: buildPeer(senderAlias, senderIp, senderFingerprint, senderDeviceType, senderDeviceModel),
    files: files,
    capabilities: capabilities(),
    stage: needsConfirm ? SessionStage.awaitingConfirmation : SessionStage.active
  });
  unifiedByProtocol.set(protocolSessionId, session.id);
  if (needsConfirm) {
    schedulePendingTimeout(protocolSessionId);
  }
  return session.id;
}

/** 接收方向字节进度（进度事件按 会话×文件 归属）。 */
export function updateReceiveProgress(protocolSessionId: string, fileId: string,
  bytesSent: number, totalBytes: number): void {
  let unifiedId = unifiedByProtocol.get(protocolSessionId);
  if (unifiedId === undefined) {
    return;
  }
  updateFileProgress(unifiedId, fileId, bytesSent, totalBytes);
}

/** 接收会话进入进行中（确认后）。 */
export function markReceiveActive(protocolSessionId: string): void {
  cancelPendingTimeout(protocolSessionId);
  let unifiedId = unifiedByProtocol.get(protocolSessionId);
  if (unifiedId === undefined) {
    return;
  }
  setStage(unifiedId, SessionStage.active);
}

/** 接收会话终结（成功/部分失败/失败/取消/拒绝）。 */
export function finishLocalReceiveSession(protocolSessionId: string, stage: SessionStage,
  errorMessage?: string, errorCode?: string): void {
  cancelPendingTimeout(protocolSessionId);
  let unifiedId = unifiedByProtocol.get(protocolSessionId);
  if (unifiedId === undefined) {
    return;
  }
  finish(unifiedId, stage, errorMessage, errorCode);
}

function resolveProtocolId(sessionId: string): string {
  let session = getSession(sessionId);
  if (session === undefined) {
    return '';
  }
  return session.protocolSessionId;
}

const adapter: SessionAdapter = {
  key: LOCAL_RECEIVE_KEY,
  initialize: (): void => {
  },
  getCapabilities: capabilities,
  getDisplayDescriptor: (sessionId: string): SessionDisplayDescriptor => {
    let session = getSession(sessionId);
    if (session === undefined) {
      return emptyDisplayDescriptor();
    }
    // 文本消息内容由摄入请求时写入（仅手动输入的文本消息带内容）
    let text: string = textPreviewByProtocol.get(session.protocolSessionId) ?? '';
    return {
      peerTitle: session.peer.displayName.length > 0 ? session.peer.displayName :
        $r('app.string.session_peer_unknown_device'),
      peerSubtitle: session.peer.ip ?? '',
      badges: session.peer.badges,
      deviceType: session.peer.deviceType ?? 'mobile',
      directionLabel: $r('app.string.session_direction_receive'),
      supportsTextPreview: text.length > 0,
      textPreview: text
    };
  },
  confirm: (sessionId: string): void => {
    let protocolSessionId = resolveProtocolId(sessionId);
    if (protocolSessionId.length > 0 && confirmInvoker !== undefined) {
      confirmInvoker(protocolSessionId);
    }
  },
  decline: (sessionId: string): void => {
    let protocolSessionId = resolveProtocolId(sessionId);
    if (protocolSessionId.length > 0 && declineInvoker !== undefined) {
      declineInvoker(protocolSessionId);
    }
  },
  cancel: (sessionId: string): void => {
    let protocolSessionId = resolveProtocolId(sessionId);
    if (protocolSessionId.length === 0) {
      return;
    }
    nativeCancelLocalSession(protocolSessionId).catch((e: Object): void => {
      logger.warn('local session cancel failed: ' + String(e));
    });
  },
  retry: (): void => {
  },
  dispose: (sessionId: string): void => {
    let protocolSessionId = resolveProtocolId(sessionId);
    if (protocolSessionId.length > 0) {
      cancelPendingTimeout(protocolSessionId);
      unifiedByProtocol.delete(protocolSessionId);
      textPreviewByProtocol.delete(protocolSessionId);
    }
  }
};

registerAdapter(adapter);
