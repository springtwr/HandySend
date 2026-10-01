/**
 * TransferCenterViewModel.ets — 任务视图模型
 *
 * 从统一注册表读取全部会话与任务历史，合并为**单一「会话」列表**：
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
  SessionActionAvailability,
  SessionDataFlow,
  SessionFile,
  SessionHistoryOutcome,
  SessionStage,
  TransferSession,
  isPreparing,
  isTerminalStage,
  resolveSessionActions
} from '../model/transfer/TransferSession';
import { SessionHistoryEntry, SessionHistoryFileEntry } from '../model/transfer/SessionHistory';
import {
  cancel,
  clearHistory as clearSessionHistoryFromRegistry,
  confirmSession,
  declineSession,
  getAllSessions,
  getClearableCount,
  getHistory,
  removeEntriesByIds,
  subscribeSessions,
  unsubscribeSessions
} from '../service/transfer/TransferSessionRegistry';
import { getSource } from '../service/transfer/DeviceSourceRegistry';
import { getAdapter, isTextSessionDescriptor } from '../service/transfer/adapters/SessionAdapter';
import { formatTime } from '../utils/FormatUtil';
import { isTextFile } from '../utils/MimeUtils';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TransferCenter', '任务');

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

/** 批量取消目标集合：全部非终态会话的标识（终态与本任务历史不受影响）。 */
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

/** 传输方向图标：inbound=接收（download）；outbound=发送（upload）。 */
export function directionIconFor(dataFlow: SessionDataFlow): Resource {
  if (dataFlow === SessionDataFlow.inbound) {
    return $r('sys.symbol.download');
  }
  return $r('sys.symbol.upload');
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

/** 网页来源键：对端设备类型为 web 的会话统一归入该来源（浏览器上传/下载）。 */
export const WEB_SOURCE_KEY: string = 'web';

/**
 * 会话感知的来源标签解析：对端设备类型为 web 时解析为 web 来源标签，
 * 否则沿用既有的按协议键解析。
 *
 * 浏览器上传产生的入站会话走局域网接收协议（协议键形如 localsend-receive），
 * 仅按协议键解析会得到 LocalSend；引入「对端设备类型」维度后，网页接收与网页发送
 * 口径一致，普通 LocalSend / 互传来源不受影响。
 */
export function sourceLabelForSession(protocolKey: string, peerDeviceType: string): ResourceStr {
  if (peerDeviceType === WEB_SOURCE_KEY) {
    return sourceLabelForProtocol(WEB_SOURCE_KEY);
  }
  return sourceLabelForProtocol(protocolKey);
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

/**
 * 任务条目「单文本类文件」判定（纯函数，无副作用）：
 * 恰好一个文件且该文件为文本类时返回真，其余情形（多文件、单非文本、空）返回假。
 * 文本类判定复用统一入口（MimeUtils.isTextFile），不在此处比对 MIME/扩展名。
 */
export function isSingleTextFileTask(fileCount: number, fileType: string, fileName: string): boolean {
  return fileCount === 1 && isTextFile(fileType, fileName);
}

/**
 * 行模型文件数量文案（纯函数，无副作用）：命中「恰好一个文本类文件」时用本地化「文本」标签，
 * 其余情形保持既有文件数量文案；实时行与历史行共用同一口径。
 */
function fileCountTextOf(fileCount: number, singleFileType: string,
  singleFileName: string): ResourceStr {
  if (isSingleTextFileTask(fileCount, singleFileType, singleFileName)) {
    return $r('app.string.transfer_center_text_label');
  }
  return $r('app.string.transfer_center_file_count', fileCount);
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
  // 传输方向（inbound=接收 / outbound=发送），供条目方向图标判定
  dataFlow: SessionDataFlow
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
  // 文件数量文案：恰好一个文本类文件时用「文本」标签，否则用文件数量（与历史行同口径）
  let liveFiles: Array<SessionFile> = session.files;
  let onlyFileType: string = liveFiles.length === 1 ? liveFiles[0].fileType : '';
  let onlyFileName: string = liveFiles.length === 1 ? liveFiles[0].fileName : '';
  return {
    key: session.id,
    sessionId: session.id,
    peerName: session.peer.displayName,
    timeText: formatTime(ts),
    directionLabel: directionLabelFor(session.dataFlow),
    dataFlow: session.dataFlow,
    sourceLabel: sourceLabelForSession(session.protocolKey, session.peer.deviceType ?? ''),
    fileCountText: fileCountTextOf(liveFiles.length, onlyFileType, onlyFileName),
    timestamp: ts,
    session: session,
    isTextSession: isText,
    textPreview: preview
  };
}

/** 由持久化历史条目构建行模型（无实时对象，保留终态快照）。 */
export function historyEntryRow(entry: SessionHistoryEntry): SessionRowModel {
  let ts: number = sessionTimestamp(entry.startedAt, entry.finishedAt);
  // 文件数量文案与实时行同口径：历史逐文件清单恰好一个文本类文件时用「文本」标签
  let historyFiles: Array<SessionHistoryFileEntry> = entry.files;
  let onlyFileType: string = historyFiles.length === 1 ? historyFiles[0].fileType : '';
  let onlyFileName: string = historyFiles.length === 1 ? historyFiles[0].fileName : '';
  return {
    key: entry.sessionId,
    sessionId: entry.sessionId,
    peerName: entry.peerName,
    timeText: formatTime(ts),
    directionLabel: directionLabelFor(entry.dataFlow),
    dataFlow: entry.dataFlow,
    sourceLabel: sourceLabelForSession(entry.protocolKey, entry.peerDeviceType),
    fileCountText: fileCountTextOf(entry.fileCount, onlyFileType, onlyFileName),
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

/**
 * 行动作可用性：与详情页共用统一动作规则（单一事实源）。
 * 历史行无实时会话，恒不可用；文本会话仅影响按钮标签，不影响可用性判定。
 */
export function rowActions(row: SessionRowModel): SessionActionAvailability {
  if (row.session === undefined) {
    return { canConfirm: false, canDecline: false, canCancel: false };
  }
  return resolveSessionActions(row.session.stage, row.session.capabilities);
}

/** 行是否文本消息会话（构建期预计算的标志；历史行恒为假）。 */
export function rowIsTextSession(row: SessionRowModel): boolean {
  return row.isTextSession;
}

/**
 * 行是否可勾选删除（纯函数，无副作用）。
 * 可勾选范围与「清除任务历史」的清空口径同源：持久化历史行（终态）与已终态可见会话行可勾选，
 * 进行中与待确认会话不可勾选——这两类会话尚在运行，「删除」对其无意义（对应动作是取消 / 拒绝）。
 * 入参为可选：行缺失（如虚拟滚动期间行数据不可得）时按不可勾选处理。
 */
export function rowDeletable(row?: SessionRowModel): boolean {
  if (row === undefined) {
    return false;
  }
  return row.session === undefined || isTerminalStage(rowStage(row));
}

/** 行离散阶段文案（仅实时行有值）。 */
export function rowStageText(row: SessionRowModel): ResourceStr {
  return row.session !== undefined ? row.session.stageText : '';
}

/** 行是否具备字节级进度且可直接展示百分比（无字节进度或分母为 0 时为假）。 */
export function rowHasByteProgress(row: SessionRowModel): boolean {
  if (row.session === undefined || !row.session.capabilities.hasByteProgress) {
    return false;
  }
  // 准备态以准备进度判定（分母为 prepTotalBytes），其余维持传输口径
  return row.session.totalBytes > 0 || isPreparing(row.session);
}

/** 行整体进度百分比（实时行按会话对象实时计算，历史行恒为 0）；准备态取准备进度口径。 */
export function rowPercent(row: SessionRowModel): number {
  if (row.session === undefined) {
    return 0;
  }
  if (isPreparing(row.session)) {
    return percentOfBytes(row.session.prepBytes, row.session.prepTotalBytes);
  }
  return percentOfBytes(row.session.bytesSent, row.session.totalBytes);
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
 * 每行含 索引 / 会话标识 / 时间文案 / 阶段 / 来源标记（实时或历史）。
 * 条目身份即会话标识（二者同值），故不再重复输出「键」字段。
 * 把数据变更后实际构建出的行序列固化为可检索证据：若摘要各行互不相同而界面仍相同，
 * 即为渲染侧错位；若摘要本身相同，则问题回到数据侧。
 * 本函数输出完整序列，仅供异常信号触发时使用。
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
    parts.push(`[${i}] 会话标识=${session.sessionId} 时间=${session.timeText}` +
      ` 阶段=${rowStage(session)} 来源=${source}`);
  }
  return parts.join(' ');
}

/**
 * 行序列常态摘要（纯函数，无副作用）：仅输出行数、被剔除条数与首尾条目标识，
 * 体积不随记录数线性增长。异常信号触发时才改用 describeCenterRows 输出完整序列。
 */
export function describeCenterRowsSummary(rows: Array<CenterRow>, droppedCount: number): string {
  let head: string = rows.length > 0 ? rows[0].key : '-';
  let tail: string = rows.length > 0 ? rows[rows.length - 1].key : '-';
  return '行序列摘要 行数=' + rows.length + ' 剔除=' + droppedCount +
    ' 首=' + head + ' 尾=' + tail;
}

/** 行序列是否存在重复标识（同键多行）——命中即为异常信号，需输出完整序列 */
export function hasDuplicateRowKeys(rows: Array<CenterRow>): boolean {
  let seen: Set<string> = new Set<string>();
  for (let i = 0; i < rows.length; i++) {
    let rowKey: string = rows[i].key;
    if (seen.has(rowKey)) {
      return true;
    }
    seen.add(rowKey);
  }
  return false;
}

@ObservedV2
export class TransferCenterViewModel {
  // 合并后的完整行序列（条目/空态）：数据变更时整体重建
  @Trace public rows: Array<CenterRow> = []
  // 可清除计数（历史条数 + 已终态可见会话数）：标题栏「清除任务历史」入口的置灰判定依据
  @Trace public clearableCount: number = 0
  // 多选模式：长按条目进入，退出时清空全部勾选
  @Trace public selectionMode: boolean = false
  // 已勾选的会话标识集合：行模型在每次 refresh 时整体重建，勾选状态因此独立于行模型保存，
  // 以会话标识为键，天然跨实时/历史来源切换保持稳定
  @Trace public selectedIds: Array<string> = []
  private subscribed: boolean = false
  // 变更总线回调需保持同一引用以便退订
  private changeCallback: () => void = (): void => {
  }
  // 上一次输出的行序列转储：内容未变时不再重复输出（进度刷新会高频触发 refresh）
  private lastRowDump: string = ''
  // 上一次构建的行序列行数：用于检测「行数相比上次减少」异常信号
  private lastRowCount: number = 0

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
    // 行序列转储：常态仅一行摘要（体积有界，不随记录数增长）；命中「条目被剔除 /
    // 存在重复标识 / 行数相比上次减少」任一异常信号时改输出完整序列，保留排障证据
    let droppedCount: number = validated.dropped.length;
    let shrunk: boolean = this.rows.length < this.lastRowCount;
    let duplicated: boolean = hasDuplicateRowKeys(this.rows);
    let rowDump: string = droppedCount > 0 || duplicated || shrunk ?
      '行序列转储 ' + describeCenterRows(this.rows) :
      describeCenterRowsSummary(this.rows, droppedCount);
    this.lastRowCount = this.rows.length;
    // 内容未变不重复输出（进度刷新会高频触发本方法）
    if (rowDump !== this.lastRowDump) {
      this.lastRowDump = rowDump;
      logger.debug(rowDump);
    }
    // 置灰口径与清除动作同源：可清除计数为零 ⇔ 入口置灰
    this.clearableCount = getClearableCount();
    this.pruneSelection();
  }

  // ── 多选状态 ──

  /** 可勾选行数量（纯函数）：仅终态与持久化历史行计入，进行中 / 待确认会话不可勾选。 */
  private deletableCount(): number {
    let count: number = 0;
    for (let i = 0; i < this.rows.length; i++) {
      let row: CenterRow = this.rows[i];
      if (row.kind === ROW_SESSION && row.session !== undefined && rowDeletable(row.session)) {
        count++;
      }
    }
    return count;
  }

  /** 已勾选数量。 */
  get selectedCount(): number {
    return this.selectedIds.length;
  }

  /** 是否全选可勾选行（无可勾选行时为假）。 */
  get allSelected(): boolean {
    let total: number = this.deletableCount();
    return total > 0 && this.selectedIds.length === total;
  }

  /** 指定会话标识是否已勾选（供行渲染读取）。 */
  isSelected(sessionId: string): boolean {
    return this.selectedIds.indexOf(sessionId) >= 0;
  }

  /**
   * 剔除已不可勾选的勾选项：会话被回收或转为非终态后其勾选不再有删除意义。
   * 在每次 refresh 末尾执行，使勾选集合恒为当前可勾选行的子集。
   */
  private pruneSelection(): void {
    let kept: Array<string> = [];
    for (let i = 0; i < this.selectedIds.length; i++) {
      let id: string = this.selectedIds[i];
      let stillDeletable: boolean = false;
      for (let k = 0; k < this.rows.length; k++) {
        let row: CenterRow = this.rows[k];
        if (row.kind === ROW_SESSION && row.session !== undefined && row.session.sessionId === id &&
          rowDeletable(row.session)) {
          stillDeletable = true;
          break;
        }
      }
      if (stillDeletable) {
        kept.push(id);
      }
    }
    if (kept.length !== this.selectedIds.length) {
      this.selectedIds = kept;
    }
    // 列表中不再有会话行时退出多选：此时只剩空态行，无任何条目可操作。
    // 注意不能以 rows.length 判定——空态本身也占一行（见 composeRows）。
    // 仅剩进行中 / 待确认会话时保留多选：行仍在，只是全部不可勾选，
    // 用户可借此进入多选后勾选后续转为可删的会话。
    if (!this.hasSessionRow()) {
      this.selectionMode = false;
    }
  }

  /** 行序列中是否存在会话条目行（空态行不计入）。 */
  private hasSessionRow(): boolean {
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].kind === ROW_SESSION) {
        return true;
      }
    }
    return false;
  }

  // ── 多选命令 ──

  /**
   * 进入多选模式：可勾选行同时勾选自身，不可勾选行（进行中 / 待确认）仅进入多选。
   * 长按不可勾选行进入多选是刻意保留的入口——用户可借此时机勾选同列表中其他可删除的行，
   * 无需先找到一条可勾选行。
   */
  enterSelection(sessionId: string): void {
    this.selectionMode = true;
    this.selectedIds = this.isDeletable(sessionId) ? [sessionId] : [];
  }

  /** 退出多选模式并清空全部勾选。 */
  exitSelection(): void {
    this.selectionMode = false;
    this.selectedIds = [];
  }

  /** 切换单行勾选状态（不可勾选的行不响应）。 */
  toggleSelect(sessionId: string): void {
    if (!this.isDeletable(sessionId)) {
      return;
    }
    let next: Array<string> = [];
    for (let i = 0; i < this.selectedIds.length; i++) {
      if (this.selectedIds[i] !== sessionId) {
        next.push(this.selectedIds[i]);
      }
    }
    if (next.length === this.selectedIds.length) {
      next.push(sessionId);
    }
    this.selectedIds = next;
  }

  /** 全选 / 取消全选切换（只作用于可勾选行）。 */
  toggleSelectAll(): void {
    if (this.allSelected) {
      this.selectedIds = [];
      return;
    }
    let next: Array<string> = [];
    for (let i = 0; i < this.rows.length; i++) {
      let row: CenterRow = this.rows[i];
      if (row.kind === ROW_SESSION && row.session !== undefined && rowDeletable(row.session)) {
        next.push(row.session.sessionId);
      }
    }
    this.selectedIds = next;
  }

  /** 指定会话标识当前是否可勾选（行渲染与长按判定的唯一依据）。 */
  private isDeletable(sessionId: string): boolean {
    for (let i = 0; i < this.rows.length; i++) {
      let row: CenterRow = this.rows[i];
      if (row.kind === ROW_SESSION && row.session !== undefined &&
        row.session.sessionId === sessionId) {
        return rowDeletable(row.session);
      }
    }
    return false;
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

  /**
   * 清除任务历史：清空持久化历史 + 移除已终态可见会话条目；不触碰进行中与待确认会话。
   * 清空同时删除这些记录对应的应用自建文件（发送文本落盘副本），使其不残留为孤儿；
   * 用户 picker 选中的原始文件与接收落盘文件均不在此列（后者删除权归文件接收历史页）。
   * 清空动作自身会发布变更总线通知，列表与标题栏入口的置灰状态随通知自动重算。
   */
  clearHistory(): void {
    clearSessionHistoryFromRegistry();
  }

  /**
   * 删除已勾选的任务记录（批量），完成后退出多选模式。
   * 与「清除任务历史」同一语义口径：移除持久化历史条目 + 移除已终态可见会话条目，
   * 并删除这些记录对应的应用自建文件；进行中与待确认会话既不可勾选、
   * 也在领域动作层被跳过，故不受影响。
   * 列表与标题栏入口的置灰状态随变更通知自动重算。
   */
  deleteSelected(): void {
    if (this.selectedIds.length === 0) {
      return;
    }
    logger.debug('delete selected count=' + this.selectedIds.length);
    removeEntriesByIds(this.selectedIds);
    this.exitSelection();
  }
}
