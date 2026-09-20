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
  SessionFile,
  SessionStage,
  SessionTimelineEvent,
  TransferSession,
  defaultCapabilities,
  isTerminalStage
} from '../model/transfer/TransferSession';
import { SessionHistoryEntry } from '../model/transfer/SessionHistory';
import {
  cancel as registryCancel,
  confirmSession,
  declineSession,
  getHistory,
  getSession,
  getSessionCapabilities,
  retry as registryRetry,
  subscribeSessions,
  unsubscribeSessions
} from '../service/transfer/TransferSessionRegistry';
import { emptyDisplayDescriptor, getAdapter } from '../service/transfer/adapters/SessionAdapter';
import { isAutoFinish } from '../service/repository/SettingsRepository';
// 来源标签、方向文案与历史结果 → 统一状态映射与传输中心列表同源（同一套纯函数，避免两处口径分叉）
import { directionLabelFor, sourceLabelForProtocol, stageForOutcome } from './TransferCenterViewModel';
import { MediaFileInfo } from '../model/Types';
import { SpeedEstimator } from '../utils/SpeedEstimator';
import { formatTime } from '../utils/FormatUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionDetail', '会话详情');

/** 详情页路由参数（按统一会话标识进入）。 */
export interface SessionDetailParams {
  sessionId: string
}

// 速度显示同步间隔与过期阈值（毫秒）
const DISPLAY_SYNC_INTERVAL: number = 1000;
const SPEED_STALE_MS: number = 3000;

@ObservedV2
export class SessionDetailViewModel {
  @Trace public session: TransferSession | undefined = undefined
  // 注册表内已无该会话时回退加载的持久化历史条目（只读摘要，无逐文件进度与时间线）
  @Trace public historyEntry: SessionHistoryEntry | undefined = undefined
  @Trace public display: SessionDisplayDescriptor = emptyDisplayDescriptor()
  @Trace public capabilities: SessionCapabilities = defaultCapabilities()
  @Trace public files: Array<SessionFile> = []
  @Trace public timeline: Array<SessionTimelineEvent> = []
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

  /** 从注册表重新读取会话/文件/时间线/描述符，并同步速度显示与自动完成信号。 */
  refresh(): void {
    let session = getSession(this.sessionId);
    if (session === undefined) {
      if (this.session !== undefined) {
        // 会话已在终态可见窗口结束后被回收（如接收完成）。保留最后一次快照，
        // 使详情页继续呈现终态结果而非退化为空白占位页。
        return;
      }
      if (this.historyEntry === undefined) {
        // 从未加载到会话：按历史条目标识加载只读摘要（终态可见窗口结束后的入口）
        this.loadHistoryEntry();
      }
      return;
    }
    this.historyEntry = undefined;
    this.session = session;
    this.files = session.files;
    this.timeline = session.timeline;
    this.capabilities = getSessionCapabilities(session);
    let adapter = getAdapter(session.protocolKey);
    this.display = adapter !== undefined ? adapter.getDisplayDescriptor(session.id) : emptyDisplayDescriptor();
    this.syncSpeed(session);
    this.applyAutoFinish(session);
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
      return;
    }
    this.historyEntry = entry;
    let display: SessionDisplayDescriptor = emptyDisplayDescriptor();
    display.peerTitle = entry.peerName;
    display.peerSubtitle = '';
    display.deviceType = 'mobile';
    display.directionLabel = directionLabelFor(entry.dataFlow, entry.initiatedBy);
    display.supportsTextPreview = false;
    this.display = display;
    this.capabilities = defaultCapabilities();
    this.speed = 0;
    this.etaSeconds = -1;
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

  /** 历史条目的统一状态（供只读摘要的状态徽标复用同一套文案/配色）。 */
  historyStage(): SessionStage {
    return this.historyEntry !== undefined ? stageForOutcome(this.historyEntry.outcome) : SessionStage.succeeded;
  }

  /** 历史条目的来源协议展示标签。 */
  historySourceLabel(): ResourceStr {
    return this.historyEntry !== undefined ? sourceLabelForProtocol(this.historyEntry.protocolKey) : '';
  }

  /** 历史条目的会话时间文案。 */
  historyTimeText(): string {
    if (this.historyEntry === undefined) {
      return '';
    }
    let ts: number = this.historyEntry.startedAt > 0 ? this.historyEntry.startedAt : this.historyEntry.finishedAt;
    return formatTime(ts);
  }

  historyFileCount(): number {
    return this.historyEntry !== undefined ? this.historyEntry.fileCount : 0;
  }

  historyTotalBytes(): number {
    return this.historyEntry !== undefined ? this.historyEntry.totalBytes : 0;
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
    return this.session !== undefined && this.session.stage === SessionStage.awaitingConfirmation &&
      this.capabilities.needsConfirm;
  }

  canDecline(): boolean {
    // 与确认动作同源：仅当适配器声明需要确认且处于待确认态时可拒绝
    return this.session !== undefined && this.session.stage === SessionStage.awaitingConfirmation &&
      this.capabilities.needsConfirm;
  }

  canCancel(): boolean {
    return this.session !== undefined && !isTerminalStage(this.session.stage) && this.capabilities.canCancel;
  }

  canRetry(): boolean {
    return this.session !== undefined && isTerminalStage(this.session.stage) && this.capabilities.canRetry &&
      this.session.dataFlow === SessionDataFlow.outbound;
  }

  /** 保存到相册为完成态下的次级入口（不常驻按钮，经标题栏菜单触发）。 */
  canSaveToGallery(): boolean {
    return this.session !== undefined && this.capabilities.canSaveToGallery &&
      this.session.stage === SessionStage.succeeded;
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
    return this.display.supportsTextPreview && this.textPreview().length > 0;
  }

  /** 会话文本内容（无文本时为空串）。 */
  textPreview(): string {
    let text = this.display.textPreview;
    return text !== undefined ? text : '';
  }

  /** 该会话可保存到相册的媒体文件（由适配器提供；未提供时返回空数组）。 */
  galleryMediaFiles(): Array<MediaFileInfo> {
    if (this.session === undefined) {
      return [];
    }
    let adapter = getAdapter(this.session.protocolKey);
    if (adapter !== undefined && adapter.getGalleryMediaFiles !== undefined) {
      return adapter.getGalleryMediaFiles(this.sessionId);
    }
    return [];
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

  retry(): void {
    registryRetry(this.sessionId);
  }
}
