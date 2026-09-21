/**
 * LocalSendSendAdapter.ets — LocalSend 发送适配器
 *
 * 把 LocalSend 发送流程的状态变化翻译为注册表操作：
 * 发送开始创建会话、进度事件驱动字节进度、发送结果决定终态。
 * 取消经原生 CancellationToken / 远端 /cancel 下发；重试经注入的发送入口。
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
import { DiscoveredDevice, SendFileItem } from '../../../model/Types';
import { isSingleTextMessageSend } from '../../../model/SendTextPreparation';
import { nativeCancelTransfer, nativeCancelTransferLocal, nativeGetCurrentSendSessionId } from '../../NativeBridge';
import { NativeCancelTarget } from '../../../model/NativeTypes';
import { getLogger } from '../../../utils/Logger';
import { LogDomains } from '../../../common/LogDomains';
import {
  createSession,
  finish,
  getSession,
  updateFileProgress
} from '../TransferSessionRegistry';
import { SessionAdapter, emptyDisplayDescriptor, registerAdapter } from './SessionAdapter';

export const LOCAL_SEND_KEY: string = 'localsend-send';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionAdapter', '协议适配');

// 统一会话 → 发送上下文（取消/重试需要目标与文件）
interface SendContext {
  device: DiscoveredDevice
  protocolSessionId: string
  files: Array<SendFileItem>
}

const contexts: Map<string, SendContext> = new Map();

// 重试入口（由 SendRepository 注入，避免适配器反向依赖仓库）
let retryInvoker: ((device: DiscoveredDevice, files: Array<SendFileItem>) => void) | undefined = undefined;

export function setLocalSendRetryInvoker(
  invoker: (device: DiscoveredDevice, files: Array<SendFileItem>) => void): void {
  retryInvoker = invoker;
}

function capabilities(): SessionCapabilities {
  return {
    canCancel: true,
    canRetry: true,
    needsConfirm: false,
    // 该静态声明仅用于动作分发判定（可取消/需确认）；
    // 字节进度能力按会话声明，见 capabilitiesFor
    hasByteProgress: true,
    canSaveToGallery: false,
    hasVerify: false
  };
}

/**
 * 按会话声明能力。
 *
 * 单条文本消息走「仅预览送达」路径：接收端只取走预览、不上传文件，
 * 整个会话不产生任何字节进度事件，故该会话不声明字节级进度，
 * 避免进行中窗口被渲染成误导性的 0% 进度条。
 * 其余发送（文件、多条目等）保持字节进度。
 * 判据复用发送链路的既有纯函数，不另立口径。
 */
function capabilitiesFor(files: Array<SendFileItem>): SessionCapabilities {
  let caps: SessionCapabilities = capabilities();
  caps.hasByteProgress = !isSingleTextMessageSend(files);
  return caps;
}

function buildPeer(device: DiscoveredDevice): SessionPeer {
  return {
    displayName: device.alias,
    ip: device.ip,
    fingerprint: device.fingerprint,
    deviceType: device.deviceType,
    badges: device.deviceModel.length > 0 ? [device.deviceModel] : [],
    anonymous: false
  };
}

/** 开始一次 LocalSend 发送：创建统一会话并返回统一标识。 */
export function beginLocalSendSession(protocolSessionId: string, device: DiscoveredDevice,
  files: Array<SendFileItem>): string {
  let descriptors: Array<SessionFileDescriptor> = [];
  for (let i = 0; i < files.length; i++) {
    descriptors.push({
      fileId: files[i].fileId,
      fileName: files[i].fileName,
      fileType: files[i].fileType,
      totalBytes: files[i].size,
      // 逐文件校验和：启用校验和后由发送链路计算并携带，未启用时为空
      checksum: files[i].hash ?? ''
    });
  }
  let session = createSession({
    protocolKey: LOCAL_SEND_KEY,
    protocolSessionId: protocolSessionId,
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: buildPeer(device),
    files: descriptors,
    capabilities: capabilitiesFor(files)
  });
  contexts.set(session.id, { device: device, protocolSessionId: protocolSessionId, files: files });
  return session.id;
}

/**
 * 按统一会话标识更新发送进度。
 * 进度归属只认统一标识：调用方先定位到本会话（见 SendRepository 的文件标识 → 会话归属），
 * 再以此入口写入，避免按文件标识共享映射被后续会话覆盖。
 */
export function updateLocalSendProgress(unifiedSessionId: string, fileId: string,
  bytesSent: number, totalBytes: number): void {
  if (contexts.get(unifiedSessionId) === undefined) {
    return;
  }
  updateFileProgress(unifiedSessionId, fileId, bytesSent, totalBytes);
}

/** 按统一会话标识终结发送会话（成功/失败/取消各路径的统一终态入口）。 */
export function finishLocalSend(unifiedSessionId: string, success: boolean, errorMessage?: string,
  errorCode?: string): void {
  let session = getSession(unifiedSessionId);
  if (session === undefined || session.protocolKey !== LOCAL_SEND_KEY) {
    return;
  }
  finish(unifiedSessionId, success ? SessionStage.succeeded : SessionStage.failed, errorMessage, errorCode);
}

function releaseContext(unifiedId: string): void {
  contexts.delete(unifiedId);
}

const adapter: SessionAdapter = {
  key: LOCAL_SEND_KEY,
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
      badges: session.peer.badges,
      deviceType: session.peer.deviceType ?? 'mobile',
      directionLabel: $r('app.string.session_direction_send'),
      supportsTextPreview: false
    };
  },
  confirm: (): void => {
  },
  decline: (): void => {
  },
  cancel: (sessionId: string): void => {
    let ctx = contexts.get(sessionId);
    if (ctx === undefined) {
      return;
    }
    // 先本地中断 CancellationToken，再通知接收方清理会话
    let target = nativeGetCurrentSendSessionId();
    if (target.length === 0) {
      target = ctx.protocolSessionId;
    }
    try {
      if (target.length > 0) {
        nativeCancelTransferLocal(target);
      }
    } catch (e) {
      logger.warn('local cancel failed: ' + String(e));
    }
    let cancelTarget: NativeCancelTarget = {
      ip: ctx.device.ip,
      port: ctx.device.port,
      fingerprint: ctx.device.fingerprint,
      protocol: ctx.device.protocol
    };
    if (target.length > 0) {
      nativeCancelTransfer(cancelTarget, target).catch((e: Object): void => {
        logger.warn('remote cancel failed: ' + String(e));
      });
    }
  },
  retry: (sessionId: string): void => {
    let ctx = contexts.get(sessionId);
    if (ctx === undefined || retryInvoker === undefined) {
      return;
    }
    retryInvoker(ctx.device, ctx.files);
  },
  dispose: (sessionId: string): void => {
    releaseContext(sessionId);
  }
};

registerAdapter(adapter);
