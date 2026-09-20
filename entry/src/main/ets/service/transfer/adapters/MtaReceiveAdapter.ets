/**
 * MtaReceiveAdapter.ets — MTA 接收适配器
 *
 * 消费 MtaRepository 的接收状态快照，把接收阶段映射为统一会话状态：
 * REQUEST_RECEIVED → 待确认；建链/下载/落盘 → 进行中；COMPLETED/FAILED → 终态。
 * 确认/拒绝/取消/复制文本与相册媒体经 MtaRepository 注入的入口下发；
 * 文本消息会话经展示描述符携带文本内容，正向动作为「复制文本」（不进入下载）。
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
import {
  ReceiverStage,
  ReceiverState,
  isMtaReceivingStage
} from '../../../model/mta/MtaProtocolModels';
import {
  createSession,
  finish,
  getSession,
  setStage,
  setStageProgress,
  updateFileProgress
} from '../TransferSessionRegistry';
import { SessionAdapter, emptyDisplayDescriptor, registerAdapter } from './SessionAdapter';
import { MediaFileInfo } from '../../../model/Types';

export const MTA_RECEIVE_KEY: string = 'mta-receive';

// MTA 接收任意时刻至多一个会话：用固定逻辑协议标识，终态后再来新请求创建新会话
const PROTOCOL_ID: string = 'mta-receive-session';

let activeUnifiedId: string | undefined = undefined;

// 统一会话标识 → 原生文本内容（文本消息接收时以「复制文本」作为正向动作）
const textByUnifiedId: Map<string, string> = new Map();

let acceptInvoker: (() => void) | undefined = undefined;
let rejectInvoker: (() => void) | undefined = undefined;
let cancelInvoker: (() => void) | undefined = undefined;
// 复制文本收尾（回接受 ack 且不进入下载流程）
let copyInvoker: (() => void) | undefined = undefined;
// 当前接收会话可保存到相册的媒体文件（由协议仓库提供）
let galleryMediaProvider: (() => Array<MediaFileInfo>) | undefined = undefined;

export function setMtaReceiveInvokers(
  accept: () => void,
  reject: () => void,
  cancel: () => void,
  copy: () => void,
  provideGalleryMedia: () => Array<MediaFileInfo>): void {
  acceptInvoker = accept;
  rejectInvoker = reject;
  cancelInvoker = cancel;
  copyInvoker = copy;
  galleryMediaProvider = provideGalleryMedia;
}

function capabilities(): SessionCapabilities {
  return {
    canCancel: true,
    canRetry: false,
    needsConfirm: true,
    hasByteProgress: true,
    canSaveToGallery: true,
    hasVerify: false
  };
}

/**
 * 构建对端标识。
 * MTA 协议载荷（BLE 广播、GATT DeviceInfo、sendRequest 的 ReceiveRequest）均不携带
 * 对端设备类型或型号，故此处不设置 deviceType；展示层据此恒回退手机图标，不伪造数据。
 */
function buildPeer(state: ReceiverState): SessionPeer {
  let request = state.receiveRequest;
  let name: string = request !== undefined ? request.senderName : '';
  return { displayName: name, badges: [], anonymous: name.length === 0 };
}

/** 阶段文案（离散阶段口径）。 */
function stageTextOf(stage: ReceiverStage): ResourceStr {
  if (stage === ReceiverStage.P2P_INFO_RECEIVED || stage === ReceiverStage.P2P_CONNECTING) {
    return $r('app.string.session_stage_connecting');
  }
  if (stage === ReceiverStage.P2P_CONNECTED || stage === ReceiverStage.WS_CONNECTING) {
    return $r('app.string.session_stage_connected');
  }
  if (stage === ReceiverStage.NEGOTIATED) {
    return $r('app.string.session_stage_negotiating');
  }
  if (stage === ReceiverStage.DOWNLOADING) {
    return $r('app.string.session_stage_receiving');
  }
  if (stage === ReceiverStage.SAVING) {
    return $r('app.string.session_stage_saving');
  }
  return '';
}

/**
 * 消费 MTA 接收状态快照：按阶段映射为统一会话操作。
 * 由 MtaRepository 的状态回调驱动。
 */
export function handleMtaReceiveState(state: ReceiverState): void {
  let request = state.receiveRequest;
  let stage: ReceiverStage = state.stage;

  // 新请求到达（REQUEST_RECEIVED）：创建待确认会话
  if (stage === ReceiverStage.REQUEST_RECEIVED) {
    if (activeUnifiedId !== undefined && getSession(activeUnifiedId) !== undefined) {
      return;
    }
    let totalBytes: number = request !== undefined ? request.totalSize : 0;
    let fileName: string = request !== undefined ? request.fileName : '';
    let textContent: string = request !== undefined ? request.textContent : '';
    let descriptors: Array<SessionFileDescriptor> = [];
    descriptors.push({ fileId: 'mta-0', fileName: fileName, fileType: textContent.length > 0 ? 'text/plain' : '',
      totalBytes: totalBytes });
    let session = createSession({
      protocolKey: MTA_RECEIVE_KEY,
      protocolSessionId: PROTOCOL_ID,
      dataFlow: SessionDataFlow.inbound,
      initiatedBy: SessionInitiator.remote,
      peer: buildPeer(state),
      files: descriptors,
      capabilities: capabilities(),
      stage: SessionStage.awaitingConfirmation
    });
    activeUnifiedId = session.id;
    if (textContent.length > 0) {
      textByUnifiedId.set(session.id, textContent);
    }
    return;
  }

  if (activeUnifiedId === undefined) {
    return;
  }

  // 建链/下载/落盘：进行中 + 阶段文案 + 字节进度
  if (isMtaReceivingStage(stage)) {
    // 防御性推进：已进入接收阶段说明对端已开始传输，会话不应停留在待确认
    let current = getSession(activeUnifiedId);
    if (current !== undefined && current.stage === SessionStage.awaitingConfirmation) {
      setStage(activeUnifiedId, SessionStage.active);
    }
    setStageProgress(activeUnifiedId, stageTextOf(stage));
    if (state.progress.receivedBytes > 0) {
      let total: number = request !== undefined ? request.totalSize : state.progress.totalBytes;
      updateFileProgress(activeUnifiedId, 'mta-0', state.progress.receivedBytes, total);
    }
  } else if (stage === ReceiverStage.COMPLETED) {
    finish(activeUnifiedId, SessionStage.succeeded);
    activeUnifiedId = undefined;
  } else if (stage === ReceiverStage.FAILED) {
    finish(activeUnifiedId, SessionStage.failed, state.lastError);
    activeUnifiedId = undefined;
  }
}

function releaseActive(): void {
  activeUnifiedId = undefined;
}

const adapter: SessionAdapter = {
  key: MTA_RECEIVE_KEY,
  initialize: (): void => {
  },
  getCapabilities: capabilities,
  getDisplayDescriptor: (sessionId: string): SessionDisplayDescriptor => {
    let session = getSession(sessionId);
    if (session === undefined) {
      return emptyDisplayDescriptor();
    }
    let text: string = textByUnifiedId.get(sessionId) ?? '';
    return {
      peerTitle: session.peer.displayName.length > 0 ? session.peer.displayName :
        $r('app.string.session_peer_mta_device'),
      peerSubtitle: $r('app.string.session_peer_mta_union'),
      badges: session.peer.badges,
      // 协议不携带设备类型：恒回退手机图标（见 buildPeer 说明）
      deviceType: session.peer.deviceType ?? 'mobile',
      directionLabel: $r('app.string.session_direction_receive'),
      supportsTextPreview: text.length > 0,
      textPreview: text
    };
  },
  confirm: (sessionId: string): void => {
    // 文本消息：正向动作为「复制文本」，写入剪贴板后由页面触发本收尾（不进入下载）
    if (textByUnifiedId.get(sessionId) !== undefined) {
      if (copyInvoker !== undefined) {
        copyInvoker();
      }
      return;
    }
    if (acceptInvoker !== undefined) {
      acceptInvoker();
    }
  },
  decline: (): void => {
    if (rejectInvoker !== undefined) {
      rejectInvoker();
    }
  },
  cancel: (): void => {
    if (cancelInvoker !== undefined) {
      cancelInvoker();
    }
  },
  retry: (): void => {
  },
  getGalleryMediaFiles: (sessionId: string): Array<MediaFileInfo> => {
    // 文本消息无可保存媒体；文件接收返回协议仓库当前会话的媒体文件
    if (textByUnifiedId.get(sessionId) !== undefined) {
      return [];
    }
    return galleryMediaProvider !== undefined ? galleryMediaProvider() : [];
  },
  dispose: (sessionId: string): void => {
    textByUnifiedId.delete(sessionId);
    // 仅当回收的正是当前活跃会话时才释放引用；旧会话到期回收不得误清
    // 新会话刚设置的 activeUnifiedId，否则新会话的状态信号被丢弃而永久卡死
    if (activeUnifiedId === sessionId) {
      releaseActive();
    }
  }
};

registerAdapter(adapter);
