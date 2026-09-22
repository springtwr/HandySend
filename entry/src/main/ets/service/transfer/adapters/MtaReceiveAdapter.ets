/**
 * MtaReceiveAdapter.ets — MTA 接收适配器
 *
 * 消费 MtaRepository 的接收状态快照，把接收阶段映射为统一会话状态：
 * REQUEST_RECEIVED → 待确认；建链/下载/落盘 → 进行中；COMPLETED/FAILED → 终态。
 * 确认/拒绝/取消/接受文本与相册媒体经 MtaRepository 注入的入口下发；
 * 文本消息会话经展示描述符携带文本内容，正向动作为「接受文本」（不进入下载），
 * 剪贴板写入由 UI 侧在用户选择「复制」时独立完成。
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
  ReceiverStage, ReceiverState, isMtaReceivingStage
} from '../../../model/mta/MtaProtocolModels';
import {
  createSession,
  finish,
  getSession,
  setStage,
  setStageProgress,
  updateFileProgress,
  updateSessionFilePath
} from '../TransferSessionRegistry';
import { SessionAdapter, emptyDisplayDescriptor, registerAdapter } from './SessionAdapter';
import { MediaFileInfo } from '../../../model/Types';
import { MtaConstants } from '../../mta/MtaConstants';

export const MTA_RECEIVE_KEY: string = 'mta-receive';

/**
 * 对端接受窗口（毫秒）：发送端等待对端开始接收的上限。
 * 本机待确认超时必须严格长于该值，避免抢在对端仍在等待时误终结。
 */
export const MTA_PEER_ACCEPT_WINDOW_MS: number = MtaConstants.PEER_ACCEPT_TIMEOUT_MS;

/** MTA 接收待确认超时（毫秒）：无人处理时按已取消终结并释放接收侧资源。 */
export const MTA_PENDING_TIMEOUT_MS: number = 60000;

// MTA 接收任一时刻至多一个会话：请求未携带任务标识时回退该固定常量，保证协议会话 ID 始终有值可核对
const PROTOCOL_ID: string = 'mta-receive-session';

// MTA 接收会话的文件条目标识（单条目会话恒为该值）：文本落盘后按此回填真实路径
const MTA_RECEIVE_TEXT_FILE_ID: string = 'mta-0';

let activeUnifiedId: string | undefined = undefined;

// 待确认超时定时器（-1 表示未运行；同一时刻至多一个接收会话）
let pendingTimeoutId: number = -1;

function cancelPendingTimeout(): void {
  if (pendingTimeoutId >= 0) {
    clearTimeout(pendingTimeoutId);
    pendingTimeoutId = -1;
  }
}

function schedulePendingTimeout(sessionId: string): void {
  cancelPendingTimeout();
  pendingTimeoutId = setTimeout(() => {
    pendingTimeoutId = -1;
    expirePendingConfirm(sessionId);
  }, MTA_PENDING_TIMEOUT_MS);
}

// 统一会话标识 → 原生文本内容（文本消息接收时以「接受文本」作为正向动作）
const textContentByUnifiedId: Map<string, string> = new Map();

let acceptInvoker: (() => void) | undefined = undefined;
let rejectInvoker: (() => void) | undefined = undefined;
let cancelInvoker: (() => void) | undefined = undefined;
// 接受文本收尾（回接受 ack 与成功状态，不进入下载流程）
let acceptTextInvoker: (() => void) | undefined = undefined;
// 当前接收会话可保存到相册的媒体文件（由协议仓库提供）
let galleryMediaProvider: (() => Array<MediaFileInfo>) | undefined = undefined;

export function setMtaReceiveInvokers(
  accept: () => void,
  reject: () => void,
  cancel: () => void,
  acceptText: () => void,
  provideGalleryMedia: () => Array<MediaFileInfo>): void {
  acceptInvoker = accept;
  rejectInvoker = reject;
  cancelInvoker = cancel;
  acceptTextInvoker = acceptText;
  galleryMediaProvider = provideGalleryMedia;
}

/**
 * 「文本已落盘（带路径）」通知：把真实保存路径回填到当前活跃统一会话的文本文件条目。
 * 回填只允许「空 → 非空」且仅非终态写入，故会话不存在、已终态或参数为空时均为空操作，
 * 不产生异常。用于任务历史归档后仍可按路径读取文本内容预览。
 */
export function notifyMtaTextSaved(savedPath: string): void {
  if (activeUnifiedId === undefined) {
    return;
  }
  updateSessionFilePath(activeUnifiedId, MTA_RECEIVE_TEXT_FILE_ID, savedPath);
}

/**
 * 待确认超时终结（供定时器与测试直接调用）：按已取消终结统一会话，
 * 并复用拒绝入口释放接收侧资源（关闭连接、复位到可继续接收状态）。
 */
export function expirePendingConfirm(sessionId: string): void {
  let session = getSession(sessionId);
  if (session === undefined || session.stage !== SessionStage.awaitingConfirmation) {
    return;
  }
  if (rejectInvoker !== undefined) {
    rejectInvoker();
  }
  finish(sessionId, SessionStage.cancelled, '待确认超时', 'pending_timeout');
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
  let peer: SessionPeer = {
    displayName: name,
    badges: [],
    // 接收协议不携带品牌：标记为 MTA 来源的未知品牌（-1），
    // 与展示描述符口径一致，并随历史归档保证设备卡品牌图标在结束后不变
    mtaBrandId: -1
  };
  // 对端标识复用 fingerprint 字段：优先已连接 GATT 的对端标识，
  // 为空时回退接收请求携带的发送方 ID；两者皆空则不设置（按不可用降级）
  let peerId: string = state.connectedPeerId.length > 0 ? state.connectedPeerId :
    (request !== undefined ? request.senderId : '');
  if (peerId.length > 0) {
    peer.fingerprint = peerId;
  }
  return peer;
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
    // 协议会话 ID 取请求携带的协议任务标识；请求缺失或未携带任务标识时回退固定常量
    let protocolSessionId: string = request !== undefined && request.taskId.length > 0 ?
      request.taskId : PROTOCOL_ID;
    let descriptors: Array<SessionFileDescriptor> = [];
    descriptors.push({
      fileId: MTA_RECEIVE_TEXT_FILE_ID,
      fileName: fileName,
      fileType: textContent.length > 0 ? 'text/plain' : '',
      totalBytes: totalBytes
    });
    let session = createSession({
      protocolKey: MTA_RECEIVE_KEY,
      protocolSessionId: protocolSessionId,
      dataFlow: SessionDataFlow.inbound,
      initiatedBy: SessionInitiator.remote,
      peer: buildPeer(state),
      files: descriptors,
      capabilities: capabilities(),
      stage: SessionStage.awaitingConfirmation
    });
    activeUnifiedId = session.id;
    if (textContent.length > 0) {
      textContentByUnifiedId.set(session.id, textContent);
    }
    // 待确认阶段具备接收侧超时：用户始终不处理且对端不关闭连接时自行收尾
    schedulePendingTimeout(session.id);
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
      updateFileProgress(activeUnifiedId, MTA_RECEIVE_TEXT_FILE_ID, state.progress.receivedBytes, total);
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
    let text: string = textContentByUnifiedId.get(sessionId) ?? '';
    return {
      peerTitle: session.peer.displayName.length > 0 ? session.peer.displayName :
        $r('app.string.session_peer_mta_device'),
      peerSubtitle: $r('app.string.session_peer_mta_union'),
      badges: session.peer.badges,
      // 协议不携带设备类型：恒回退手机图标（见 buildPeer 说明）
      deviceType: session.peer.deviceType ?? 'mobile',
      // 接收协议不携带品牌：恒为未知品牌（-1），设备卡回退默认 MTA 品牌图标
      mtaBrandId: -1,
      directionLabel: $r('app.string.session_direction_receive'),
      supportsTextPreview: text.length > 0,
      textPreview: text
    };
  },
  confirm: (sessionId: string): void => {
    // 用户已处理（确认或接受文本）：取消待确认超时
    cancelPendingTimeout();
    // 文本消息：接受即收尾（回接受 ack 与成功状态、不进入下载流程）；
    // 剪贴板是否写入由 UI 侧在用户选择「复制」时独立完成，不混入协议接受语义
    if (textContentByUnifiedId.get(sessionId) !== undefined) {
      if (acceptTextInvoker !== undefined) {
        acceptTextInvoker();
      }
      // 文本接受无下载流程、协议侧不产生终态信号，此处统一按成功收尾
      finish(sessionId, SessionStage.succeeded);
      return;
    }
    if (acceptInvoker !== undefined) {
      acceptInvoker();
    }
  },
  decline: (): void => {
    // 用户已处理：取消待确认超时
    cancelPendingTimeout();
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
    if (textContentByUnifiedId.get(sessionId) !== undefined) {
      return [];
    }
    return galleryMediaProvider !== undefined ? galleryMediaProvider() : [];
  },
  dispose: (sessionId: string): void => {
    textContentByUnifiedId.delete(sessionId);
    // 仅当回收的正是当前活跃会话时才释放引用；旧会话到期回收不得误清
    // 新会话刚设置的 activeUnifiedId，否则新会话的状态信号被丢弃而永久卡死
    if (activeUnifiedId === sessionId) {
      cancelPendingTimeout();
      releaseActive();
    }
  }
};

registerAdapter(adapter);
