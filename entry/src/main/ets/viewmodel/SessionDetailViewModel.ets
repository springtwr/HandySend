/**
 * SessionDetailViewModel.ets — 通用会话详情页视图模型
 *
 * 页面外壳协议无关：读注册表会话 + 适配器展示描述符/能力声明 + 时间线；
 * 返回操作不取消会话，取消是独立显式操作（见 SessionDetailPage）。
 */

import {
  SessionCapabilities,
  SessionDataFlow,
  SessionDisplayDescriptor,
  SessionEventKind,
  SessionFile,
  SessionFileStage,
  SessionStage,
  SessionTimelineEvent,
  TransferSession,
  defaultCapabilities,
  isTerminalStage
} from '../model/transfer/TransferSession';
import { SessionHistoryEntry, SessionHistoryFileEntry } from '../model/transfer/SessionHistory';
import {
  cancel as registryCancel,
  confirmSession,
  declineSession,
  getHistory,
  getSession,
  getSessionCapabilities,
  subscribeSessions,
  unsubscribeSessions
} from '../service/transfer/TransferSessionRegistry';
import { emptyDisplayDescriptor, getAdapter, isTextSessionDescriptor } from '../service/transfer/adapters/SessionAdapter';
import { isAutoFinish } from '../service/repository/SettingsRepository';
// 来源标签、方向文案与历史结果 → 统一状态映射与任务列表同源（同一套纯函数，避免两处口径分叉）
import { directionLabelFor, sourceLabelForProtocol, stageForOutcome } from './TransferCenterViewModel';
import { isTextFile } from '../utils/MimeUtils';
import { readTextOfLocation } from '../utils/FileTextUtil';
import { MediaFileInfo } from '../model/Types';
import { SpeedEstimator } from '../utils/SpeedEstimator';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionDetail', '会话详情');

/** 详情页路由参数（按统一会话标识进入）。 */
export interface SessionDetailParams {
  sessionId: string
}

/**
 * 详情页标识栏复制可用性判定（纯函数）：非空可复制；空值不可复制（展示统一占位）。
 * 供信息行决定是否渲染行内复制入口。
 */
export function canCopyMetaValue(value: string): boolean {
  return value.length > 0;
}

/** 详情页文件区块的预览模式（仅由「文件数量 + 文本类判定」决定）。 */
export enum SessionPreviewMode {
  /** 会话仅一个文本类文件：内联展示文本内容 */
  inline = 'inline',
  /** 其余情形：展示文件清单（文本类条目提供点击预览） */
  list = 'list'
}

/**
 * 预览模式判定（纯函数，无副作用）：会话只有 1 个文件且为文本类 → 内联预览；
 * 其余（多文件、单非文本、空）→ 文件清单。实时态与历史态同规则。
 */
export function decidePreviewMode(files: Array<SessionFile>): SessionPreviewMode {
  if (files.length === 1 && isTextFile(files[0].fileType, files[0].fileName)) {
    return SessionPreviewMode.inline;
  }
  return SessionPreviewMode.list;
}

/**
 * 详情页完整信息（对实时会话与历史条目统一取数）。
 * 缺省字段以空串/0 表示，由展示层统一降级。
 */
export interface SessionDetailMeta {
  // 对端设备信息
  peerName: string
  peerFingerprint: string
  peerIp: string
  peerDeviceType: string
  peerDeviceModel: string
  // 时间信息
  createdAt: number
  startedAt: number
  finishedAt: number
  durationMs: number
  // 传输性能
  totalBytes: number
  averageSpeedBps: number
  peakSpeedBps: number
  // 结果与错误
  errorMessage: string
  errorCode: string
  // 本地设备与标识
  localAlias: string
  localIp: string
  localInterfaceName: string
  protocolSessionId: string
  sessionId: string
}

/** 空详情信息（缺省降级基线）。 */
export function emptySessionDetailMeta(): SessionDetailMeta {
  return {
    peerName: '',
    peerFingerprint: '',
    peerIp: '',
    peerDeviceType: '',
    peerDeviceModel: '',
    createdAt: 0,
    startedAt: 0,
    finishedAt: 0,
    durationMs: 0,
    totalBytes: 0,
    averageSpeedBps: 0,
    peakSpeedBps: 0,
    errorMessage: '',
    errorCode: '',
    localAlias: '',
    localIp: '',
    localInterfaceName: '',
    protocolSessionId: '',
    sessionId: ''
  };
}

/**
 * 会话是否为「接收成功后自动提示保存到相册」的候选（纯判定、无副作用）：
 * 已达成功完成态、会话能力声明可保存到相册、且非文本消息会话。
 * 是否真的存在可保存媒体由调用方另行判定（协议适配器的媒体能力，或接收侧一次性媒体信号）。
 */
export function isGallerySaveCandidate(session: TransferSession): boolean {
  if (session.stage !== SessionStage.succeeded) {
    return false;
  }
  if (!session.capabilities.canSaveToGallery) {
    return false;
  }
  let adapter = getAdapter(session.protocolKey);
  if (adapter === undefined) {
    return false;
  }
  // 文本消息会话不提示：其内容是可复制的文本，不属于相册媒体
  let descriptor: SessionDisplayDescriptor = adapter.getDisplayDescriptor(session.id);
  return !isTextSessionDescriptor(descriptor);
}

/** 取某会话可保存到相册的媒体文件（由协议适配器提供；适配器未声明该能力时为空数组）。 */
export function galleryMediaFilesOf(sessionId: string, protocolKey: string): Array<MediaFileInfo> {
  let adapter = getAdapter(protocolKey);
  if (adapter !== undefined && adapter.getGalleryMediaFiles !== undefined) {
    return adapter.getGalleryMediaFiles(sessionId);
  }
  return [];
}

/** 解析接收侧媒体信号的 JSON 内容（空串、解析失败或结构不符时返回空数组）。 */
export function parseMediaFilesJson(json: string): Array<MediaFileInfo> {
  if (json.length === 0) {
    return [];
  }
  try {
    let parsed: Object = JSON.parse(json);
    if (!Array.isArray(parsed)) {
      return [];
    }
    return parsed as Array<MediaFileInfo>;
  } catch (e) {
    logger.warn('parse media files failed: ' + String(e));
    return [];
  }
}

/** 取时间线中指定类别事件的首次时间戳（不存在返回 0）。 */
function timelineTimeOf(events: Array<SessionTimelineEvent>, kind: SessionEventKind): number {
  for (let i = 0; i < events.length; i++) {
    if (events[i].kind === kind) {
      return events[i].timestamp;
    }
  }
  return 0;
}

/** 由实时会话构建详情信息。 */
function liveDetailMeta(session: TransferSession): SessionDetailMeta {
  let createdAt: number = timelineTimeOf(session.timeline, SessionEventKind.created);
  if (createdAt <= 0) {
    createdAt = session.startedAt;
  }
  let startedAt: number = timelineTimeOf(session.timeline, SessionEventKind.started);
  if (startedAt <= 0) {
    startedAt = session.startedAt;
  }
  let finishedAt: number = session.finishedAt;
  // 耗时与时间线口径严格一致：起止时间各自截断毫秒后取差（formatTime 精确到秒），
  // 避免「毫秒差向下取整」与「时间线绝对时间之差」偶发 1 秒偏差
  let durationMs: number = 0;
  if (finishedAt > session.startedAt) {
    durationMs = (Math.floor(finishedAt / 1000) - Math.floor(session.startedAt / 1000)) * 1000;
  }
  return {
    peerName: session.peer.displayName,
    peerFingerprint: session.peer.fingerprint ?? '',
    peerIp: session.peer.ip ?? '',
    peerDeviceType: session.peer.deviceType ?? '',
    peerDeviceModel: session.peer.badges.length > 0 ? session.peer.badges[0] : '',
    createdAt: createdAt,
    startedAt: startedAt,
    finishedAt: finishedAt,
    durationMs: durationMs,
    totalBytes: session.totalBytes,
    averageSpeedBps: session.averageSpeedBps,
    peakSpeedBps: session.peakSpeedBps,
    errorMessage: session.errorMessage,
    errorCode: session.errorCode,
    localAlias: session.localAlias,
    localIp: session.localIp,
    localInterfaceName: session.localInterfaceName,
    protocolSessionId: session.protocolSessionId,
    sessionId: session.id
  };
}

/** 由持久化历史条目构建详情信息（会话回收后仍可读）。 */
function historyDetailMeta(entry: SessionHistoryEntry): SessionDetailMeta {
  let createdAt: number = timelineTimeOf(entry.timeline, SessionEventKind.created);
  if (createdAt <= 0) {
    createdAt = entry.startedAt;
  }
  let startedAt: number = timelineTimeOf(entry.timeline, SessionEventKind.started);
  if (startedAt <= 0) {
    startedAt = entry.startedAt;
  }
  return {
    peerName: entry.peerName,
    peerFingerprint: entry.peerFingerprint,
    peerIp: entry.peerIp,
    peerDeviceType: entry.peerDeviceType,
    peerDeviceModel: entry.peerDeviceModel,
    createdAt: createdAt,
    startedAt: startedAt,
    finishedAt: entry.finishedAt,
    durationMs: entry.durationMs,
    totalBytes: entry.totalBytes,
    averageSpeedBps: entry.averageSpeedBps,
    peakSpeedBps: entry.peakSpeedBps,
    errorMessage: entry.errorMessage,
    errorCode: entry.errorCode,
    localAlias: entry.localAlias,
    localIp: entry.localIp,
    localInterfaceName: entry.localInterfaceName,
    protocolSessionId: entry.protocolSessionId,
    sessionId: entry.sessionId
  };
}

/** 历史逐文件条目 → 展示用会话文件（无实时字节进度）。 */
function historyFileToSessionFile(entry: SessionHistoryFileEntry): SessionFile {
  let file = new SessionFile();
  file.fileId = entry.fileId;
  file.fileName = entry.fileName;
  file.fileType = entry.fileType;
  file.totalBytes = entry.size;
  file.checksum = entry.checksum;
  // 透传归档时的磁盘路径：历史态内联预览按该路径读取内容，缺省为空串（按不可用降级）
  file.path = entry.path ?? '';
  file.stage = entry.stage;
  if (entry.stage === SessionFileStage.completed) {
    file.bytesSent = entry.size;
  }
  return file;
}

// 速度显示同步间隔与过期阈值（毫秒）
const DISPLAY_SYNC_INTERVAL: number = 1000;
const SPEED_STALE_MS: number = 3000;

@ObservedV2
export class SessionDetailViewModel {
  @Trace public session: TransferSession | undefined = undefined
  // 注册表内已无该会话时回退加载的持久化历史条目（只读摘要，无逐文件进度与时间线）
  @Trace public historyEntry: SessionHistoryEntry | undefined = undefined
  // 曾加载实时会话、该会话已离开注册表且无历史可回退时置位：全部动作可用性恒为否
  @Trace public liveReleased: boolean = false
  @Trace public display: SessionDisplayDescriptor = emptyDisplayDescriptor()
  // 来源/发送方式标签（LocalSend / 互传 / 网页等），详情页设备卡徽标展示
  @Trace public sourceLabel: ResourceStr = ''
  @Trace public capabilities: SessionCapabilities = defaultCapabilities()
  @Trace public files: Array<SessionFile> = []
  @Trace public timeline: Array<SessionTimelineEvent> = []
  // 详情完整信息（实时会话与历史条目统一取数）
  @Trace public meta: SessionDetailMeta = emptySessionDetailMeta()
  // 历史条目的逐文件清单与时间线（会话回收后仍可读）
  @Trace public historyFiles: Array<SessionFile> = []
  @Trace public historyTimeline: Array<SessionTimelineEvent> = []
  // 内联预览文本（单文本文件时于刷新中按路径读取；渲染期不读盘）与「内容不可用」标记
  @Trace public previewText: string = ''
  @Trace public previewUnavailable: boolean = false
  // 实时速度（B/s，0 表示不可用）与预计剩余秒数（-1 表示不可用）
  @Trace public speed: number = 0
  @Trace public etaSeconds: number = -1
  // 自动完成信号：本次加载的会话进入终态且「自动完成」开启时置位，页面消费后置空
  @Trace public autoFinishRequested: boolean = false

  private sessionId: string = ''
  private subscribed: boolean = false
  private speedEstimator: SpeedEstimator = new SpeedEstimator()
  private lastSyncMs: number = 0
  // 是否观察到过进行中阶段：仅在「进行中 → 终态」的跃迁上触发自动完成，
  // 直接打开一个已终结会话（终态可见窗口内/历史摘要）不触发，避免刚进入即被自动返回
  private autoFinishArmed: boolean = false
  private changeCallback: () => void = (): void => {
  }

  /** 载入会话并订阅注册表变化。 */
  load(sessionId: string): void {
    this.sessionId = sessionId;
    this.autoFinishArmed = false;
    this.autoFinishRequested = false;
    // 载入新会话时复位「实时会话已释放」标记
    this.liveReleased = false;
    // 切换会话时复位速度采样与展示，避免残留前一会话的速度/剩余时间
    this.speedEstimator.reset();
    this.speed = 0;
    this.etaSeconds = -1;
    this.lastSyncMs = 0;
    // 切换会话时复位完整信息与历史快照，避免残留上一会话数据
    this.meta = emptySessionDetailMeta();
    this.historyFiles = [];
    this.historyTimeline = [];
    this.previewText = '';
    this.previewUnavailable = false;
    this.sourceLabel = '';
    if (!this.subscribed) {
      this.changeCallback = (): void => {
        this.refresh();
      };
      subscribeSessions(this.changeCallback);
      this.subscribed = true;
    }
    this.refresh();
  }

  unload(): void {
    if (this.subscribed) {
      unsubscribeSessions(this.changeCallback);
      this.subscribed = false;
    }
  }

  /** 会话（实时或历史摘要）是否已加载。 */
  isLoaded(): boolean {
    return this.session !== undefined || this.historyEntry !== undefined;
  }

  /** 是否为历史台账只读摘要（注册表内已无该会话，无逐文件进度与时间线）。 */
  isReadOnly(): boolean {
    return this.historyEntry !== undefined;
  }

  /** 当前统一状态（实时会话实时读取，历史条目取结果映射）。 */
  currentStage(): SessionStage {
    return this.session !== undefined ? this.session.stage : this.historyStage();
  }

  /** 是否为发送方向（实时会话取数据流向；历史条目取归档的数据流向）。 */
  isOutbound(): boolean {
    if (this.session !== undefined) {
      return this.session.dataFlow === SessionDataFlow.outbound;
    }
    return this.historyEntry !== undefined && this.historyEntry.dataFlow === SessionDataFlow.outbound;
  }

  /** 当前展示的逐文件清单（实时会话或历史条目）。 */
  detailFiles(): Array<SessionFile> {
    return this.session !== undefined ? this.files : this.historyFiles;
  }

  /** 当前展示的时间线（实时会话或历史条目）。 */
  detailTimeline(): Array<SessionTimelineEvent> {
    return this.session !== undefined ? this.timeline : this.historyTimeline;
  }

  /** 从注册表重新读取会话/文件/时间线/描述符，并同步速度显示与自动完成信号。 */
  refresh(): void {
    let session = getSession(this.sessionId);
    if (session === undefined) {
      if (this.session !== undefined) {
        // 会话已离开注册表（可见窗口结束被回收）：优先回退历史只读摘要；
        // 历史也不可得（如用户清空历史）时保留最后快照并禁用全部动作，避免「可点但无响应」
        this.loadHistoryEntry();
        if (this.historyEntry !== undefined) {
          this.session = undefined;
          this.liveReleased = false;
        } else {
          this.liveReleased = true;
        }
        return;
      }
      if (this.historyEntry === undefined) {
        // 从未加载到会话：按历史条目标识加载只读摘要（终态可见窗口结束后的入口）
        this.loadHistoryEntry();
      }
      return;
    }
    this.liveReleased = false;
    this.historyEntry = undefined;
    this.session = session;
    this.files = session.files;
    this.timeline = session.timeline;
    this.meta = liveDetailMeta(session);
    this.capabilities = getSessionCapabilities(session);
    let adapter = getAdapter(session.protocolKey);
    this.display = adapter !== undefined ? adapter.getDisplayDescriptor(session.id) : emptyDisplayDescriptor();
    this.sourceLabel = sourceLabelForProtocol(session.protocolKey);
    this.syncSpeed(session);
    this.applyAutoFinish(session);
    this.refreshPreviewContent();
  }

  /** 从持久化历史条目加载只读摘要（对端/方向/来源协议/结果/时间等由条目提供）。 */
  private loadHistoryEntry(): void {
    let entries: Array<SessionHistoryEntry> = getHistory();
    let entry: SessionHistoryEntry | undefined = undefined;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].sessionId === this.sessionId) {
        entry = entries[i];
        break;
      }
    }
    if (entry === undefined) {
      // 结构化诊断：该标识在历史台账中解析不到（条目已被清除，或从未归档）。
      // 不改动既有展示降级逻辑（保留最后快照并禁用动作）。
      logger.warn(`历史条目解析失败 会话标识=${this.sessionId} 历史条数=${entries.length}`);
      return;
    }
    this.historyEntry = entry;
    this.meta = historyDetailMeta(entry);
    let historyFiles: Array<SessionFile> = [];
    for (let i = 0; i < entry.files.length; i++) {
      historyFiles.push(historyFileToSessionFile(entry.files[i]));
    }
    this.historyFiles = historyFiles;
    this.historyTimeline = entry.timeline;
    let display: SessionDisplayDescriptor = emptyDisplayDescriptor();
    display.peerTitle = entry.peerName;
    display.peerSubtitle = '';
    display.deviceType = 'mobile';
    display.directionLabel = directionLabelFor(entry.dataFlow);
    display.supportsTextPreview = false;
    this.display = display;
    this.sourceLabel = sourceLabelForProtocol(entry.protocolKey);
    this.capabilities = defaultCapabilities();
    this.speed = 0;
    this.etaSeconds = -1;
    // 历史态预览按逐文件路径读取（与实时态同规则）
    this.refreshPreviewContent();
  }

  /**
   * 自动完成信号：会话在本次浏览期间由非终态进入终态且「自动完成」开启时置位；
   * 文本消息阅读场景（需用户阅读/复制内容）不自动返回。
   */
  private applyAutoFinish(session: TransferSession): void {
    if (!isTerminalStage(session.stage)) {
      this.autoFinishArmed = true;
      return;
    }
    if (!this.autoFinishArmed) {
      return;
    }
    this.autoFinishArmed = false;
    if (!isAutoFinish() || this.hasTextPreview()) {
      return;
    }
    this.autoFinishRequested = true;
  }

  /** 历史条目的统一状态（供详情状态徽标复用同一套文案/配色）。 */
  historyStage(): SessionStage {
    return this.historyEntry !== undefined ? stageForOutcome(this.historyEntry.outcome) : SessionStage.succeeded;
  }

  private syncSpeed(session: TransferSession): void {
    if (isTerminalStage(session.stage) || !session.capabilities.hasByteProgress) {
      this.speed = 0;
      this.etaSeconds = -1;
      return;
    }
    let now: number = Date.now();
    this.speedEstimator.update(session.bytesSent, now);
    if (now - this.lastSyncMs < DISPLAY_SYNC_INTERVAL) {
      return;
    }
    this.lastSyncMs = now;
    let speed: number = this.speedEstimator.getSpeed();
    if (speed <= 0 || this.speedEstimator.isStale(now, SPEED_STALE_MS)) {
      this.speed = 0;
      this.etaSeconds = -1;
    } else {
      this.speed = speed;
      this.etaSeconds = this.speedEstimator.etaSeconds(session.totalBytes, session.bytesSent);
    }
  }

  // ── 动作可用性（按状态与能力声明；不可用动作不展示为可执行） ──

  canConfirm(): boolean {
    if (this.liveReleased) {
      return false;
    }
    return this.session !== undefined && this.session.stage === SessionStage.awaitingConfirmation &&
      this.capabilities.needsConfirm;
  }

  canDecline(): boolean {
    if (this.liveReleased) {
      return false;
    }
    // 与确认动作同源：仅当适配器声明需要确认且处于待确认态时可拒绝
    return this.session !== undefined && this.session.stage === SessionStage.awaitingConfirmation &&
      this.capabilities.needsConfirm;
  }

  canCancel(): boolean {
    if (this.liveReleased) {
      return false;
    }
    return this.session !== undefined && !isTerminalStage(this.session.stage) && this.capabilities.canCancel;
  }

  canVerify(): boolean {
    return this.session !== undefined && this.capabilities.hasVerify &&
      this.session.peer.fingerprint !== undefined && (this.session.peer.fingerprint ?? '').length > 0;
  }

  hasByteProgress(): boolean {
    return this.capabilities.hasByteProgress && this.session !== undefined && this.session.totalBytes > 0;
  }

  /** 是否为文本消息会话（携带可复制的文本内容）。 */
  hasTextPreview(): boolean {
    return isTextSessionDescriptor(this.display);
  }

  /** 当前预览模式（实时态与历史态同规则）。 */
  previewMode(): SessionPreviewMode {
    return decidePreviewMode(this.detailFiles());
  }

  /** 是否为内联文本预览（会话仅一个文本类文件）。 */
  isInlinePreview(): boolean {
    return this.previewMode() === SessionPreviewMode.inline;
  }

  /** 某条目是否为文本类文件（多文件时提供点击预览入口）。 */
  isTextFileEntry(file: SessionFile): boolean {
    return isTextFile(file.fileType, file.fileName);
  }

  /** 按需读取某文件的文本内容（多文件时的点击预览）；失败返回 undefined 表示不可用。 */
  readFileText(file: SessionFile): string | undefined {
    return readTextOfLocation(file.path);
  }

  /**
   * 刷新内联预览内容：仅内联模式时按路径读取（数据变更时执行一次，渲染期不读盘）；
   * 无路径或读取失败时回退展示描述符携带的文本，仍不可用则标记为不可用。
   */
  private refreshPreviewContent(): void {
    this.previewText = '';
    this.previewUnavailable = false;
    if (!this.isInlinePreview()) {
      return;
    }
    let file = this.detailFiles()[0];
    if (file.path.length > 0) {
      let content = readTextOfLocation(file.path);
      if (content !== undefined) {
        this.previewText = content;
        return;
      }
    }
    let fallback = this.display.textPreview;
    if (fallback !== undefined && fallback.length > 0) {
      this.previewText = fallback;
      return;
    }
    this.previewUnavailable = true;
  }

  /** 会话文本内容：优先内联预览读到的内容，其次展示描述符携带的文本（无文本时为空串）。 */
  textPreview(): string {
    if (this.previewText.length > 0) {
      return this.previewText;
    }
    let text = this.display.textPreview;
    return text !== undefined ? text : '';
  }

  /** 会话整体进度百分比。 */
  percent(): number {
    if (this.session === undefined || this.session.totalBytes <= 0) {
      return 0;
    }
    let pct: number = (this.session.bytesSent * 100) / this.session.totalBytes;
    return pct > 100 ? 100 : pct;
  }

  peerFingerprint(): string {
    return this.session !== undefined ? (this.session.peer.fingerprint ?? '') : '';
  }

  // ── 动作 ──

  confirm(): void {
    confirmSession(this.sessionId);
  }

  decline(): void {
    declineSession(this.sessionId);
  }

  /** 取消（独立显式操作；页面返回不触发）。 */
  cancelTransfer(): void {
    logger.debug('cancel session ' + this.sessionId);
    registryCancel(this.sessionId);
  }
}
