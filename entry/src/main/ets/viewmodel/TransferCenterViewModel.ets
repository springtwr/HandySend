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
  getClearableCount,
  getHistory,
  getPendingCount,
  retry,
  subscribeSessions,
  unsubscribeSessions
} from '../service/transfer/TransferSessionRegistry';
import { getSource } from '../service/transfer/DeviceSourceRegistry';
import { getAdapter, isTextSessionDescriptor } from '../service/transfer/adapters/SessionAdapter';
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
  // 条目渲染键：即会话标识，与会话一一对应且与会话生命周期同寿命。
  // 键中不携带「来源」（实时/历史），故同一会话由实时条目转为历史条目时身份不变。
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
  // 是否文本消息会话：构建期由展示描述符预计算（历史行恒为假，不提供文本动作）
  isTextSession: boolean
  // 文本消息内容：仅文本会话的实时行非空（供列表「复制」写剪贴板，渲染期零适配器访问）
  textPreview: string
}

/** 由注册表内会话构建行模型（持有会话对象引用，状态/进度实时绑定）。 */
export function liveSessionRow(session: TransferSession): SessionRowModel {
  let ts: number = sessionTimestamp(session.startedAt, session.finishedAt);
  let adapter = getAdapter(session.protocolKey);
  let descriptor = adapter !== undefined ? adapter.getDisplayDescriptor(session.id) : undefined;
  let isText: boolean = descriptor !== undefined && isTextSessionDescriptor(descriptor);
  let preview: string = '';
  if (isText && descriptor !== undefined && descriptor.textPreview !== undefined) {
    preview = descriptor.textPreview;
  }
  return {
    key: session.id,
    sessionId: session.id,
    peerName: session.peer.displayName,
    timeText: formatTime(ts),
    directionLabel: directionLabelFor(session.dataFlow),
    sourceLabel: sourceLabelForProtocol(session.protocolKey),
    fileCountText: $r('app.string.transfer_center_file_count', session.files.length),
    timestamp: ts,
    session: session,
    isTextSession: isText,
    textPreview: preview
  };
}

/** 由持久化历史条目构建行模型（无实时对象，保留终态快照）。 */
export function historyEntryRow(entry: SessionHistoryEntry): SessionRowModel {
  let ts: number = sessionTimestamp(entry.startedAt, entry.finishedAt);
  return {
    key: entry.sessionId,
    sessionId: entry.sessionId,
    peerName: entry.peerName,
    timeText: formatTime(ts),
    directionLabel: directionLabelFor(entry.dataFlow),
    sourceLabel: sourceLabelForProtocol(entry.protocolKey),
    fileCountText: $r('app.string.transfer_center_file_count', entry.fileCount),
    timestamp: ts,
    historyStage: stageForOutcome(entry.outcome),
    isTextSession: false,
    textPreview: ''
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

/** 行是否文本消息会话（构建期预计算的标志；历史行恒为假）。 */
export function rowIsTextSession(row: SessionRowModel): boolean {
  return row.isTextSession;
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
 * 合并可见会话行与历史行：按统一会话标识去重（同一会话在终态可见窗口内只保留可见行）。
 * 实时条目数组先于历史条目数组遍历，故去重保留实时条目，维持「实时条目优先」的既有语义。
 * 本函数只做合并与去重，顺序由后续的确定性排序步骤决定。
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
  return rows;
}

/**
 * 按会话标识兜底去重（纯函数，无副作用）：同一会话标识只保留首次出现者。
 * 输入为「合并去重」后的行序列（实时条目在前），保留首现即保留实时条目，
 * 与合并阶段同口径维持「实时条目优先」；作为行序列构建期的第二道防重复保障，
 * 从结构上保证「同一会话最多一行」。
 */
export function dedupeSessionRows(rows: Array<SessionRowModel>): Array<SessionRowModel> {
  let seen: Array<string> = [];
  let result: Array<SessionRowModel> = [];
  for (let i = 0; i < rows.length; i++) {
    let row = rows[i];
    if (seen.indexOf(row.sessionId) < 0) {
      seen.push(row.sessionId);
      result.push(row);
    }
  }
  return result;
}

/**
 * 确定性排序（纯函数，无副作用）：主键为会话时间倒序；主键相等时以会话标识字典序升序为
 * 次级键，使同一秒内创建的多条会话顺序完全确定、可断言，不因来源遍历顺序而抖动。
 */
export function sortSessionRows(rows: Array<SessionRowModel>): Array<SessionRowModel> {
  let result: Array<SessionRowModel> = [];
  for (let i = 0; i < rows.length; i++) {
    result.push(rows[i]);
  }
  result.sort((a: SessionRowModel, b: SessionRowModel): number => {
    if (a.timestamp !== b.timestamp) {
      return b.timestamp - a.timestamp;
    }
    if (a.sessionId < b.sessionId) {
      return -1;
    }
    if (a.sessionId > b.sessionId) {
      return 1;
    }
    return 0;
  });
  return result;
}

/** 可解析性校验结果：可保留行与被剔除行。 */
export interface RowValidationResult {
  kept: Array<SessionRowModel>
  dropped: Array<SessionRowModel>
}

/**
 * 条目可解析性校验（纯函数，无副作用）：
 * 以「实时会话标识集合 / 历史记录标识集合」为基准，凡不能解析为
 * 「实时会话（行持有会话对象）或历史记录（行标识命中历史集合）」的行一律剔除，
 * 保证列表中的每一条目都可进入详情（实时状态或历史只读摘要）。
 */
export function validateSessionRows(rows: Array<SessionRowModel>,
  liveIds: Array<string>, historyIds: Array<string>): RowValidationResult {
  let kept: Array<SessionRowModel> = [];
  let dropped: Array<SessionRowModel> = [];
  for (let i = 0; i < rows.length; i++) {
    let row = rows[i];
    let resolvable: boolean = row.session !== undefined || liveIds.indexOf(row.sessionId) >= 0 ||
      historyIds.indexOf(row.sessionId) >= 0;
    if (resolvable) {
      kept.push(row);
    } else {
      dropped.push(row);
    }
  }
  return { kept: kept, dropped: dropped };
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

/**
 * 行序列描述（纯函数，无副作用）：输出「行数 + 每行摘要」字符串，
 * 每行含 索引 / 键 / 会话标识 / 时间文案 / 阶段 / 来源标记（实时或历史）。
 * 把数据变更后实际构建出的行序列固化为可检索证据：若摘要各行互不相同而界面仍相同，
 * 即为渲染侧错位；若摘要本身相同，则问题回到数据侧。
 */
export function describeCenterRows(rows: Array<CenterRow>): string {
  let parts: Array<string> = [];
  parts.push('行数=' + rows.length);
  for (let i = 0; i < rows.length; i++) {
    let row = rows[i];
    let session = row.session;
    if (session === undefined) {
      parts.push(`[${i}] 键=${row.key} 类别=${row.kind}`);
      continue;
    }
    // 来源标记：持有实时会话对象的为实时条目，否则为历史条目
    let source: string = session.session !== undefined ? '实时' : '历史';
    parts.push(`[${i}] 键=${row.key} 会话标识=${session.sessionId} 时间=${session.timeText}` +
      ` 阶段=${rowStage(session)} 来源=${source}`);
  }
  return parts.join(' ');
}

@ObservedV2
export class TransferCenterViewModel {
  // 合并后的完整行序列（条目/空态）：数据变更时整体重建
  @Trace public rows: Array<CenterRow> = []
  @Trace public activeCount: number = 0
  // 可清除计数（历史条数 + 已终态可见会话数）：标题栏「清除会话历史」入口的置灰判定依据
  @Trace public clearableCount: number = 0

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
    let liveIds: Array<string> = [];
    for (let i = 0; i < allSessions.length; i++) {
      liveRows.push(liveSessionRow(allSessions[i]));
      liveIds.push(allSessions[i].id);
    }
    let historyRows: Array<SessionRowModel> = [];
    let historyIds: Array<string> = [];
    for (let i = 0; i < allHistory.length; i++) {
      historyRows.push(historyEntryRow(allHistory[i]));
      historyIds.push(allHistory[i].sessionId);
    }
    // 行序列构建流水线（固定顺序）：合并去重 → 兜底去重 → 确定性排序 → 可进入性校验 → 组装。
    // 去重与排序先于校验，使「同一会话最多一行」与「不可解析条目零展示」两条不变式同时成立。
    let merged: Array<SessionRowModel> = mergeSessionRows(liveRows, historyRows);
    let deduped: Array<SessionRowModel> = dedupeSessionRows(merged);
    let sorted: Array<SessionRowModel> = sortSessionRows(deduped);
    // 硬性不变式：列表每一条目都必须可解析为实时会话或历史记录，
    // 不可解析的条目一律剔除并留痕（不做静默渲染）
    let validated: RowValidationResult = validateSessionRows(sorted, liveIds, historyIds);
    this.logDroppedRows(validated.dropped);
    this.rows = this.composeRows(validated.kept);
    // 行序列转储：内容与本次构建的行序列同源，用于区分数据侧正确与渲染侧错位；
    // 刷新由进度高频驱动，降为 debug 避免刷屏
    logger.debug('行序列转储 ' + describeCenterRows(this.rows));
    this.activeCount = getActiveCount();
    // 置灰口径与清除动作同源：可清除计数为零 ⇔ 入口置灰
    this.clearableCount = getClearableCount();
  }

  /** 输出被剔除条目的结构化诊断（会话标识〔即条目身份〕/ 是否仍持有实时会话对象）。 */
  private logDroppedRows(dropped: Array<SessionRowModel>): void {
    for (let i = 0; i < dropped.length; i++) {
      let row = dropped[i];
      // 条目身份即会话标识（二者同值），诊断输出一次会话标识即可
      logger.warn(`剔除不可解析条目 会话标识=${row.sessionId}` +
        ` 持有实时会话=${row.session !== undefined} 历史阶段快照=${row.historyStage !== undefined}`);
    }
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
   * 清除会话历史：清空持久化历史 + 移除已终态可见会话条目；不触碰进行中与待确认会话。
   * 清空动作自身会发布变更总线通知，列表与标题栏入口的置灰状态随通知自动重算。
   */
  clearHistory(): void {
    clearSessionHistoryFromRegistry();
  }

  pendingCount(): number {
    return getPendingCount();
  }
}
