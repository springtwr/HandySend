/**
 * TransferCenterViewModel.ets — 传输中心视图模型
 *
 * 从统一注册表读取全部会话与会话历史，合并为**单一「会话」列表**：
 * - 进行中 / 待确认 / 终态可见窗口内会话与持久化历史同处一个列表；
 * - 按会话创建时间倒序（历史条目无创建时间时回退完成时间）；
 * - 同一会话在终态可见窗口内与持久化历史按统一会话标识去重，只渲染一次。
 *
 * 行模型在数据变更时一次性构建并缓存于 @Trace 字段（build 直接引用，不在渲染中重算），
 * 行内文案为预计算字符串或 ResourceStr，渲染期不做同步资源读取。
 * 分组、去重、合并排序均为纯函数，可独立测试。
 * 列表标题与页面级入口由外层标题栏承载，行序列不含标题行。
 */

import {
  SessionDataFlow,
  SessionHistoryOutcome,
  SessionStage,
  TransferSession,
  isTerminalStage
} from '../model/transfer/TransferSession';
import { SessionHistoryEntry } from '../model/transfer/SessionHistory';
import {
  cancel,
  clearHistory as clearSessionHistoryFromRegistry,
  confirmSession,
  declineSession,
  getActiveCount,
  getAllSessions,
  getHistory,
  getPendingCount,
  retry,
  subscribeSessions,
  unsubscribeSessions
} from '../service/transfer/TransferSessionRegistry';
import { getSource } from '../service/transfer/DeviceSourceRegistry';
import { formatTime } from '../utils/FormatUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TransferCenter', '传输中心');

// ── 纯逻辑辅助（可独立测试） ──

/** 由协议键派生来源键（协议键形如 localsend-send / mta-receive / web-download）。 */
export function sessionSourceKey(protocolKey: string): string {
  let idx: number = protocolKey.indexOf('-');
  return idx > 0 ? protocolKey.substring(0, idx) : protocolKey;
}

/** 分组结果。 */
export interface TransferCenterGroups {
  active: Array<TransferSession>
  pending: Array<TransferSession>
  terminal: Array<TransferSession>
}

/** 按统一状态分组（进行中 / 待确认 / 终态可见窗口）。 */
export function groupSessions(sessions: Array<TransferSession>): TransferCenterGroups {
  let active: Array<TransferSession> = [];
  let pending: Array<TransferSession> = [];
  let terminal: Array<TransferSession> = [];
  for (let i = 0; i < sessions.length; i++) {
    let s = sessions[i];
    if (s.stage === SessionStage.awaitingConfirmation) {
      pending.push(s);
    } else if (isTerminalStage(s.stage)) {
      terminal.push(s);
    } else {
      active.push(s);
    }
  }
  return { active: active, pending: pending, terminal: terminal };
}

/** 批量取消目标集合：全部非终态会话的标识（终态与本会话历史不受影响）。 */
export function collectActiveSessionIds(sessions: Array<TransferSession>): Array<string> {
  let result: Array<string> = [];
  for (let i = 0; i < sessions.length; i++) {
    if (!isTerminalStage(sessions[i].stage)) {
      result.push(sessions[i].id);
    }
  }
  return result;
}

/** 历史结果 → 统一状态（供状态徽标复用同一套文案/配色）。 */
export function stageForOutcome(outcome: SessionHistoryOutcome): SessionStage {
  if (outcome === SessionHistoryOutcome.partiallyFailed) {
    return SessionStage.partiallyFailed;
  }
  if (outcome === SessionHistoryOutcome.failed) {
    return SessionStage.failed;
  }
  if (outcome === SessionHistoryOutcome.cancelled) {
    return SessionStage.cancelled;
  }
  if (outcome === SessionHistoryOutcome.declined) {
    return SessionStage.declined;
  }
  return SessionStage.succeeded;
}

/**
 * 传输方向文案：inbound=来自（接收）；outbound=发给（含本机主动发送与被对端拉取的网页下载）。
 */
export function directionLabelFor(dataFlow: SessionDataFlow): ResourceStr {
  if (dataFlow === SessionDataFlow.inbound) {
    return $r('app.string.session_direction_receive');
  }
  return $r('app.string.session_direction_send');
}

/** 来源键 → 展示标签（无描述符时回退来源键）。 */
export function sourceLabelForProtocol(protocolKey: string): ResourceStr {
  let key: string = sessionSourceKey(protocolKey);
  let descriptor = getSource(key);
  if (descriptor !== undefined) {
    return descriptor.label;
  }
  return key;
}

/** 会话时间戳：优先创建时间，缺失时回退完成时间。 */
function sessionTimestamp(startedAt: number, finishedAt: number): number {
  return startedAt > 0 ? startedAt : finishedAt;
}

/** 会话百分比（分母为 0 时返回 0）。 */
function percentOfBytes(bytesSent: number, totalBytes: number): number {
  if (totalBytes <= 0) {
    return 0;
  }
  let pct: number = (bytesSent * 100) / totalBytes;
  return pct > 100 ? 100 : pct;
}

// ── 行模型 ──

/**
 * 统一会话行：注册表内可见会话（进行中/待确认/终态窗口）与持久化历史条目同构。
 * 稳定展示值（时间戳/方向/来源/昵称/排序键）在构建时预计算；
 * 实时会话行持有统一会话对象引用，状态/进度/阶段文案直接读其 @Trace 字段，
 * 与详情页同源同口径（不再缓存易变快照，从根本上消除「条目传输中而详情已完成」的分叉）。
 * 历史条目行无实时对象，保留终态快照用于状态徽标。
 */
export interface SessionRowModel {
  key: string
  sessionId: string
  peerName: string
  // 已格式化的会话时间文案（精确到秒）
  timeText: string
  directionLabel: ResourceStr
  sourceLabel: ResourceStr
  // 文件数量文案（复用统一资源口径）
  fileCountText: ResourceStr
  // 排序用时间戳（创建时间，缺失回退完成时间）
  timestamp: number
  // 实时会话对象引用（历史条目行为 undefined，走 historyStage 快照）
  session?: TransferSession
  // 历史条目行的终态快照（仅历史行使用）
  historyStage?: SessionStage
}

/** 由注册表内会话构建行模型（持有会话对象引用，状态/进度实时绑定）。 */
export function liveSessionRow(session: TransferSession): SessionRowModel {
  let ts: number = sessionTimestamp(session.startedAt, session.finishedAt);
  return {
    key: 'live_' + session.id,
    sessionId: session.id,
    peerName: session.peer.displayName,
    timeText: formatTime(ts),
    directionLabel: directionLabelFor(session.dataFlow),
    sourceLabel: sourceLabelForProtocol(session.protocolKey),
    fileCountText: $r('app.string.transfer_center_file_count', session.files.length),
    timestamp: ts,
    session: session
  };
}

/** 由持久化历史条目构建行模型（无实时对象，保留终态快照）。 */
export function historyEntryRow(entry: SessionHistoryEntry): SessionRowModel {
  let ts: number = sessionTimestamp(entry.startedAt, entry.finishedAt);
  return {
    key: 'history_' + entry.sessionId + '_' + entry.schemaVersion,
    sessionId: entry.sessionId,
    peerName: entry.peerName,
    timeText: formatTime(ts),
    directionLabel: directionLabelFor(entry.dataFlow),
    sourceLabel: sourceLabelForProtocol(entry.protocolKey),
    fileCountText: $r('app.string.transfer_center_file_count', entry.fileCount),
    timestamp: ts,
    historyStage: stageForOutcome(entry.outcome)
  };
}

// ── 行状态读取（实时行读会话对象，历史行走快照） ──

/** 行统一状态。 */
export function rowStage(row: SessionRowModel): SessionStage {
  return row.session !== undefined ? row.session.stage : (row.historyStage ?? SessionStage.succeeded);
}

/** 行是否终态。 */
export function rowIsTerminal(row: SessionRowModel): boolean {
  return isTerminalStage(rowStage(row));
}

/** 行是否待确认（仅实时行可能为真）。 */
export function rowAwaitingConfirm(row: SessionRowModel): boolean {
  return row.session !== undefined && row.session.stage === SessionStage.awaitingConfirmation;
}

/** 行离散阶段文案（仅实时行有值）。 */
export function rowStageText(row: SessionRowModel): ResourceStr {
  return row.session !== undefined ? row.session.stageText : '';
}

/** 行是否具备字节级进度且可直接展示百分比（无字节进度或分母为 0 时为假）。 */
export function rowHasByteProgress(row: SessionRowModel): boolean {
  return row.session !== undefined && row.session.capabilities.hasByteProgress && row.session.totalBytes > 0;
}

/** 行整体进度百分比（实时行按会话对象实时计算，历史行恒为 0）。 */
export function rowPercent(row: SessionRowModel): number {
  return row.session !== undefined ? percentOfBytes(row.session.bytesSent, row.session.totalBytes) : 0;
}

/**
 * 合并可见会话行与历史行：按统一会话标识去重（同一会话在终态可见窗口内只保留可见行），
 * 并按会话时间倒序排列。
 */
export function mergeSessionRows(live: Array<SessionRowModel>,
  history: Array<SessionRowModel>): Array<SessionRowModel> {
  let rows: Array<SessionRowModel> = [];
  for (let i = 0; i < live.length; i++) {
    rows.push(live[i]);
  }
  for (let i = 0; i < history.length; i++) {
    let duplicated: boolean = false;
    for (let k = 0; k < rows.length; k++) {
      if (rows[k].sessionId === history[i].sessionId) {
        duplicated = true;
        break;
      }
    }
    if (!duplicated) {
      rows.push(history[i]);
    }
  }
  rows.sort((a: SessionRowModel, b: SessionRowModel): number => b.timestamp - a.timestamp);
  return rows;
}

// 扁平列表行类别：会话条目行与空态行由单一 Repeat 承载
// （列表标题与入口已迁入外层标题栏，行序列不再包含标题行）
export const ROW_SESSION: string = 'session';
export const ROW_EMPTY: string = 'empty';

/** 扁平列表行：空态与条目同构，保证整个列表只由一个 Repeat 生成。 */
export interface CenterRow {
  key: string
  kind: string
  session?: SessionRowModel
}

@ObservedV2
export class TransferCenterViewModel {
  // 合并后的完整行序列（条目/空态）：数据变更时整体重建
  @Trace public rows: Array<CenterRow> = []
  @Trace public activeCount: number = 0
  // 持久化历史条数（作为标题栏「清除会话历史」入口的置灰判定依据）
  @Trace public historyCount: number = 0

  private subscribed: boolean = false
  // 变更总线回调需保持同一引用以便退订
  private changeCallback: () => void = (): void => {
  }

  /** 订阅注册表变化并首次加载。 */
  start(): void {
    if (!this.subscribed) {
      this.changeCallback = (): void => {
        this.refresh();
      };
      subscribeSessions(this.changeCallback);
      this.subscribed = true;
    }
    this.refresh();
  }

  stop(): void {
    if (this.subscribed) {
      unsubscribeSessions(this.changeCallback);
      this.subscribed = false;
    }
  }

  /** 从注册表重新读取并重建合并列表（数据变更时调用一次，不在渲染中重算）。 */
  refresh(): void {
    let allSessions: Array<TransferSession> = getAllSessions();
    let allHistory: Array<SessionHistoryEntry> = getHistory();

    let liveRows: Array<SessionRowModel> = [];
    for (let i = 0; i < allSessions.length; i++) {
      liveRows.push(liveSessionRow(allSessions[i]));
    }
    let historyRows: Array<SessionRowModel> = [];
    for (let i = 0; i < allHistory.length; i++) {
      historyRows.push(historyEntryRow(allHistory[i]));
    }
    this.rows = this.composeRows(mergeSessionRows(liveRows, historyRows));
    this.activeCount = getActiveCount();
    this.historyCount = allHistory.length;
  }

  /**
   * 组装完整行序列：会话条目（或空态）。
   * 条目同处一个序列，由列表的单一虚拟滚动 Repeat 统一承载。
   */
  private composeRows(sessionRows: Array<SessionRowModel>): Array<CenterRow> {
    let rows: Array<CenterRow> = [];
    if (sessionRows.length === 0) {
      rows.push({ key: 'empty', kind: ROW_EMPTY });
    } else {
      for (let i = 0; i < sessionRows.length; i++) {
        rows.push({ key: sessionRows[i].key, kind: ROW_SESSION, session: sessionRows[i] });
      }
    }
    return rows;
  }

  // ── 交互动作 ──

  confirm(sessionId: string): void {
    logger.debug('confirm session ' + sessionId);
    confirmSession(sessionId);
  }

  decline(sessionId: string): void {
    logger.debug('decline session ' + sessionId);
    declineSession(sessionId);
  }

  cancelSession(sessionId: string): void {
    cancel(sessionId);
  }

  retrySession(sessionId: string): void {
    retry(sessionId);
  }

  /**
   * 清除会话历史（不影响进行中会话与终态可见窗口内的会话）。
   * 清空动作自身会发布变更总线通知，列表与标题栏入口的置灰状态随通知自动重算。
   */
  clearHistory(): void {
    clearSessionHistoryFromRegistry();
  }

  pendingCount(): number {
    return getPendingCount();
  }
}
