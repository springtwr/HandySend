/**
 * TransferSessionRegistry.ets — 统一会话注册表（唯一事实源）
 *
 * 职责：会话创建/进度/状态/终结/取消/查询、终态可见窗口与有界回收、
 * 生命周期事件发布、协议无关聚合快照、会话历史归档触发。
 *
 * 关键约束：
 * - 终态判定权归适配器（协议可能无结束信号），注册表只负责终态之后的
 *   可见窗口、归档与回收；
 * - 第一次到达的终态即最终状态（取消/完成竞态给出唯一确定结果）；
 * - 回收带代次守卫，同标识重建不被旧定时器误删；
 * - 状态变化经既有变更总线（AppCore.subscribe/notifyChange）对外发布，
 *   不使用按协议分散的一次性事件队列。
 */

import { notifyChange, subscribe, unsubscribe } from '../repository/AppCore';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import {
  OverallSnapshot,
  SessionCapabilities,
  SessionCreateInput,
  SessionEventKind,
  SessionFile,
  SessionFileDescriptor,
  SessionFileStage,
  SessionFilter,
  SessionStage,
  SessionTimelineEvent,
  TransferSession,
  isSuccessStage,
  isTerminalStage
} from '../../model/transfer/TransferSession';
import {
  SessionHistoryEntry,
  SessionHistoryQuery
} from '../../model/transfer/SessionHistory';
import { archiveSession, getSessionHistory as loadSessionHistory, clearSessionHistory } from './SessionHistoryStore';
import { getAdapter } from './adapters/SessionAdapter';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TransferRegistry', '会话注册表');

// 终态可见窗口（毫秒）：成功类较短、失败/取消类较长（对齐现状量级）
export const SUCCESS_VISIBLE_MS: number = 3000;
export const FAILURE_VISIBLE_MS: number = 5000;

/** 会话生命周期事件（后台服务与会话历史归档消费）。 */
export interface SessionLifecycleEvent {
  kind: string  // 'created' | 'finished' | 'reclaimed'
  sessionId: string
  protocolKey: string
  stage: SessionStage
}

// ── 模块状态 ──

const sessions: Map<string, TransferSession> = new Map();
// 会话回收定时器（会话标识 → timer id）；代次守卫见 scheduleReclaim
const reclaimTimers: Map<string, number> = new Map();
const lifecycleListeners: Array<(event: SessionLifecycleEvent) => void> = [];
let idSeq: number = 0;

// ── 纯逻辑辅助（可独立测试） ──

/** 终态可见窗口长度（毫秒）。 */
export function reclaimDelayMs(stage: SessionStage): number {
  return isSuccessStage(stage) ? SUCCESS_VISIBLE_MS : FAILURE_VISIBLE_MS;
}

/** 由文件集重算总字节与已传字节（容忍分母增长；单文件字节单调不回跳）。 */
export function recomputeTotals(session: TransferSession): void {
  let total: number = 0;
  let sent: number = 0;
  for (let i = 0; i < session.files.length; i++) {
    let f = session.files[i];
    total = total + f.totalBytes;
    sent = sent + f.bytesSent;
  }
  session.totalBytes = total;
  // 已传字节保持单调不回跳（分母增长后重算值可能变小，不采用）
  if (sent > session.bytesSent) {
    session.bytesSent = sent;
  }
}

/**
 * 协议无关聚合（纯函数）：进度/字节/会话数/设备数只统计进行中会话；
 * allFinished/hasFailure 统计全部输入。prevPercent 传入时整体进度单调不减。
 */
export function deriveOverall(sessionList: Array<TransferSession>, prevPercent: number = 0): OverallSnapshot {
  let activeSessions: Array<TransferSession> = [];
  for (let i = 0; i < sessionList.length; i++) {
    if (!isTerminalStage(sessionList[i].stage)) {
      activeSessions.push(sessionList[i]);
    }
  }
  let bytesSent: number = 0;
  let totalBytes: number = 0;
  let deviceNames: Array<string> = [];
  for (let i = 0; i < activeSessions.length; i++) {
    bytesSent = bytesSent + activeSessions[i].bytesSent;
    totalBytes = totalBytes + activeSessions[i].totalBytes;
    let name: string = activeSessions[i].peer.displayName;
    if (name.length > 0 && deviceNames.indexOf(name) < 0) {
      deviceNames.push(name);
    }
  }
  let percent: number = 0;
  if (activeSessions.length > 0) {
    if (totalBytes > 0) {
      percent = (bytesSent * 100) / totalBytes;
      if (percent > 100) {
        percent = 100;
      }
    }
  } else if (sessionList.length > 0) {
    for (let i = 0; i < sessionList.length; i++) {
      bytesSent = bytesSent + sessionList[i].bytesSent;
      totalBytes = totalBytes + sessionList[i].totalBytes;
    }
    if (totalBytes > 0) {
      percent = (bytesSent * 100) / totalBytes;
      if (percent > 100) {
        percent = 100;
      }
    }
  }
  if (percent < prevPercent) {
    percent = prevPercent;
  }
  let hasFailure: boolean = false;
  for (let i = 0; i < sessionList.length; i++) {
    if (isTerminalStage(sessionList[i].stage) && !isSuccessStage(sessionList[i].stage)) {
      hasFailure = true;
      break;
    }
  }
  return {
    active: activeSessions.length > 0,
    percent: percent,
    bytesSent: bytesSent,
    totalBytes: totalBytes,
    sessionCount: activeSessions.length,
    deviceCount: deviceNames.length,
    allFinished: sessionList.length > 0 && activeSessions.length === 0,
    hasFailure: hasFailure
  };
}

// ── 内部工具 ──

function emitLifecycle(event: SessionLifecycleEvent): void {
  for (let i = 0; i < lifecycleListeners.length; i++) {
    try {
      lifecycleListeners[i](event);
    } catch (e) {
      logger.error('lifecycle listener failed: ' + String(e));
    }
  }
}

function pushTimeline(session: TransferSession, kind: SessionEventKind, detail?: string): void {
  let event: SessionTimelineEvent = {
    kind: kind,
    timestamp: Date.now(),
    detail: detail,
    sessionId: session.id
  };
  let timeline: Array<SessionTimelineEvent> = session.timeline.slice();
  timeline.push(event);
  session.timeline = timeline;
}

function toSessionFile(descriptor: SessionFileDescriptor): SessionFile {
  let file = new SessionFile();
  file.fileId = descriptor.fileId;
  file.fileName = descriptor.fileName;
  file.fileType = descriptor.fileType;
  file.totalBytes = descriptor.totalBytes;
  file.occurrence = descriptor.occurrence ?? 1;
  file.bytesSent = 0;
  file.stage = SessionFileStage.waiting;
  return file;
}

/** 生成统一会话标识（含来源前缀，全局唯一且稳定）。 */
export function nextSessionId(protocolKey: string): string {
  idSeq++;
  return protocolKey + '_' + Date.now() + '_' + idSeq;
}

// ── 创建与更新 ──

export function createSession(input: SessionCreateInput, sessionId?: string): TransferSession {
  let session = new TransferSession();
  session.id = sessionId !== undefined && sessionId.length > 0 ? sessionId : nextSessionId(input.protocolKey);
  session.protocolKey = input.protocolKey;
  session.protocolSessionId = input.protocolSessionId;
  session.dataFlow = input.dataFlow;
  session.initiatedBy = input.initiatedBy;
  session.peer = input.peer;
  session.capabilities = input.capabilities;
  session.stageText = input.stageText ?? '';
  session.startedAt = Date.now();
  session.generation = 0;
  let files: Array<SessionFile> = [];
  for (let i = 0; i < input.files.length; i++) {
    files.push(toSessionFile(input.files[i]));
  }
  session.files = files;
  session.stage = input.stage ?? SessionStage.active;
  recomputeTotals(session);
  sessions.set(session.id, session);
  // 同标识重建：取消挂起的回收定时器（复活守卫），并递增代次使旧定时器失效
  cancelReclaim(session.id);
  pushTimeline(session, SessionEventKind.created, input.protocolKey);
  if (session.stage !== SessionStage.awaitingConfirmation) {
    pushTimeline(session, SessionEventKind.started);
  }
  emitLifecycle({ kind: 'created', sessionId: session.id, protocolKey: session.protocolKey, stage: session.stage });
  notifyChange();
  return session;
}

/** 增量追加文件（分母随之增长，进度不回跳、不据此误判完成）。 */
export function appendFiles(sessionId: string, files: Array<SessionFileDescriptor>): void {
  let session = getSession(sessionId);
  if (session === undefined || isTerminalStage(session.stage)) {
    return;
  }
  let next: Array<SessionFile> = session.files.slice();
  for (let i = 0; i < files.length; i++) {
    next.push(toSessionFile(files[i]));
  }
  session.files = next;
  recomputeTotals(session);
  notifyChange();
}

/** 字节级进度更新（单文件单调不回跳）。 */
export function updateFileProgress(sessionId: string, fileId: string,
  bytesSent: number, totalBytes?: number): void {
  let session = getSession(sessionId);
  if (session === undefined || isTerminalStage(session.stage)) {
    return;
  }
  for (let i = 0; i < session.files.length; i++) {
    let f = session.files[i];
    if (f.fileId !== fileId) {
      continue;
    }
    if (totalBytes !== undefined && totalBytes > 0) {
      f.totalBytes = totalBytes;
    }
    if (bytesSent > f.bytesSent) {
      f.bytesSent = bytesSent;
    }
    if (f.totalBytes > 0 && f.bytesSent >= f.totalBytes) {
      f.stage = SessionFileStage.completed;
    } else if (f.bytesSent > 0) {
      f.stage = SessionFileStage.transferring;
    }
    break;
  }
  recomputeTotals(session);
  notifyChange();
}

/** 离散阶段进度（无字节进度的协议：仅更新阶段文案）。 */
export function setStageProgress(sessionId: string, stageText: ResourceStr): void {
  let session = getSession(sessionId);
  if (session === undefined || isTerminalStage(session.stage)) {
    return;
  }
  session.stageText = stageText;
  notifyChange();
}

/** 状态变更（协议阶段 → 统一状态）。终态后不可再改（首次终态为准）。 */
export function setStage(sessionId: string, stage: SessionStage, errorMessage?: string): void {
  let session = getSession(sessionId);
  if (session === undefined) {
    return;
  }
  if (isTerminalStage(session.stage)) {
    return;
  }
  if (isTerminalStage(stage)) {
    finish(sessionId, stage, errorMessage);
    return;
  }
  if (session.stage === SessionStage.awaitingConfirmation && stage === SessionStage.active) {
    pushTimeline(session, SessionEventKind.confirmed);
    pushTimeline(session, SessionEventKind.started);
  }
  session.stage = stage;
  if (errorMessage !== undefined) {
    session.errorMessage = errorMessage;
  }
  notifyChange();
}

/** 确认待确认会话（动作由适配器实现，注册表负责状态迁移）。 */
export function confirmSession(sessionId: string): void {
  let session = getSession(sessionId);
  if (session === undefined || session.stage !== SessionStage.awaitingConfirmation) {
    return;
  }
  let adapter = getAdapter(session.protocolKey);
  // 按能力声明分发：适配器声明无需确认时，确认动作不可执行
  if (adapter !== undefined && !adapter.getCapabilities().needsConfirm) {
    return;
  }
  session.stage = SessionStage.active;
  pushTimeline(session, SessionEventKind.confirmed);
  pushTimeline(session, SessionEventKind.started);
  notifyChange();
  if (adapter !== undefined) {
    adapter.confirm(sessionId);
  }
}

/** 拒绝待确认会话（终态：已拒绝）。 */
export function declineSession(sessionId: string): void {
  let session = getSession(sessionId);
  if (session === undefined || session.stage !== SessionStage.awaitingConfirmation) {
    return;
  }
  let adapter = getAdapter(session.protocolKey);
  // 按能力声明分发：适配器声明无需确认时，拒绝动作不可执行
  if (adapter !== undefined && !adapter.getCapabilities().needsConfirm) {
    return;
  }
  if (adapter !== undefined) {
    adapter.decline(sessionId);
  }
  finish(sessionId, SessionStage.declined);
}

/**
 * 终结会话（首次终态为准）：记录时间线、归档历史、发布生命周期事件、
 * 安排可见窗口后的回收。
 */
export function finish(sessionId: string, outcome: SessionStage, errorMessage?: string): void {
  let session = getSession(sessionId);
  if (session === undefined) {
    return;
  }
  if (isTerminalStage(session.stage)) {
    return;
  }
  // 记录终结前的阶段：待确认阶段的拒绝/撤回取消不写入会话历史
  let previouslyAwaitingConfirmation: boolean = session.stage === SessionStage.awaitingConfirmation;
  session.stage = outcome;
  // 终态文案一律由统一状态映射决定：清空进行中阶段残留的离散文案，
  // 避免列表/详情在终态仍展示陈旧的阶段文案（如「传输中」）。
  session.stageText = '';
  session.finishedAt = Date.now();
  if (errorMessage !== undefined) {
    session.errorMessage = errorMessage;
  }
  // 终态把逐文件状态补齐：成功类终态下未完成文件标记完成（文本消息等无进度事件场景）
  if (isSuccessStage(outcome)) {
    for (let i = 0; i < session.files.length; i++) {
      session.files[i].stage = SessionFileStage.completed;
      if (session.files[i].totalBytes > 0) {
        session.files[i].bytesSent = session.files[i].totalBytes;
      }
    }
    recomputeTotals(session);
  }
  let kind: SessionEventKind = SessionEventKind.completed;
  if (outcome === SessionStage.failed || outcome === SessionStage.partiallyFailed) {
    kind = SessionEventKind.failed;
  } else if (outcome === SessionStage.cancelled) {
    kind = SessionEventKind.cancelled;
  } else if (outcome === SessionStage.declined) {
    kind = SessionEventKind.declined;
  }
  pushTimeline(session, kind, errorMessage);
  archiveSession(session, previouslyAwaitingConfirmation);
  emitLifecycle({ kind: 'finished', sessionId: session.id, protocolKey: session.protocolKey, stage: session.stage });
  scheduleReclaim(sessionId);
  notifyChange();
}

/**
 * 取消会话（幂等）：注册表置终态并归档，动作经适配器执行。
 * 按能力声明分发：适配器声明不可取消（canCancel=false）时为空操作，
 * 不改状态也不调用适配器（如 Web 下载，仅能由协议侧终结）。
 * 重复/并发取消安全（终态后直接返回）。
 */
export function cancel(sessionId: string): void {
  let session = getSession(sessionId);
  if (session === undefined || isTerminalStage(session.stage)) {
    return;
  }
  let adapter = getAdapter(session.protocolKey);
  if (adapter !== undefined && !adapter.getCapabilities().canCancel) {
    logger.debug('cancel ignored (canCancel=false) session=' + sessionId);
    return;
  }
  finish(sessionId, SessionStage.cancelled);
  if (adapter !== undefined) {
    try {
      adapter.cancel(sessionId);
    } catch (e) {
      logger.warn('adapter cancel failed: ' + String(e));
    }
  }
}

/** 重试失败会话（发送方向）：经适配器创建新会话，旧会话保留在历史。 */
export function retry(sessionId: string): void {
  let session = getSession(sessionId);
  if (session === undefined || !isTerminalStage(session.stage)) {
    return;
  }
  if (!session.capabilities.canRetry) {
    return;
  }
  let adapter = getAdapter(session.protocolKey);
  if (adapter !== undefined) {
    adapter.retry(sessionId);
  }
}

// ── 回收 ──

function cancelReclaim(sessionId: string): void {
  let timer = reclaimTimers.get(sessionId);
  if (timer !== undefined) {
    clearTimeout(timer);
    reclaimTimers.delete(sessionId);
  }
}

/** 安排终态会话的回收（代次守卫：同标识重建不被旧定时器误删）。 */
function scheduleReclaim(sessionId: string): void {
  let session = sessions.get(sessionId);
  if (session === undefined) {
    return;
  }
  cancelReclaim(sessionId);
  let generation: number = session.generation;
  let delay: number = reclaimDelayMs(session.stage);
  session.reclaimAt = Date.now() + delay;
  let timer: number = setTimeout(() => {
    reclaimTimers.delete(sessionId);
    let current = sessions.get(sessionId);
    if (current === undefined) {
      return;
    }
    // 复活守卫：期间被同标识重建（generation 变化）或回到非终态则不回收
    if (current.generation !== generation || !isTerminalStage(current.stage)) {
      return;
    }
    releaseSession(current);
  }, delay);
  reclaimTimers.set(sessionId, timer);
}

/** 回收会话：通知适配器释放协议资源并从注册表移除。 */
function releaseSession(session: TransferSession): void {
  let adapter = getAdapter(session.protocolKey);
  if (adapter !== undefined) {
    try {
      adapter.dispose(session.id);
    } catch (e) {
      logger.warn('adapter dispose failed: ' + String(e));
    }
  }
  sessions.delete(session.id);
  emitLifecycle({ kind: 'reclaimed', sessionId: session.id, protocolKey: session.protocolKey, stage: session.stage });
  notifyChange();
}

// ── 查询 ──

export function getSession(sessionId: string): TransferSession | undefined {
  return sessions.get(sessionId);
}

/** 按协议标识查找统一会话（进度/事件归属不依赖文件标识回退匹配）。 */
export function findByProtocol(protocolKey: string, protocolSessionId: string): TransferSession | undefined {
  let result: TransferSession | undefined = undefined;
  sessions.forEach((session: TransferSession) => {
    if (result === undefined && session.protocolKey === protocolKey &&
      session.protocolSessionId === protocolSessionId) {
      result = session;
    }
  });
  return result;
}

/** 查询会话（可选筛选）。 */
export function querySessions(filter?: SessionFilter): Array<TransferSession> {
  let result: Array<TransferSession> = [];
  sessions.forEach((session: TransferSession) => {
    if (filter !== undefined) {
      if (filter.stage !== undefined && session.stage !== filter.stage) {
        return;
      }
      if (filter.protocolKey !== undefined && session.protocolKey !== filter.protocolKey) {
        return;
      }
      if (filter.dataFlow !== undefined && session.dataFlow !== filter.dataFlow) {
        return;
      }
    }
    result.push(session);
  });
  return result;
}

/** 全部会话（UI 按状态分组展示）。 */
export function getAllSessions(): Array<TransferSession> {
  let result: Array<TransferSession> = [];
  sessions.forEach((session: TransferSession) => {
    result.push(session);
  });
  return result;
}

/** 活跃（非终态）会话数。 */
export function getActiveCount(): number {
  let count: number = 0;
  sessions.forEach((session: TransferSession) => {
    if (!isTerminalStage(session.stage)) {
      count++;
    }
  });
  return count;
}

/** 待确认会话数（活跃角标/待确认区使用）。 */
export function getPendingCount(): number {
  let count: number = 0;
  sessions.forEach((session: TransferSession) => {
    if (session.stage === SessionStage.awaitingConfirmation) {
      count++;
    }
  });
  return count;
}

export function getOverallSnapshot(prevPercent: number = 0): OverallSnapshot {
  return deriveOverall(getAllSessions(), prevPercent);
}

// ── 订阅 ──

/** 订阅会话变化（复用既有变更总线，作为唯一 UI 通知入口）。 */
export function subscribeSessions(callback: () => void): void {
  subscribe(callback);
}

export function unsubscribeSessions(callback: () => void): void {
  unsubscribe(callback);
}

/** 订阅会话生命周期事件（后台服务/历史归档消费）。返回取消订阅函数。 */
export function onSessionLifecycle(callback: (event: SessionLifecycleEvent) => void): () => void {
  lifecycleListeners.push(callback);
  return () => {
    let kept: Array<(event: SessionLifecycleEvent) => void> = [];
    for (let i = 0; i < lifecycleListeners.length; i++) {
      if (lifecycleListeners[i] !== callback) {
        kept.push(lifecycleListeners[i]);
      }
    }
    lifecycleListeners.splice(0, lifecycleListeners.length);
    for (let i = 0; i < kept.length; i++) {
      lifecycleListeners.push(kept[i]);
    }
  };
}

// ── 历史 ──

export function getHistory(filter?: SessionHistoryQuery): Array<SessionHistoryEntry> {
  return loadSessionHistory(filter);
}

export function clearHistory(): void {
  clearSessionHistory();
}

// ── 适配器上下文查询（供中心/详情页避免直接依赖适配器） ──

/**
 * 会话能力声明（会话级）。
 *
 * 能力由适配器在创建会话时按该会话的实际路径声明（如单条文本消息发送
 * 无字节进度、Web 下载不可取消）；详情页动作区与能力相关展示一律以此为准，
 * 不使用适配器的静态能力，避免同一协议的不同会话被张冠李戴。
 */
export function getSessionCapabilities(session: TransferSession): SessionCapabilities {
  return session.capabilities;
}

// ── 测试/重置支持 ──

/** 清空注册表与定时器（仅测试与进程重置使用）。 */
export function resetRegistry(): void {
  reclaimTimers.forEach((timer: number) => {
    clearTimeout(timer);
  });
  reclaimTimers.clear();
  sessions.clear();
  idSeq = 0;
}
