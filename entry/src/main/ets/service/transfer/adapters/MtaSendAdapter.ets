/**
 * MtaSendAdapter.ets — MTA 发送适配器
 *
 * 把 MTA 发送服务的阶段变化翻译为注册表操作；无字节进度时以阶段文案呈现。
 * 发送编排（MtaSendService 生命周期、收发互斥、取消/重试/等待跳过）由本适配器承接，
 * 发送页只负责发起；MTA 会话统一经任务与通用详情页呈现，不再有专用详情外壳。
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
import {
  MtaSendRequest,
  MTA_SHARED_TEXT_FILE_NAME,
  mtaDeviceFromParams,
  mtaSendStageLabel
} from '../../../model/mta/MtaMainModels';
import { MtaSendService } from '../../mta/MtaSendService';
import { utf8ByteLength } from '../../mta/MtaBleCommon';
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
  PeerIdentity,
  createSession,
  finish,
  getSession,
  querySessions,
  replaceTerminalSessionsForPeer,
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
/** 当前发送代次（单调递增）：仅属于当前代次的状态事件有效 */
let sendGeneration: number = 0;
/** 服务资源释放定时器（-1 表示未安排） */
let teardownTimer: number = -1;
/** 待触发的资源回收所属代次（-1 表示未安排） */
let teardownGeneration: number = -1;

// 会话结束后释放服务资源的延迟（毫秒）：先让链路资源收尾完成，再停止日志轮询与原生事件订阅
const SEND_TEARDOWN_DELAY_MS: number = 5000;

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
  brandBadge: string, mtaBrandId: number, bleAddress: string): SessionPeer {
  let badges: Array<string> = [];
  if (deviceModel.length > 0) {
    badges.push(deviceModel);
  }
  if (brandBadge.length > 0) {
    badges.push(brandBadge);
  }
  let peer: SessionPeer = {
    displayName: targetAlias,
    deviceType: deviceType,
    badges: badges,
    // MTA 来源：写入品牌标识（-1 为未知品牌），驱动设备卡品牌图标并随历史归档
    mtaBrandId: mtaBrandId
  };
  // 对端 BLE 地址复用 fingerprint 字段（仅非空时写入）：MTA 无 LocalSend 指纹，
  // 设备卡标识区据此展示可识别的对端地址，并随历史归档保持一致
  if (bleAddress.length > 0) {
    peer.fingerprint = bleAddress;
  }
  return peer;
}

/** 开始一次 MTA 发送（taskId 为协议标识）。 */
export function beginMtaSendSession(taskId: string, targetAlias: string, deviceType: string,
  deviceModel: string, brandBadge: string, files: Array<SessionFileDescriptor>,
  mtaBrandId: number = -1, bleAddress: string = ''): string {
  // 同设备取代：新会话创建之前移除该对端上一条已终态会话的可见条目。
  // MTA 协议载体不携带对端 IP，故以昵称声明身份，由注册表按昵称回退匹配。
  let identity: PeerIdentity = { ip: '', name: targetAlias };
  replaceTerminalSessionsForPeer(identity);
  let session = createSession({
    protocolKey: MTA_SEND_KEY,
    protocolSessionId: taskId,
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: buildPeer(targetAlias, deviceType, deviceModel, brandBadge, mtaBrandId, bleAddress),
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
    // 游标式拆分累计字节（MTA 发送为顺序文件流）：依次填充各文件直至耗尽，
    // 避免全部字节记到 files[0] 造成逐文件进度失真、失败时 files[0] 被误标完成
    let session = getSession(unifiedId);
    if (session !== undefined && session.files.length > 0) {
      let remaining: number = sentBytes;
      for (let i = 0; i < session.files.length; i++) {
        let file = session.files[i];
        if (file.totalBytes <= 0) {
          continue;
        }
        let portion: number = Math.min(Math.max(remaining, 0), file.totalBytes);
        updateFileProgress(unifiedId, file.fileId, portion, file.totalBytes);
        remaining -= portion;
      }
    }
  }
}

/** 终结 MTA 发送会话。 */
export function finishMtaSendSession(unifiedId: string, terminal: MtaSendTerminal,
  errorMessage?: string, errorCode?: string): void {
  let stage: SessionStage = SessionStage.failed;
  if (terminal === MtaSendTerminal.success) {
    stage = SessionStage.succeeded;
  } else if (terminal === MtaSendTerminal.partial) {
    stage = SessionStage.partiallyFailed;
  } else if (terminal === MtaSendTerminal.cancelled) {
    stage = SessionStage.cancelled;
  }
  finish(unifiedId, stage, errorMessage, errorCode);
}

// ── 发送事件决策（纯函数：无副作用、可导出、可断言忽略原因） ──

/** 发送状态事件的处置决策。 */
export enum MtaSendEventDecision {
  /** 丢弃该事件（迟到代次 / 已终结且无活跃会话 / 未开始 / 终态不诞生会话） */
  ignore = 'ignore',
  /** 用本次请求信息创建统一会话并写入进度 */
  createAndAdvance = 'create_and_advance',
  /** 会话已存在：写入阶段文案与字节进度 */
  advance = 'advance',
  /** 会话已存在且事件为终态：按终态类别终结会话 */
  finish = 'finish'
}

/** 事件被丢弃的原因（非 ignore 决策恒为 none）。 */
export enum MtaSendEventIgnoreReason {
  none = '',
  /** 事件代次不是当前发送代次（旧实例的迟到事件） */
  staleGeneration = 'stale_generation',
  /** 本会话已终结且当前无活跃会话 */
  closedWithoutActiveSession = 'closed_without_active_session',
  /** 尚未开始发送（空闲/扫描中） */
  notStarted = 'not_started',
  /** 终态事件不得诞生会话 */
  terminalWithoutActiveSession = 'terminal_without_active_session'
}

/** 发送事件的处置计划（纯数据契约）。 */
export class MtaSendEventPlan {
  /** 处置决策 */
  decision: MtaSendEventDecision = MtaSendEventDecision.ignore;
  /** 丢弃原因（仅 ignore 决策非 none） */
  ignoreReason: MtaSendEventIgnoreReason = MtaSendEventIgnoreReason.none;
  /** 事件是否为终态（决定终结时采用何种终态类别） */
  terminal: boolean = false;
}

/** 发送阶段是否为终态（完成/部分完成/失败/取消）。 */
function isTerminalSenderStage(stage: MtaSenderStage): boolean {
  return stage === MtaSenderStage.COMPLETED || stage === MtaSenderStage.PARTIAL ||
    stage === MtaSenderStage.FAILED || stage === MtaSenderStage.CANCELLED;
}

/**
 * 判定一次发送状态事件的处置方式（纯函数，无副作用）。
 *
 * 入口单点判定，同时覆盖「创建会话」与「更新/终结会话」两侧：
 * - 事件代次不是当前代次 → 丢弃（迟到事件零副作用）；
 * - 有活跃会话：终态 → 终结，其余 → 推进；
 * - 无活跃会话：已终结 → 丢弃；空闲/扫描中 → 丢弃；终态 → 丢弃（终态不诞生会话）；
 *   进行中 → 创建会话并推进。
 */
export function decideMtaSendEvent(currentGeneration: number, eventGeneration: number,
  hasActiveSession: boolean, sessionClosed: boolean, stage: MtaSenderStage): MtaSendEventPlan {
  let plan = new MtaSendEventPlan();
  let terminal: boolean = isTerminalSenderStage(stage);
  plan.terminal = terminal;
  if (eventGeneration !== currentGeneration) {
    plan.decision = MtaSendEventDecision.ignore;
    plan.ignoreReason = MtaSendEventIgnoreReason.staleGeneration;
    return plan;
  }
  if (hasActiveSession) {
    plan.decision = terminal ? MtaSendEventDecision.finish : MtaSendEventDecision.advance;
    return plan;
  }
  if (sessionClosed) {
    plan.decision = MtaSendEventDecision.ignore;
    plan.ignoreReason = MtaSendEventIgnoreReason.closedWithoutActiveSession;
    return plan;
  }
  if (stage === MtaSenderStage.IDLE) {
    plan.decision = MtaSendEventDecision.ignore;
    plan.ignoreReason = MtaSendEventIgnoreReason.notStarted;
    return plan;
  }
  if (terminal) {
    plan.decision = MtaSendEventDecision.ignore;
    plan.ignoreReason = MtaSendEventIgnoreReason.terminalWithoutActiveSession;
    return plan;
  }
  plan.decision = MtaSendEventDecision.createAndAdvance;
  return plan;
}

// ── 实例结束决策（纯函数：无副作用、可导出） ──

/** 发送实例结束时的处置计划（纯数据契约）。 */
export class MtaSendEndPlan {
  /** 是否恢复接收服务记账（该实例确实暂停过接收服务，必须成对归还） */
  resumeReceiveAccounting: boolean = true;
  /** 是否安排资源延迟回收（仅当前代次可安排，防旧实例销毁当前生效实例） */
  scheduleTeardown: boolean = false;
}

/**
 * 判定发送实例结束时的两个动作（纯函数，无副作用）：
 * 接收服务记账恒归还；资源延迟回收仅当前代次可安排。
 */
export function decideMtaSendInstanceEnd(instanceGeneration: number,
  currentGeneration: number): MtaSendEndPlan {
  let plan = new MtaSendEndPlan();
  plan.resumeReceiveAccounting = true;
  plan.scheduleTeardown = instanceGeneration === currentGeneration;
  return plan;
}

// ── 发送请求 → 发送服务入参 ──

/** 按请求的显示元数据构建会话文件描述符集（文本发送为单一文本条目）。 */
function buildDescriptors(request: MtaSendRequest | undefined): Array<SessionFileDescriptor> {
  let files: Array<SessionFileDescriptor> = [];
  if (request === undefined) {
    return files;
  }
  // 文本发送：会话呈现为单一文本类文件条目；路径取发送页持久化的文本文件（供详情页预览）
  if (request.isTextSend) {
    files.push({
      fileId: 'mta-text-0',
      fileName: MTA_SHARED_TEXT_FILE_NAME,
      fileType: 'text/plain',
      totalBytes: utf8ByteLength(request.textContent),
      path: request.textFilePath ?? ''
    });
    return files;
  }
  for (let i = 0; i < request.fileDescriptors.length; i++) {
    let descriptor = request.fileDescriptors[i];
    files.push({
      fileId: descriptor.fileId,
      fileName: descriptor.fileName,
      fileType: descriptor.fileType,
      totalBytes: descriptor.size,
      // 发送条目路径（picker/沙箱定位）：供详情页按路径读取文本内容预览
      path: i < request.fileUris.length ? request.fileUris[i] : ''
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

/**
 * 状态事件入口（代次守卫）：仅当前代次的事件有效，其余一律丢弃（不建会话、不改状态）。
 * 决策由纯函数 `decideMtaSendEvent` 给出；创建会话只使用本次发送的请求信息（处理器闭包捕获）。
 */
function handleSendState(eventGeneration: number, request: MtaSendRequest | undefined,
  state: SenderState): void {
  let plan = decideMtaSendEvent(sendGeneration, eventGeneration, activeUnifiedId !== undefined,
    sessionClosed, state.stage);
  if (plan.decision === MtaSendEventDecision.ignore) {
    logger.debug(`丢弃发送状态事件：阶段=${state.stage} 事件代次=${eventGeneration}` +
      ` 当前代次=${sendGeneration} 原因=${plan.ignoreReason}`);
    return;
  }
  let unifiedId: string | undefined = activeUnifiedId;
  if (plan.decision === MtaSendEventDecision.createAndAdvance) {
    let session = state.session;
    let taskId: string = session !== undefined ? session.taskId : '';
    unifiedId = beginMtaSendSession(taskId,
      request !== undefined ? request.targetAlias : '',
      request !== undefined ? request.deviceType : '',
      request !== undefined ? request.deviceModel : '',
      request !== undefined ? request.badgeText : '',
      buildDescriptors(request),
      request !== undefined ? request.brandId : -1,
      request !== undefined ? request.bleAddress : '');
    activeUnifiedId = unifiedId;
  }
  if (unifiedId === undefined) {
    return;
  }
  if (plan.decision === MtaSendEventDecision.finish) {
    let kind: MtaSendTerminal = MtaSendTerminal.failed;
    if (state.stage === MtaSenderStage.COMPLETED) {
      kind = MtaSendTerminal.success;
    } else if (state.stage === MtaSenderStage.PARTIAL) {
      kind = MtaSendTerminal.partial;
    } else if (state.stage === MtaSenderStage.CANCELLED) {
      kind = MtaSendTerminal.cancelled;
    }
    // 错误码仅在非成功终态记录（成功态不产生错误码）
    let errorCode: string = kind === MtaSendTerminal.success ? '' : kind;
    finishMtaSendSession(unifiedId, kind, state.lastError, errorCode);
    activeUnifiedId = undefined;
    sessionClosed = true;
    return;
  }
  updateMtaSendProgress(unifiedId, state.progress.sentBytes, state.progress.totalBytes,
    mtaSendStageLabel(state.stage));
}

// ── 发送服务生命周期 ──

/**
 * 实例结束（会话终态）的处置：接收服务记账恒归还，资源延迟回收仅当前代次可安排。
 * 决策由纯函数 `decideMtaSendInstanceEnd` 给出，两个动作可各自被独立验证。
 */
function onSendSessionEnd(instanceGeneration: number): void {
  let plan = decideMtaSendInstanceEnd(instanceGeneration, sendGeneration);
  if (plan.resumeReceiveAccounting) {
    resumeMtaReceiveAfterSend().catch((e: Object): void => {
      logger.warn('恢复 MTA 接收服务异常: ' + String(e));
    });
  }
  if (plan.scheduleTeardown) {
    scheduleTeardown(instanceGeneration);
  }
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

/** 安排资源延迟回收：记录所属代次；触发时再次校验代次，仅当前代次才释放服务实例。 */
function scheduleTeardown(generation: number): void {
  cancelTeardown();
  teardownGeneration = generation;
  teardownTimer = setTimeout((): void => {
    teardownTimer = -1;
    let scheduled = teardownGeneration;
    teardownGeneration = -1;
    // 触发时再次校验：已被新发送取代的旧实例不得销毁当前生效实例
    if (scheduled !== sendGeneration) {
      return;
    }
    destroySendService();
  }, SEND_TEARDOWN_DELAY_MS);
}

function cancelTeardown(): void {
  if (teardownTimer >= 0) {
    clearTimeout(teardownTimer);
    teardownTimer = -1;
  }
  teardownGeneration = -1;
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
  // 代次守卫：先递增代次，使上一实例的迟到事件在释放前即被过滤
  sendGeneration++;
  let generation = sendGeneration;
  // 释放上一轮发送服务（同时取消其挂起的资源回收），避免叠加多个服务实例
  destroySendService();
  let service = new MtaSendService();
  sendService = service;
  // 本次发送专用事件处理器：捕获本次代次与请求，状态事件入口据此过滤并创建会话；
  // 不再复用模块级共享处理器（那是迟到事件污染当前发送的结构性原因）
  let handlers = new MtaSendEventHandlers();
  handlers.onStateChange = (state: SenderState): void => {
    handleSendState(generation, params, state);
  };
  service.setEventHandlers(handlers);
  service.setSessionEndListener((): void => {
    onSendSessionEnd(generation);
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
  await service.sendToDevice(device, files, text);
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
      // MTA 来源：透传品牌标识（-1 为未知品牌，回退默认 MTA 图标），与发送页设备列表同源
      mtaBrandId: session.peer.mtaBrandId,
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
