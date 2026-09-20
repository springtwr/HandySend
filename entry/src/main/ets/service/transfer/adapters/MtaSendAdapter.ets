/**
 * MtaSendAdapter.ets — MTA 发送适配器
 *
 * 把 MTA 发送服务的阶段变化翻译为注册表操作；无字节进度时以阶段文案呈现。
 * 发送编排（MtaSendService 生命周期、收发互斥、取消/重试/等待跳过）由本适配器承接，
 * 发送页只负责发起；MTA 会话统一经传输中心与通用详情页呈现，不再有专用详情外壳。
 */

import { common } from '@kit.AbilityKit';
import {
  SessionCapabilities,
  SessionDataFlow,
  SessionDisplayDescriptor,
  SessionFileDescriptor,
  SessionFilter,
  SessionInitiator,
  SessionPeer,
  SessionStage,
  isTerminalStage
} from '../../../model/transfer/TransferSession';
import {
  MtaSendEventHandlers,
  MtaSendFile,
  MtaSenderStage,
  SenderState
} from '../../../model/mta/MtaSendModels';
import { MtaSendRequest, mtaDeviceFromParams, mtaSendStageLabel } from '../../../model/mta/MtaMainModels';
import { MtaSendService } from '../../mta/MtaSendService';
import {
  getMtaSendClickedMs,
  isMtaSendActive,
  resumeMtaReceiveAfterSend,
  stopMtaDiscoveryScan,
  suspendMtaReceiveForSend
} from '../../repository/MtaRepository';
import { getLogger } from '../../../utils/Logger';
import { LogDomains } from '../../../common/LogDomains';
import {
  createSession,
  finish,
  getSession,
  querySessions,
  setStageProgress,
  updateFileProgress
} from '../TransferSessionRegistry';
import { SessionAdapter, emptyDisplayDescriptor, hasDisplayText, registerAdapter } from './SessionAdapter';

export const MTA_SEND_KEY: string = 'mta-send';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionAdapter', '协议适配');

/** MTA 发送终态类别。 */
export enum MtaSendTerminal {
  success = 'success',
  partial = 'partial',
  failed = 'failed',
  cancelled = 'cancelled'
}

// ── MTA 发送编排（协议层会话由适配器内部管理） ──
// 统一会话建模「用户可见的一次有界传输活动」；MtaSendService 生命周期、收发互斥、
// 取消与等待跳过等既有行为在此承接，并逐一翻译为注册表操作。

/** 发送服务实例（发送为单会话编排，同一时刻至多一个） */
let sendService: MtaSendService | undefined = undefined;
/** 发起时的应用上下文（重试复用） */
let sendContext: common.Context | undefined = undefined;
/** 最近一次发送请求（重试复用） */
let lastSendRequest: MtaSendRequest | undefined = undefined;
/** 当前统一会话标识（进行中时存在） */
let activeUnifiedId: string | undefined = undefined;
/** 本会话是否已终结（终态或已被注册表回收）：阻止迟到的终态信号重建幽灵会话 */
let sessionClosed: boolean = false;
/** 服务资源释放定时器（-1 表示未安排） */
let teardownTimer: number = -1;

// 会话结束后释放服务资源的延迟（毫秒）：先让链路资源收尾完成，再停止日志轮询与原生事件订阅
const SEND_TEARDOWN_DELAY_MS: number = 5000;

const sendHandlers: MtaSendEventHandlers = new MtaSendEventHandlers();
sendHandlers.onStateChange = (state: SenderState): void => {
  syncUnifiedSession(state);
};

function capabilities(): SessionCapabilities {
  return {
    canCancel: true,
    canRetry: true,
    needsConfirm: false,
    hasByteProgress: true,
    canSaveToGallery: false,
    hasVerify: false
  };
}

function buildPeer(targetAlias: string, deviceType: string, deviceModel: string,
  brandBadge: string): SessionPeer {
  let badges: Array<string> = [];
  if (deviceModel.length > 0) {
    badges.push(deviceModel);
  }
  if (brandBadge.length > 0) {
    badges.push(brandBadge);
  }
  return {
    displayName: targetAlias,
    deviceType: deviceType,
    badges: badges,
    anonymous: targetAlias.length === 0
  };
}

/** 开始一次 MTA 发送（taskId 为协议标识）。 */
export function beginMtaSendSession(taskId: string, targetAlias: string, deviceType: string,
  deviceModel: string, brandBadge: string, files: Array<SessionFileDescriptor>): string {
  let session = createSession({
    protocolKey: MTA_SEND_KEY,
    protocolSessionId: taskId,
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: buildPeer(targetAlias, deviceType, deviceModel, brandBadge),
    files: files,
    capabilities: capabilities(),
    stage: SessionStage.active
  });
  return session.id;
}

/** 更新 MTA 发送进度（字节与阶段文案）。 */
export function updateMtaSendProgress(unifiedId: string, sentBytes: number, totalBytes: number,
  stageText: ResourceStr): void {
  if (hasDisplayText(stageText)) {
    setStageProgress(unifiedId, stageText);
  }
  if (totalBytes > 0) {
    // 以单文件口径整体推进（MTA 发送为顺序文件流）
    let session = getSession(unifiedId);
    if (session !== undefined && session.files.length > 0) {
      updateFileProgress(unifiedId, session.files[0].fileId, sentBytes, totalBytes);
    }
  }
}

/** 终结 MTA 发送会话。 */
export function finishMtaSendSession(unifiedId: string, terminal: MtaSendTerminal,
  errorMessage?: string): void {
  let stage: SessionStage = SessionStage.failed;
  if (terminal === MtaSendTerminal.success) {
    stage = SessionStage.succeeded;
  } else if (terminal === MtaSendTerminal.partial) {
    stage = SessionStage.partiallyFailed;
  } else if (terminal === MtaSendTerminal.cancelled) {
    stage = SessionStage.cancelled;
  }
  finish(unifiedId, stage, errorMessage);
}

// ── 发送请求 → 发送服务入参 ──

/** 按请求的显示元数据构建会话文件描述符集（文本发送无文件条目）。 */
function buildDescriptors(request: MtaSendRequest | undefined): Array<SessionFileDescriptor> {
  let files: Array<SessionFileDescriptor> = [];
  if (request === undefined) {
    return files;
  }
  for (let i = 0; i < request.fileDescriptors.length; i++) {
    let descriptor = request.fileDescriptors[i];
    files.push({
      fileId: descriptor.fileId,
      fileName: descriptor.fileName,
      fileType: descriptor.fileType,
      totalBytes: descriptor.size
    });
  }
  return files;
}

/** 从 URI 末段解析显示文件名（无有效段时以序号兜底）。 */
function fileNameFromUri(uri: string, fallbackIndex: number): string {
  let name = uri;
  let slash = uri.lastIndexOf('/');
  if (slash >= 0 && slash < uri.length - 1) {
    name = uri.substring(slash + 1);
  }
  try {
    name = decodeURIComponent(name);
  } catch (_e) {
  }
  return name.length > 0 ? name : `file_${fallbackIndex}`;
}

/** 映射请求中的文件清单为发送服务入参。 */
function buildSendFiles(request: MtaSendRequest): Array<MtaSendFile> {
  let files: Array<MtaSendFile> = [];
  if (request.isTextSend) {
    // 文本发送经 sendToDevice 文本入参附加共享文本条目
    return files;
  }
  for (let i = 0; i < request.fileUris.length; i++) {
    let file = new MtaSendFile();
    file.uri = request.fileUris[i];
    if (i < request.fileDescriptors.length) {
      let descriptor = request.fileDescriptors[i];
      file.displayName = descriptor.fileName.length > 0 ? descriptor.fileName :
        fileNameFromUri(request.fileUris[i], i);
      file.sizeBytes = descriptor.size;
    } else {
      file.displayName = fileNameFromUri(request.fileUris[i], i);
    }
    files.push(file);
  }
  return files;
}

// ── 统一会话生命周期翻译 ──

/** 首次进入非空闲阶段创建会话，进行中更新进度，终态终结会话。 */
function syncUnifiedSession(state: SenderState): void {
  let terminalSuccess: boolean = state.stage === MtaSenderStage.COMPLETED;
  let terminal: boolean = terminalSuccess || state.stage === MtaSenderStage.PARTIAL ||
    state.stage === MtaSenderStage.FAILED || state.stage === MtaSenderStage.CANCELLED;
  let unifiedId: string | undefined = activeUnifiedId;
  if (unifiedId === undefined) {
    // 会话已终结：迟到的终态信号不得重建新会话
    if (sessionClosed) {
      return;
    }
    if (state.stage === MtaSenderStage.IDLE || state.stage === MtaSenderStage.SCANNING) {
      return;
    }
    let session = state.session;
    let taskId: string = session !== undefined ? session.taskId : '';
    let request = lastSendRequest;
    unifiedId = beginMtaSendSession(taskId,
      request !== undefined ? request.targetAlias : '',
      request !== undefined ? request.deviceType : '',
      request !== undefined ? request.deviceModel : '',
      request !== undefined ? request.badgeText : '',
      buildDescriptors(request));
    activeUnifiedId = unifiedId;
  }
  if (terminal) {
    let kind: MtaSendTerminal = MtaSendTerminal.failed;
    if (terminalSuccess) {
      kind = MtaSendTerminal.success;
    } else if (state.stage === MtaSenderStage.PARTIAL) {
      kind = MtaSendTerminal.partial;
    } else if (state.stage === MtaSenderStage.CANCELLED) {
      kind = MtaSendTerminal.cancelled;
    }
    finishMtaSendSession(unifiedId, kind, state.lastError);
    activeUnifiedId = undefined;
    sessionClosed = true;
    return;
  }
  updateMtaSendProgress(unifiedId, state.progress.sentBytes, state.progress.totalBytes,
    mtaSendStageLabel(state.stage));
}

// ── 发送服务生命周期 ──

/** 会话终态：按开关恢复 MTA 接收服务，并在资源收尾后释放发送服务。 */
function onSendSessionEnd(): void {
  resumeMtaReceiveAfterSend().catch((e: Object): void => {
    logger.warn('恢复 MTA 接收服务异常: ' + String(e));
  });
  scheduleTeardown();
}

/** 释放当前发送服务（幂等）：取消挂起的释放并停止日志轮询/原生事件订阅。 */
function destroySendService(): void {
  cancelTeardown();
  let service = sendService;
  sendService = undefined;
  if (service !== undefined) {
    service.destroy();
  }
}

function scheduleTeardown(): void {
  cancelTeardown();
  teardownTimer = setTimeout((): void => {
    teardownTimer = -1;
    destroySendService();
  }, SEND_TEARDOWN_DELAY_MS);
}

function cancelTeardown(): void {
  if (teardownTimer >= 0) {
    clearTimeout(teardownTimer);
    teardownTimer = -1;
  }
}

/**
 * 发起一次 MTA 发送（由发送流程调用）：
 * 新建发送服务并绑定事件与终态监听 → 停发现扫描并暂停接收服务（收发互斥）→ 开始发送。
 */
export async function startMtaSend(params: MtaSendRequest, context: common.Context): Promise<void> {
  let hasContent: boolean = params.isTextSend ? params.textContent.length > 0 : params.fileUris.length > 0;
  if (!hasContent) {
    return;
  }
  let clickedMs = getMtaSendClickedMs();
  let startMs = Date.now();
  lastSendRequest = params;
  sendContext = context;
  activeUnifiedId = undefined;
  sessionClosed = false;
  // 释放上一轮发送服务，避免同一适配器叠加多个服务实例的定时器与订阅
  destroySendService();
  let service = new MtaSendService();
  sendService = service;
  service.setEventHandlers(sendHandlers);
  service.setSessionEndListener((): void => {
    onSendSessionEnd();
  });
  service.init(context);
  // 收发互斥：发送前停止发现扫描并暂停接收服务
  stopMtaDiscoveryScan();
  await suspendMtaReceiveForSend();
  if (clickedMs > 0) {
    logger.debug(`点击设备→开始发送耗时=${startMs - clickedMs}ms（含停扫描+暂停接收服务）`);
  }
  let files = buildSendFiles(params);
  let text = params.isTextSend ? params.textContent : '';
  let device = mtaDeviceFromParams(params);
  await service.sendToDevice(device, files, false, text);
}

/** 取消进行中的 MTA 发送（经适配器命令入口调用）。 */
function cancelActiveSend(): void {
  let service = sendService;
  if (service === undefined) {
    return;
  }
  service.cancelSend().catch((e: Object): void => {
    logger.warn('MTA 取消发送异常: ' + String(e));
  });
}

/** 重试：以最近一次请求重新发起 MTA 发送。 */
function retryLastSend(): void {
  let request = lastSendRequest;
  let context = sendContext;
  if (request === undefined || context === undefined) {
    return;
  }
  startMtaSend(request, context).catch((e: Object): void => {
    logger.warn('MTA 重试发送异常: ' + String(e));
  });
}

/**
 * 是否存在进行中的 MTA 发送（发送页「设备忙」判定）。
 * 收发互斥计数覆盖「点击→注册表会话创建」之间的空窗，注册表活跃会话为统一事实源。
 */
export function isMtaSendSessionActive(): boolean {
  if (isMtaSendActive()) {
    return true;
  }
  let filter: SessionFilter = { protocolKey: MTA_SEND_KEY };
  let sessions = querySessions(filter);
  for (let i = 0; i < sessions.length; i++) {
    if (!isTerminalStage(sessions[i].stage)) {
      return true;
    }
  }
  return false;
}

const adapter: SessionAdapter = {
  key: MTA_SEND_KEY,
  initialize: (): void => {
  },
  getCapabilities: capabilities,
  getDisplayDescriptor: (sessionId: string): SessionDisplayDescriptor => {
    let session = getSession(sessionId);
    if (session === undefined) {
      return emptyDisplayDescriptor();
    }
    return {
      peerTitle: session.peer.displayName.length > 0 ? session.peer.displayName :
        $r('app.string.session_peer_mta_device'),
      peerSubtitle: $r('app.string.session_peer_mta_union'),
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
  cancel: (_sessionId: string): void => {
    cancelActiveSend();
  },
  retry: (_sessionId: string): void => {
    retryLastSend();
  },
  dispose: (sessionId: string): void => {
    // 注册表回收：若回收的正是当前会话（如取消后可见窗口早于取消通知等待结束），
    // 标记已终结，避免随后到达的终态信号重建幽灵会话
    if (activeUnifiedId === sessionId) {
      activeUnifiedId = undefined;
      sessionClosed = true;
    }
  }
};

registerAdapter(adapter);
