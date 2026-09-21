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
  // 应用内部业务编号（非协议标识）：仅用于业务侧归属，禁止作为协议会话 ID 或取消目标
  businessSessionId: string
  files: Array<SendFileItem>
}

const contexts: Map<string, SendContext> = new Map();

/**
 * 取消下发目标选择（纯函数，无副作用）：仅当原生当前发送会话标识可用时返回该标识，
 * 否则返回空串表示「不下发」。原生取消表以协议标识为键，应用内部业务编号不是协议标识，
 * 故本函数不接收业务编号——从形态上杜绝业务编号被当作取消目标下发。
 */
export function decideCancelTarget(nativeSessionId: string): string {
  return nativeSessionId.length > 0 ? nativeSessionId : '';
}

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
    badges: device.deviceModel.length > 0 ? [device.deviceModel] : []
  };
}

/** 开始一次 LocalSend 发送：创建统一会话并返回统一标识。 */
export function beginLocalSendSession(businessSessionId: string, device: DiscoveredDevice,
  files: Array<SendFileItem>): string {
  let descriptors: Array<SessionFileDescriptor> = [];
  for (let i = 0; i < files.length; i++) {
    descriptors.push({
      fileId: files[i].fileId,
      fileName: files[i].fileName,
      fileType: files[i].fileType,
      totalBytes: files[i].size,
      // 逐文件校验和：启用校验和后由发送链路计算并携带，未启用时为空
      checksum: files[i].hash ?? '',
      // 发送条目路径：供详情页按路径读取文本内容预览（手输文本为持久目录、picker 为选择器 URI）
      path: files[i].filePath
    });
  }
  let session = createSession({
    protocolKey: LOCAL_SEND_KEY,
    // 创建时协议标识（接收方标识）尚不可知：由 prepare-upload 握手返回后回填，此处置空；
    // 传入的标识是应用内部业务编号，不属于协议标识，禁止作为协议会话 ID。
    protocolSessionId: '',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: buildPeer(device),
    files: descriptors,
    capabilities: capabilitiesFor(files)
  });
  contexts.set(session.id, { device: device, businessSessionId: businessSessionId, files: files });
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
    // 取消目标只能是协议标识（握手期 prepare_<ip> 或握手后的接收方标识）；
    // 取不到协议标识说明发送链路已不在活动状态：不下发并留痕，绝不回退到内部业务编号。
    let target = decideCancelTarget(nativeGetCurrentSendSessionId());
    if (target.length === 0) {
      logger.warn('取消下发跳过：未取得协议标识（发送链路可能已不在活动状态） 统一会话=' + sessionId);
      return;
    }
    logger.info('取消下发目标 协议标识=' + target + ' 统一会话=' + sessionId);
    try {
      nativeCancelTransferLocal(target);
      logger.info('本地取消下发完成 协议标识=' + target);
    } catch (e) {
      logger.warn('本地取消下发失败 协议标识=' + target + ' 原因=' + String(e));
    }
    let cancelTarget: NativeCancelTarget = {
      ip: ctx.device.ip,
      port: ctx.device.port,
      fingerprint: ctx.device.fingerprint,
      protocol: ctx.device.protocol
    };
    nativeCancelTransfer(cancelTarget, target).then((): void => {
      logger.info('远端取消下发完成 协议标识=' + target);
    }).catch((e: Object): void => {
      logger.warn('远端取消下发失败 协议标识=' + target + ' 原因=' + String(e));
    });
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
