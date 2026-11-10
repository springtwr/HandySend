/**
 * LocalSendSendAdapter.ets — LocalSend 发送适配器
 *
 * 把 LocalSend 发送流程的状态变化翻译为注册表操作：
 * 发送开始创建会话、进度事件驱动字节进度、发送结果决定终态。
 * 取消经会话专属原生发送键中止本会话，握手后再向对端下发 /cancel；重试经注入的发送入口。
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
import { DiscoveredDevice, SendFileItem, SendSessionStatus } from '../../../model/Types';
import { isSingleTextMessageSend } from '../../../model/SendTextPreparation';
import { nativeCancelTransfer, nativeCancelTransferLocal } from '../../NativeBridge';
import { NativeCancelTarget } from '../../../model/NativeTypes';
import { getLogger } from '../../../utils/Logger';
import { LogDomains } from '../../../common/LogDomains';
import {
  createSession, finish, getSession, updateFileProgress
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
  // 本会话专属的原生发送键：随 nativeSendFiles 下传，贯穿 prepare 与上传阶段，
  // 取消时按它精确中止本会话，避免并发发送共用「当前发送会话」而互相覆盖
  nativeSendKey: string
}

const contexts: Map<string, SendContext> = new Map();

// 原生发送键序号：同进程内保证多设备并发发送的键互不相同
let nativeSendKeySeq: number = 0;

/** 生成某次 LocalSend 发送专属的原生取消键（与协议标识、业务编号彼此独立）。 */
function newNativeSendKey(): string {
  nativeSendKeySeq++;
  return 'send_' + Date.now() + '_' + nativeSendKeySeq;
}

// 准备期取消登记（统一会话标识 → 中止哈希回调）：校验和计算期间尚无原生发送会话，
// 取消经此回调直接中止哈希（nativeCancelHash），不走协议取消路径。
const prepCancels: Map<string, () => void> = new Map();

/** 登记某会话的准备期取消回调（准备期开始）。 */
export function beginLocalSendPrep(sessionId: string, cancelPrep: () => void): void {
  prepCancels.set(sessionId, cancelPrep);
}

/** 注销某会话的准备期取消回调（准备期结束）。 */
export function endLocalSendPrep(sessionId: string): void {
  prepCancels.delete(sessionId);
}

/**
 * 取消键选择（纯函数，无副作用）：仅当会话持有的原生发送键非空时返回该键，
 * 否则返回空串表示「不下发」。该键由会话创建时生成并随 nativeSendFiles 下传，
 * 不是协议会话标识、也不是应用内部业务编号，仅用于精确取消本会话。
 */
export function decideCancelTarget(nativeSendKey: string): string {
  return nativeSendKey.length > 0 ? nativeSendKey : '';
}

/** 取某统一发送会话的原生取消键（供发送链路随 nativeSendFiles 下传）。 */
export function getLocalSendNativeKey(sessionId: string): string {
  let ctx = contexts.get(sessionId);
  return ctx !== undefined ? ctx.nativeSendKey : '';
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
    capabilities: capabilitiesFor(files),
    textMessage: isSingleTextMessageSend(files)
  });
  contexts.set(session.id, {
    device: device,
    businessSessionId: businessSessionId,
    files: files,
    nativeSendKey: newNativeSendKey()
  });
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
  // 拒收/取消是独立终态：调用方以 errorCode 透传发送状态（见 SendRepository 的终态错误码约定），
  // 此处还原为 declined/cancelled 展示为拒收/已取消，其余非成功终态仍为失败
  let stage: SessionStage = success ? SessionStage.succeeded : SessionStage.failed;
  if (!success && errorCode === SendSessionStatus.declined) {
    stage = SessionStage.declined;
  } else if (!success && errorCode === SendSessionStatus.cancelled) {
    stage = SessionStage.cancelled;
  }
  finish(unifiedSessionId, stage, errorMessage, errorCode);
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
    // 手输文本消息在发送期也携带内容预览；文件选择器选取的 .txt 不带 preview。
    let ctx: SendContext | undefined = contexts.get(sessionId);
    let text: string = '';
    if (ctx !== undefined && isSingleTextMessageSend(ctx.files)) {
      text = ctx.files[0].preview ?? '';
    }
    return {
      peerTitle: session.peer.displayName,
      peerSubtitle: session.peer.ip ?? '',
      badges: session.peer.badges,
      deviceType: session.peer.deviceType ?? 'mobile',
      directionLabel: $r('app.string.session_direction_send'),
      supportsTextPreview: text.length > 0,
      textPreview: text
    };
  },
  confirm: (): void => {
  },
  decline: (): void => {
  },
  cancel: (sessionId: string): void => {
    // 准备期：优先中止校验和计算并返回（此时无原生发送会话可取消）
    let cancelPrep = prepCancels.get(sessionId);
    if (cancelPrep !== undefined) {
      prepCancels.delete(sessionId);
      logger.debug('准备期取消：中止校验和计算 统一会话=' + sessionId);
      try {
        cancelPrep();
      } catch (e) {
        logger.warn('准备期取消回调失败 统一会话=' + sessionId + ' 原因=' + String(e));
      }
      return;
    }
    let ctx = contexts.get(sessionId);
    if (ctx === undefined) {
      return;
    }
    // 取消目标只能是本会话自己的原生发送键；
    // 取不到键说明发送链路未建立：不下发并留痕，绝不回退到进程级「当前发送会话」
    let target = decideCancelTarget(ctx.nativeSendKey);
    if (target.length === 0) {
      logger.debug('取消下发跳过：会话未持有原生发送键 统一会话=' + sessionId);
      return;
    }
    logger.debug('本地取消下发目标 发送键=' + target + ' 统一会话=' + sessionId);
    try {
      nativeCancelTransferLocal(target);
      logger.debug('本地取消下发完成 发送键=' + target);
    } catch (e) {
      logger.warn('本地取消下发失败 发送键=' + target + ' 原因=' + String(e));
    }
    // 远端 /cancel 必须携带接收方会话标识：prepare 阶段该标识尚不可知，
    // 中止请求本身会关闭连接并让对端收到 PrepareUploadAborted，无需再发远端取消
    let session = getSession(sessionId);
    let remoteSessionId: string = session !== undefined ? session.protocolSessionId : '';
    if (remoteSessionId.length === 0) {
      logger.debug('对端取消跳过：接收方会话标识尚未就绪（连接中断会通知对端） 统一会话=' + sessionId);
      return;
    }
    let cancelTarget: NativeCancelTarget = {
      ip: ctx.device.ip,
      port: ctx.device.port,
      fingerprint: ctx.device.fingerprint,
      protocol: ctx.device.protocol
    };
    nativeCancelTransfer(cancelTarget, remoteSessionId).then((): void => {
      logger.debug('对端取消下发完成 协议标识=' + remoteSessionId);
    }).catch((e: Object): void => {
      logger.warn('对端取消下发失败 协议标识=' + remoteSessionId + ' 原因=' + String(e));
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
    prepCancels.delete(sessionId);
    releaseContext(sessionId);
  }
};

registerAdapter(adapter);
