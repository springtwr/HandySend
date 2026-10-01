/**
 * TransferSessionRegistry.ets — 统一会话注册表（唯一事实源）
 *
 * 职责：会话创建/进度/状态/终结/取消/查询、终态可见窗口与有界回收、
 * 生命周期事件发布、协议无关聚合快照、任务历史归档触发。
 *
 * 关键约束：
 * - 终态判定权归适配器（协议可能无结束信号），注册表只负责终态之后的
 *   可见窗口、归档与回收；
 * - 第一次到达的终态即最终状态（取消/完成竞态给出唯一确定结果）；
 * - 回收带代次守卫，同标识重建不被旧定时器误删；
 * - 状态变化经既有变更总线（AppCore.subscribe/notifyChange）对外发布，
 *   不使用按协议分散的一次性事件队列。
 */

import { notifyChange, subscribe, unsubscribe, getLocalInterfaces } from '../repository/AppCore';
import { getDeviceAlias } from '../repository/DeviceRepository';
import { NetworkInterface } from '../../model/Types';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import {
  OverallSnapshot,
  SessionCapabilities,
  SessionCreateInput,
  SessionDataFlow,
  SessionEventKind,
  SessionFile,
  SessionFileDescriptor,
  SessionFileStage,
  SessionFilter,
  SessionPeer,
  SessionStage,
  SessionTimelineEvent,
  TransferSession,
  isPreparing,
  isSuccessStage,
  isTerminalStage
} from '../../model/transfer/TransferSession';
import {
  SessionHistoryEntry, SessionHistoryQuery
} from '../../model/transfer/SessionHistory';
import {
  archiveSession,
  getSessionHistory as loadSessionHistory,
  clearSessionHistory,
  removeSessionHistoryByIds
} from './SessionHistoryStore';
import { getAdapter } from './adapters/SessionAdapter';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TransferRegistry', '会话注册表');

// 终态可见窗口（毫秒）：成功类较短、失败/取消类较长（对齐现状量级）
export const SUCCESS_VISIBLE_MS: number = 3000;

export const FAILURE_VISIBLE_MS: number = 5000;

// 发送侧无进展兜底阈值（毫秒）：固定阈值、不自适应；判定依据是「连续无进展」而非会话总存活时长
export const NO_PROGRESS_TIMEOUT_MS: number = 60000;

// 无进展看门狗轮询间隔（毫秒）：单一节流轮询，仅在存在发送方向非终态会话时运行
export const WATCHDOG_INTERVAL_MS: number = 10000;

// 无进展兜底终结的记录错误码
export const NO_PROGRESS_ERROR_CODE: string = 'no_progress';

// ── 模块状态 ──

const sessions: Map<string, TransferSession> = new Map();
// 会话回收定时器（会话标识 → timer id）；代次守卫见 scheduleReclaim
const reclaimTimers: Map<string, number> = new Map();
// 峰值速度采样点（会话标识 → 上次采样时间与已传字节）
const speedSamples: Map<string, SpeedSample> = new Map();
// 发送会话最近活动时刻（会话标识 → 毫秒）：仅发送方向会话参与无进展看门狗
const activityTimes: Map<string, number> = new Map();
// 无进展看门狗定时器（-1 表示未运行）
let watchdogTimer: number = -1;
let idSeq: number = 0;

// 速度采样的最小间隔（毫秒）：过密采样受调度抖动影响大
const SPEED_SAMPLE_MIN_MS: number = 200;

/** 峰值速度采样点。 */
interface SpeedSample {
  lastMs: number
  lastBytes: number
}

/** 默认网卡（优先 isDefault 且有 IP，其次首个有 IP 的网卡）。 */
function defaultLocalInterface(): NetworkInterface | undefined {
  let list: Array<NetworkInterface> = getLocalInterfaces();
  for (let i = 0; i < list.length; i++) {
    if (list[i].isDefault && list[i].ip.length > 0) {
      return list[i];
    }
  }
  for (let i = 0; i < list.length; i++) {
    if (list[i].ip.length > 0) {
      return list[i];
    }
  }
  return undefined;
}

/** 采样瞬时速度并维护会话峰值速度（不可得时保持既有值）。 */
function sampleSpeed(session: TransferSession): void {
  let now: number = Date.now();
  let sample = speedSamples.get(session.id);
  if (sample === undefined) {
    speedSamples.set(session.id, { lastMs: now, lastBytes: session.bytesSent });
    return;
  }
  let elapsed: number = now - sample.lastMs;
  if (elapsed < SPEED_SAMPLE_MIN_MS) {
    return;
  }
  let delta: number = session.bytesSent - sample.lastBytes;
  if (delta > 0) {
    let bps: number = (delta * 1000) / elapsed;
    if (bps > session.peakSpeedBps) {
      session.peakSpeedBps = bps;
    }
  }
  sample.lastMs = now;
  sample.lastBytes = session.bytesSent;
}

/** 会话终结时按总字节/耗时推导平均速度（不可得时保持 0）。 */
function finalizeSpeed(session: TransferSession): void {
  let durationMs: number = session.finishedAt - session.startedAt;
  if (durationMs > 0 && session.bytesSent > 0) {
    session.averageSpeedBps = (session.bytesSent * 1000) / durationMs;
  }
  speedSamples.delete(session.id);
}

// ── 纯逻辑辅助（可独立测试） ──

/** 终态可见窗口长度（毫秒）。 */
export function reclaimDelayMs(stage: SessionStage): number {
  return isSuccessStage(stage) ? SUCCESS_VISIBLE_MS : FAILURE_VISIBLE_MS;
}

/**
 * 对端身份声明（同设备判定用）：跨协议时 IP 可能不可得（如 MTA 不携带对端 IP），
 * 此时回退昵称；两者都缺失即视为不同对端，不做任何移除。
 */
export interface PeerIdentity {
  ip: string
  name: string
  /** 协议级稳定标识（缺省为空串；局域网=LocalSend 指纹，互传=对端发送者 ID） */
  id?: string
}

/** 由会话对端派生身份声明（缺省字段归空串，避免可选字段参与比较）。 */
export function peerIdentityOf(peer: SessionPeer): PeerIdentity {
  return { ip: peer.ip ?? '', name: peer.displayName, id: peer.fingerprint ?? '' };
}

/**
 * 对端身份匹配（纯函数，无副作用），按精度从高到低：
 * - 双方 IP 均非空时按 IP 相等匹配（局域网发送携带 IP，精度最高，口径保持不变）；
 * - 否则双方稳定标识 `id` 均非空时按 `id` 相等匹配（互传无 IP：对端发送者 ID 比昵称可靠，
 *   修掉「同名不同机互相取代」「同机改名/重连后残留旧条目」）；
 * - 否则双方昵称均非空时按昵称相等匹配（最后回退）；
 * - 否则不匹配（匿名或身份缺失的对端不参与同设备判定，杜绝误判）。
 */
export function isSamePeer(a: PeerIdentity, b: PeerIdentity): boolean {
  if (a.ip.length > 0 && b.ip.length > 0) {
    return a.ip === b.ip;
  }
  let aId = a.id ?? '';
  let bId = b.id ?? '';
  if (aId.length > 0 && bId.length > 0) {
    return aId === bId;
  }
  if (a.name.length > 0 && b.name.length > 0) {
    return a.name === b.name;
  }
  return false;
}

/**
 * 无进展判定（纯函数，无副作用）：当前时刻 − 最近活动时刻超过阈值即应终结。
 * 仅累计「真正无进展」的时间——只要活动时刻持续刷新，任何耗时都不构成终结条件，
 * 因此不存在「会话总存活上限」语义。
 */
export function isNoProgressTimeout(nowMs: number, lastActivityMs: number,
  thresholdMs: number): boolean {
  return nowMs - lastActivityMs > thresholdMs;
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
 * 协议无关聚合（纯函数）：
 * - 有进行中会话时，进度/字节/设备数只统计进行中会话；
 * - 无进行中会话时按终态会话汇总字节与进度（收尾展示 100%）；
 * - 待确认会话不计入活跃标志/会话数/设备数/进度与字节汇总；
 * - allFinished 表示「全部会话均已终态」（待确认不算完成，避免提前发布终态通知）；
 * - hasFailure 统计全部输入；prevPercent 传入时整体进度单调不减。
 */
export function deriveOverall(sessionList: Array<TransferSession>, prevPercent: number = 0): OverallSnapshot {
  let activeSessions: Array<TransferSession> = [];
  let terminalSessions: Array<TransferSession> = [];
  let allTerminal: boolean = sessionList.length > 0;
  for (let i = 0; i < sessionList.length; i++) {
    let stage: SessionStage = sessionList[i].stage;
    // 任一非终态（进行中或待确认）都不算「全部完成」
    if (!isTerminalStage(stage)) {
      allTerminal = false;
    }
    if (stage === SessionStage.active) {
      activeSessions.push(sessionList[i]);
    } else if (isTerminalStage(stage)) {
      terminalSessions.push(sessionList[i]);
    }
  }
  let bytesSent: number = 0;
  let totalBytes: number = 0;
  let deviceNames: Array<string> = [];
  for (let i = 0; i < activeSessions.length; i++) {
    let active = activeSessions[i];
    // 准备态活跃会话以准备进度计入字节汇总（后台通知展示真实推进而非 0%）
    if (isPreparing(active)) {
      bytesSent = bytesSent + active.prepBytes;
      totalBytes = totalBytes + active.prepTotalBytes;
    } else {
      bytesSent = bytesSent + active.bytesSent;
      totalBytes = totalBytes + active.totalBytes;
    }
    let name: string = active.peer.displayName;
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
  } else if (terminalSessions.length > 0) {
    for (let i = 0; i < terminalSessions.length; i++) {
      bytesSent = bytesSent + terminalSessions[i].bytesSent;
      totalBytes = totalBytes + terminalSessions[i].totalBytes;
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
    allFinished: allTerminal,
    hasFailure: hasFailure
  };
}

// ── 内部工具 ──

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
  file.checksum = descriptor.checksum ?? '';
  file.path = descriptor.path ?? '';
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

/**
 * 刷新发送会话的最近活动时刻（无进展计时基准）。
 * 仅发送方向、非终态会话参与：接收方向不写活动表，避免影响接收侧行为。
 */
function touchActivity(session: TransferSession, nowMs: number = Date.now()): void {
  if (session.dataFlow !== SessionDataFlow.outbound || isTerminalStage(session.stage)) {
    return;
  }
  activityTimes.set(session.id, nowMs);
}

export function createSession(input: SessionCreateInput): TransferSession {
  let session = new TransferSession();
  session.id = nextSessionId(input.protocolKey);
  session.protocolKey = input.protocolKey;
  session.protocolSessionId = input.protocolSessionId;
  session.dataFlow = input.dataFlow;
  session.initiatedBy = input.initiatedBy;
  session.peer = input.peer;
  session.capabilities = input.capabilities;
  session.stageText = input.stageText ?? '';
  session.startedAt = Date.now();
  // 采集本机标识（昵称 / 默认 IP / 网卡接口名），随历史持久化以支撑详情展示
  session.localAlias = getDeviceAlias();
  let localInterface = defaultLocalInterface();
  session.localIp = localInterface !== undefined ? localInterface.ip : '';
  session.localInterfaceName = localInterface !== undefined ? localInterface.name : '';
  let files: Array<SessionFile> = [];
  for (let i = 0; i < input.files.length; i++) {
    files.push(toSessionFile(input.files[i]));
  }
  session.files = files;
  session.stage = input.stage ?? SessionStage.active;
  recomputeTotals(session);
  sessions.set(session.id, session);
  // 发送方向会话纳入无进展看门狗：活动基准自创建时刻起算，
  // 后续字节进度、阶段/文案更新与文件集追加均会刷新（见各自入口）
  touchActivity(session);
  ensureWatchdog();
  pushTimeline(session, SessionEventKind.created, input.protocolKey);
  if (session.stage !== SessionStage.awaitingConfirmation) {
    pushTimeline(session, SessionEventKind.started);
  }
  logger.info(`会话创建 id=${session.id} 协议=${session.protocolKey} 方向=${session.dataFlow}` +
    ` 阶段=${session.stage} 文件数=${session.files.length}`);
  notifyChange();
  return session;
}

/**
 * 创建后回填协议会话标识：仅当会话存在、当前为空、参数非空且会话非终态时写入，
 * 写入后发布变更通知以驱动展示刷新；其余情形一律空操作（不覆盖已有非空值、终态不改写）。
 * 用途：局域网发送在 prepare-upload 握手完成后才由协议返回接收方标识，创建时物理上不可知，
 * 故须在拿到标识后回填；终结后不再回填可保证归档值等于终态时刻的实际值。
 * @returns 是否实际写入（供用例断言空操作）
 */
export function updateProtocolSessionId(sessionId: string, protocolSessionId: string): boolean {
  if (sessionId.length === 0 || protocolSessionId.length === 0) {
    return false;
  }
  let session = sessions.get(sessionId);
  if (session === undefined || isTerminalStage(session.stage) || session.protocolSessionId.length > 0) {
    return false;
  }
  session.protocolSessionId = protocolSessionId;
  notifyChange();
  return true;
}

/**
 * 运行期写入/更新会话文件路径：把某文件的最终磁盘位置写入对应文件条目。
 * 会话不存在、已终态、路径为空或文件标识未命中时为空操作。
 * 用途：接收侧在导出文本、发送侧在文本落盘后补写真实路径，供详情页按路径读取内容。
 * @returns 是否实际写入
 */
export function updateSessionFilePath(sessionId: string, fileId: string, path: string): boolean {
  if (sessionId.length === 0 || fileId.length === 0 || path.length === 0) {
    return false;
  }
  let session = sessions.get(sessionId);
  if (session === undefined || isTerminalStage(session.stage)) {
    return false;
  }
  for (let i = 0; i < session.files.length; i++) {
    if (session.files[i].fileId === fileId) {
      session.files[i].path = path;
      notifyChange();
      return true;
    }
  }
  return false;
}

/** 回填接收确认阶段的对端预览图路径（目前仅 MTA 缩略图使用）。
 *
 * 会话已终结、路径为空或与现有值相同时为空操作，返回是否写入。
 */
export function updateSessionPeerPreview(sessionId: string, path: string): boolean {
  if (sessionId.length === 0 || path.length === 0) {
    return false;
  }
  let session = sessions.get(sessionId);
  if (session === undefined || isTerminalStage(session.stage)) {
    return false;
  }
  if (session.peer.previewImagePath === path) {
    return false;
  }
  session.peer.previewImagePath = path;
  notifyChange();
  return true;
}

/** 增量追加文件（分母随之增长，进度不回跳、不据此误判完成）。 */export function appendFiles(sessionId: string, files: Array<SessionFileDescriptor>): void {
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
  // 文件集追加亦视为进展：刷新发送会话活动基准
  touchActivity(session);
  notifyChange();
}

/**
 * 整体替换会话文件清单：以真实结果取代创建期的占位条目。
 * 会话不存在、已终态或清单为空时为空操作（与 appendFiles / updateSessionFilePath 的
 * 「终态不改写」约定一致）；否则按描述符整体重建逐文件条目（保留描述符携带的 path）、
 * 重算会话总字节并发布一次变更通知。调用方随后终结会话时按成功语义补齐字节与文件状态。
 * 用途：接收类协议在下载落盘完成后以真实逐文件清单（文件名/大小/类型/路径）回填，
 * 使详情与任务列表按同一口径展示，不再残留单一「主文件名」占位条目。
 * @returns 是否实际替换（供用例断言空操作）
 */
export function setSessionFiles(sessionId: string, files: Array<SessionFileDescriptor>): boolean {
  if (sessionId.length === 0 || files.length === 0) {
    return false;
  }
  let session = sessions.get(sessionId);
  if (session === undefined || isTerminalStage(session.stage)) {
    return false;
  }
  let next: Array<SessionFile> = [];
  for (let i = 0; i < files.length; i++) {
    next.push(toSessionFile(files[i]));
  }
  session.files = next;
  recomputeTotals(session);
  notifyChange();
  return true;
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
  sampleSpeed(session);
  // 字节进度即进展：刷新发送会话活动基准
  touchActivity(session);
  notifyChange();
}

/** 离散阶段进度（无字节进度的协议：仅更新阶段文案）。 */
export function setStageProgress(sessionId: string, stageText: ResourceStr): void {
  let session = getSession(sessionId);
  if (session === undefined || isTerminalStage(session.stage)) {
    return;
  }
  session.stageText = stageText;
  // 阶段/文案更新即进展：刷新发送会话活动基准
  touchActivity(session);
  notifyChange();
}

/**
 * 准备（校验和计算）进度写入：终态会话空操作；置入准备分母（prepTotalBytes > 0），
 * 已哈希字节单调不回跳（迟到的小值不采用）；刷新发送会话活动基准并发布变更通知。
 * 准备进度只经 prepBytes/prepTotalBytes 承载，绝不写入 bytesSent/totalBytes。
 */
export function setPrepProgress(sessionId: string, prepBytes: number, prepTotalBytes: number): void {
  let session = getSession(sessionId);
  if (session === undefined || isTerminalStage(session.stage)) {
    return;
  }
  if (prepTotalBytes > 0) {
    session.prepTotalBytes = prepTotalBytes;
  }
  if (prepBytes > session.prepBytes) {
    session.prepBytes = prepBytes;
  }
  // 准备进度即进展：刷新活动基准，准备期不被无进展看门狗误判
  touchActivity(session);
  notifyChange();
}

/**
 * 结束准备（校验和计算）显示态（准备完成、转入传输前调用）：清零准备进度
 * （prepBytes/prepTotalBytes）并**同一步清除准备阶段文案**（stageText 置空），
 * 使状态徽标与详情页阶段文案回落到统一状态映射（active → 「传输中」），
 * 不再残留「正在计算校验和」。终态会话空操作；未处于准备态（无准备进度）的会话
 * 提前返回、不受影响。
 */
export function clearPrep(sessionId: string): void {
  let session = getSession(sessionId);
  if (session === undefined || isTerminalStage(session.stage)) {
    return;
  }
  if (session.prepBytes === 0 && session.prepTotalBytes === 0) {
    return;
  }
  session.prepBytes = 0;
  session.prepTotalBytes = 0;
  // 结束准备显示态：清除准备阶段文案，避免徽标/详情页残留「正在计算校验和」
  session.stageText = '';
  notifyChange();
}

/** 状态变更（协议阶段 → 统一状态）。终态后不可再改（首次终态为准）。 */
export function setStage(sessionId: string, stage: SessionStage, errorMessage?: string,
  errorCode?: string): void {
  let session = getSession(sessionId);
  if (session === undefined) {
    return;
  }
  if (isTerminalStage(session.stage)) {
    return;
  }
  if (isTerminalStage(stage)) {
    finish(sessionId, stage, errorMessage, errorCode);
    return;
  }
  if (session.stage === SessionStage.awaitingConfirmation && stage === SessionStage.active) {
    pushTimeline(session, SessionEventKind.confirmed);
    pushTimeline(session, SessionEventKind.started);
  }
  // 生命周期诊断只记录阶段跃迁（进度与文案更新属高频事件，不记录）
  if (session.stage !== stage) {
    logger.info(`阶段推进 id=${session.id} 协议=${session.protocolKey} 阶段=${session.stage}→${stage}`);
  }
  session.stage = stage;
  // 阶段推进即进展：刷新发送会话活动基准
  touchActivity(session);
  if (errorMessage !== undefined) {
    session.errorMessage = errorMessage;
  }
  if (errorCode !== undefined) {
    session.errorCode = errorCode;
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
  logger.info(`阶段推进 id=${session.id} 协议=${session.protocolKey}` +
    ` 阶段=${session.stage}→${SessionStage.active}`);
  session.stage = SessionStage.active;
  touchActivity(session);
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
export function finish(sessionId: string, outcome: SessionStage, errorMessage?: string,
  errorCode?: string): void {
  let session = getSession(sessionId);
  if (session === undefined) {
    return;
  }
  if (isTerminalStage(session.stage)) {
    return;
  }
  session.stage = outcome;
  // 终态文案一律由统一状态映射决定：清空进行中阶段残留的离散文案，
  // 避免列表/详情在终态仍展示陈旧的阶段文案（如「传输中」）。
  session.stageText = '';
  // 终态清零准备进度：避免终态行残留准备态判定与准备进度
  session.prepBytes = 0;
  session.prepTotalBytes = 0;
  session.finishedAt = Date.now();
  if (errorMessage !== undefined) {
    session.errorMessage = errorMessage;
  }
  // 错误码与错误信息并列记录（无法取得时保持空串）
  if (errorCode !== undefined) {
    session.errorCode = errorCode;
  }
  // 终态按类别补齐逐文件状态，使会话结果与文件清单语义一致：
  // - 成功类：全部置成功并补齐已传字节（文本消息等无进度事件场景）；
  // - 失败类：已完成保持成功，其余（等待中/传输中）置失败；
  // - 取消类：已完成/已失败保持，其余（等待中/传输中）置已取消；
  // - 拒绝类：逐文件状态保持终态前的原状。
  if (isSuccessStage(outcome)) {
    for (let i = 0; i < session.files.length; i++) {
      session.files[i].stage = SessionFileStage.completed;
      if (session.files[i].totalBytes > 0) {
        session.files[i].bytesSent = session.files[i].totalBytes;
      }
    }
    recomputeTotals(session);
  } else if (outcome === SessionStage.failed || outcome === SessionStage.partiallyFailed) {
    for (let i = 0; i < session.files.length; i++) {
      if (session.files[i].stage !== SessionFileStage.completed) {
        session.files[i].stage = SessionFileStage.failed;
      }
    }
  } else if (outcome === SessionStage.cancelled) {
    for (let i = 0; i < session.files.length; i++) {
      let fileStage: SessionFileStage = session.files[i].stage;
      // 取消不改写已完成/已失败文件：仅把等待中/传输中的未完成文件置为已取消
      if (fileStage === SessionFileStage.waiting || fileStage === SessionFileStage.transferring) {
        session.files[i].stage = SessionFileStage.cancelled;
      }
    }
  }
  // 终结时定格性能指标：平均速度按总字节/耗时推导；峰值速度由会话期间采样维护
  finalizeSpeed(session);
  let kind: SessionEventKind = SessionEventKind.completed;
  if (outcome === SessionStage.failed || outcome === SessionStage.partiallyFailed) {
    kind = SessionEventKind.failed;
  } else if (outcome === SessionStage.cancelled) {
    kind = SessionEventKind.cancelled;
  } else if (outcome === SessionStage.declined) {
    kind = SessionEventKind.declined;
  }
  pushTimeline(session, kind, errorMessage);
  archiveSession(session);
  logger.info(`会话终结 id=${sessionId} 协议=${session.protocolKey} 结果=${outcome}` +
    ` 错误码=${session.errorCode} 文件数=${session.files.length}`);
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
  let delay: number = reclaimDelayMs(session.stage);
  let timer: number = setTimeout(() => {
    reclaimTimers.delete(sessionId);
    let current = sessions.get(sessionId);
    if (current === undefined) {
      return;
    }
    // 期间被同标识重建（新会话会另起定时器）或回到非终态则不回收
    if (!isTerminalStage(current.stage)) {
      return;
    }
    releaseSession(current);
  }, delay);
  reclaimTimers.set(sessionId, timer);
}

/** 释放会话：通知适配器释放协议资源并从注册表移除（不发布变更通知，供批量移除统一收口）。 */
function removeSession(session: TransferSession): void {
  let adapter = getAdapter(session.protocolKey);
  if (adapter !== undefined) {
    try {
      adapter.dispose(session.id);
    } catch (e) {
      logger.warn('adapter dispose failed: ' + String(e));
    }
  }
  sessions.delete(session.id);
  speedSamples.delete(session.id);
  activityTimes.delete(session.id);
}

/** 回收会话：从注册表移除并发布变更通知（终态可见窗口到期路径）。 */
function releaseSession(session: TransferSession): void {
  removeSession(session);
  logger.info(`会话回收 id=${session.id} 结果=${session.stage} 已归档=${isTerminalStage(session.stage)}`);
  notifyChange();
}

/**
 * 同设备取代：移除指定对端全部**已终态**会话的可见条目（取消其回收定时器并按回收路径释放），
 * 不触碰任何非终态会话与其它对端；返回被移除数量。变更通知在一次内发布。
 * 调用点必须在**新会话创建之前**，保证不会误删本次会话。
 */
export function replaceTerminalSessionsForPeer(identity: PeerIdentity): number {
  let matched: Array<string> = [];
  sessions.forEach((session: TransferSession, sessionId: string) => {
    if (!isTerminalStage(session.stage)) {
      return;
    }
    if (!isSamePeer(identity, peerIdentityOf(session.peer))) {
      return;
    }
    matched.push(sessionId);
  });
  return removeTerminalByIds(matched, '同设备取代');
}

/**
 * 批量移除已终态会话（取消其回收定时器 → 按回收路径释放）；
 * 非终态与不存在的标识一律跳过；一次变更通知内完成。
 */
function removeTerminalByIds(ids: Array<string>, reason: string): number {
  let removed: Array<string> = [];
  for (let i = 0; i < ids.length; i++) {
    let session = sessions.get(ids[i]);
    if (session === undefined || !isTerminalStage(session.stage)) {
      continue;
    }
    cancelReclaim(ids[i]);
    removeSession(session);
    removed.push(ids[i]);
  }
  if (removed.length > 0) {
    logger.info(`${reason} 移除已终态会话=${removed.length} 标识=[${removed.join(',')}]`);
    notifyChange();
  }
  return removed.length;
}

// ── 无进展看门狗（发送方向兜底终结） ──

/**
 * 无进展检查入口（可注入当前时刻，供用例确定性驱动）：
 * 对全部发送方向的非终态会话按纯函数逐一体检，超阈值者按失败终结并记录可诊断的错误信息与错误码。
 * 与既有入口收口兜底幂等：已终态会话由 finish 直接跳过，首次到达的终态为唯一最终结果。
 * @returns 被终结的会话数
 */
export function checkNoProgress(nowMs: number): number {
  let expired: Array<string> = [];
  sessions.forEach((session: TransferSession, sessionId: string) => {
    if (session.dataFlow !== SessionDataFlow.outbound || isTerminalStage(session.stage)) {
      return;
    }
    let last: number = activityTimes.get(sessionId) ?? session.startedAt;
    if (isNoProgressTimeout(nowMs, last, NO_PROGRESS_TIMEOUT_MS)) {
      expired.push(sessionId);
    }
  });
  let count: number = 0;
  for (let i = 0; i < expired.length; i++) {
    let session = sessions.get(expired[i]);
    if (session === undefined || isTerminalStage(session.stage)) {
      continue;
    }
    let last: number = activityTimes.get(expired[i]) ?? session.startedAt;
    let idleMs: number = nowMs - last;
    logger.warn(`无进展兜底终结 id=${expired[i]} 协议=${session.protocolKey}` +
      ` 无活动时长=${idleMs}ms 阈值=${NO_PROGRESS_TIMEOUT_MS}ms`);
    activityTimes.delete(expired[i]);
    finish(expired[i], SessionStage.failed, `长时间无进展（${idleMs}ms）`, NO_PROGRESS_ERROR_CODE);
    count++;
  }
  return count;
}

/** 是否存在发送方向的非终态会话（看门狗的存续条件）。 */
function hasActiveOutboundSession(): boolean {
  let found: boolean = false;
  sessions.forEach((session: TransferSession) => {
    if (!found && session.dataFlow === SessionDataFlow.outbound && !isTerminalStage(session.stage)) {
      found = true;
    }
  });
  return found;
}

/** 启动看门狗（幂等）：仅在存在发送方向非终态会话时运行，避免空转。 */
function ensureWatchdog(): void {
  if (watchdogTimer >= 0 || !hasActiveOutboundSession()) {
    return;
  }
  watchdogTimer = setInterval(() => {
    checkNoProgress(Date.now());
    // 无活跃发送会话时停止定时器
    if (!hasActiveOutboundSession()) {
      stopWatchdog();
    }
  }, WATCHDOG_INTERVAL_MS);
}

/** 停止看门狗并复位定时器句柄。 */
function stopWatchdog(): void {
  if (watchdogTimer >= 0) {
    clearInterval(watchdogTimer);
    watchdogTimer = -1;
  }
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

/**
 * 按协议键集合查询未终结会话（含待确认，排除终态）。
 * 供协议总开关关闭前的二次确认：列出将被中断的活跃传输明细。
 * 协议键取值：LocalSend 范围 = localsend-send / localsend-receive / web-download；
 * MTA 范围 = mta-send / mta-receive。
 */
export function listActiveSessionsByProtocolKeys(protocolKeys: Array<string>): Array<TransferSession> {
  let result: Array<TransferSession> = [];
  sessions.forEach((session: TransferSession) => {
    if (isTerminalStage(session.stage)) {
      return;
    }
    if (protocolKeys.indexOf(session.protocolKey) < 0) {
      return;
    }
    result.push(session);
  });
  return result;
}

/** 活跃（进行中）会话数：仅统计已进入传输的会话，排除待确认与终态。 */
export function getActiveCount(): number {
  let count: number = 0;
  sessions.forEach((session: TransferSession) => {
    if (session.stage === SessionStage.active) {
      count++;
    }
  });
  return count;
}

/**
 * 未完成（非终态）会话数：进行中 + 待确认，作为任务入口数量的统一口径。
 * 会话进入终态后不再计入。
 */
export function getUnfinishedCount(): number {
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

// ── 历史 ──

export function getHistory(filter?: SessionHistoryQuery): Array<SessionHistoryEntry> {
  return loadSessionHistory(filter);
}

/**
 * 清除任务历史：清空持久化历史 + 移除全部已终态的可见会话条目；
 * 不触碰进行中与待确认会话。变更通知在一次内发布，订阅者自动重算。
 */
export function clearHistory(): void {
  clearSessionHistory();
  let terminalIds: Array<string> = [];
  sessions.forEach((session: TransferSession, sessionId: string) => {
    if (isTerminalStage(session.stage)) {
      terminalIds.push(sessionId);
    }
  });
  let removed: number = removeTerminalByIds(terminalIds, '清除任务历史');
  // removeTerminalByIds 在被移除数大于 0 时已发布通知；此处补齐「仅有历史、无终态可见会话」的通知
  if (removed === 0) {
    notifyChange();
  }
}

/**
 * 按会话标识集合移除任务记录（多选删除）：
 * 移除持久化历史条目 + 移除对应的已终态可见会话条目。
 * 与「清除任务历史」同一语义口径（只动终态内容、不触碰进行中与待确认会话），
 * 非终态会话在 removeTerminalByIds 中一律跳过，历史侧也无对应记录，故行为与全量清除一致。
 * 变更通知在一次内发布，列表随通知自动重算。
 * @param ids 待移除的会话标识集合
 * @returns 实际移除的可见会话条目数（历史侧命中数见 removeSessionHistoryByIds 返回值）
 */
export function removeEntriesByIds(ids: Array<string>): number {
  if (ids.length === 0) {
    return 0;
  }
  let historyRemoved: number = removeSessionHistoryByIds(ids);
  let sessionRemoved: number = removeTerminalByIds(ids, '删除所选任务记录');
  // removeTerminalByIds 在被移除数大于 0 时已发布通知；此处补齐「仅有历史、无终态可见会话」的通知
  if (historyRemoved > 0 && sessionRemoved === 0) {
    notifyChange();
  }
  return sessionRemoved;
}

/**
 * 可清除计数 = 持久化历史条数 + 已终态可见会话数。
 * 与「清除任务历史」的实际可清除内容同源，作为入口可用性判定的唯一依据。
 */
export function getClearableCount(): number {
  let count: number = loadSessionHistory().length;
  sessions.forEach((session: TransferSession) => {
    if (isTerminalStage(session.stage)) {
      count++;
    }
  });
  return count;
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

/** 清空注册表、回收定时器与看门狗状态（仅测试与进程重置使用）。 */
export function resetRegistry(): void {
  reclaimTimers.forEach((timer: number) => {
    clearTimeout(timer);
  });
  reclaimTimers.clear();
  stopWatchdog();
  sessions.clear();
  speedSamples.clear();
  activityTimes.clear();
  idSeq = 0;
}
