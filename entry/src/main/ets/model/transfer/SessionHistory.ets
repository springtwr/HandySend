/**
 * SessionHistory.ets — 任务历史模型与存储接口契约
 *
 * 会话级历史台账（方向、来源协议、对端设备、逐文件清单、时间与耗时、性能、
 * 结果与错误、时间线、本机标识），有界 FIFO 保留、按会话标识幂等归档；
 * 与文件级接收历史相互独立。存储后端抽象为接口，本期由应用偏好存储实现。
 */

import {
  SessionDataFlow,
  SessionFileStage,
  SessionHistoryOutcome,
  SessionInitiator,
  SessionTimelineEvent
} from './TransferSession';

/**
 * 当前任务历史 schema 版本（单一当前版本，读写均按此版本；不实现版本迁移）。
 * v3 新增可选对端 MTA 品牌标识（`peerMtaBrandId`）；读取不校验版本，旧条目缺省该字段，
 * 按「非 MTA / 无品牌」降级，故无需迁移逻辑。
 */
export const SESSION_HISTORY_SCHEMA_VERSION: number = 3;

/** 任务历史保留条数上限（有界 FIFO，最旧优先裁剪）。 */
export const SESSION_HISTORY_CAPACITY: number = 200;

/** 单条历史的时间线保留上限（有界，避免长时传输时间线无界增长）。 */
export const SESSION_HISTORY_TIMELINE_CAPACITY: number = 50;

/** 任务历史中的逐文件条目（终态快照）。 */
export interface SessionHistoryFileEntry {
  fileId: string
  fileName: string
  fileType: string
  size: number
  // 终态文件阶段（完成/失败等）
  stage: SessionFileStage
  // 校验和/哈希（可选，未提供为空串）
  checksum: string
  // 该文件在磁盘上的位置（归档时透传；旧条目缺省为空，预览按不可用降级）
  path?: string
}

/** 任务历史记录（v3：完整传输信息快照）。 */
export interface SessionHistoryEntry {
  sessionId: string
  protocolKey: string
  // 协议侧会话标识（诊断用）
  protocolSessionId: string
  dataFlow: SessionDataFlow
  initiatedBy: SessionInitiator
  // ── 对端设备信息 ──
  peerName: string
  peerFingerprint: string
  peerIp: string
  peerDeviceType: string
  peerDeviceModel: string
  // MTA 来源品牌标识（可选）：存在即表示对端为互传（MTA）来源，驱动历史态设备卡品牌图标；
  // 旧条目缺省为 undefined，按非 MTA 降级
  peerMtaBrandId?: number
  // ── 逐文件清单与聚合 ──
  files: Array<SessionHistoryFileEntry>
  fileCount: number
  totalBytes: number
  // ── 结果与错误 ──
  outcome: SessionHistoryOutcome
  errorMessage: string
  errorCode: string
  // ── 时间与耗时 ──
  startedAt: number
  finishedAt: number
  durationMs: number
  // ── 传输性能 ──
  averageSpeedBps: number
  peakSpeedBps: number
  // ── 完整时间线（有界） ──
  timeline: Array<SessionTimelineEvent>
  // ── 本地设备与标识 ──
  localAlias: string
  localIp: string
  localInterfaceName: string
  schemaVersion: number
}

/** 持久化容器（单键 JSON）。 */
export interface SessionHistoryFile {
  schemaVersion: number
  entries: Array<SessionHistoryEntry>
}

/** 任务历史查询条件（字段缺省表示不筛）。 */
export interface SessionHistoryQuery {
  protocolKey?: string
  dataFlow?: SessionDataFlow
}

/**
 * 任务历史存储抽象接口。
 * 调用方只依赖本接口，未来可平滑替换存储后端（如关系型数据库）。
 */
export interface SessionHistoryStore {
  load(): Array<SessionHistoryEntry>

  persist(entries: Array<SessionHistoryEntry>): void

  clear(): void
}

// ── 纯逻辑辅助（可独立测试） ──

/** FIFO 裁剪：超出容量时丢弃最旧条目（按 finishedAt 升序为最旧）。 */
export function trimHistory(entries: Array<SessionHistoryEntry>,
  capacity: number = SESSION_HISTORY_CAPACITY): Array<SessionHistoryEntry> {
  if (capacity <= 0 || entries.length <= capacity) {
    return entries;
  }
  return entries.slice(entries.length - capacity);
}

/** 时间线有界保留：超出上限时丢弃最早的事件。 */
export function boundTimeline(timeline: Array<SessionTimelineEvent>): Array<SessionTimelineEvent> {
  if (timeline.length <= SESSION_HISTORY_TIMELINE_CAPACITY) {
    return timeline.slice();
  }
  return timeline.slice(timeline.length - SESSION_HISTORY_TIMELINE_CAPACITY);
}

/**
 * 按会话标识幂等 upsert：同会话重复终结不产生重复记录。
 * 已存在时以新记录替换（保留原位置），不存在时追加到末尾。
 */
export function upsertHistory(entries: Array<SessionHistoryEntry>,
  entry: SessionHistoryEntry): Array<SessionHistoryEntry> {
  let result: Array<SessionHistoryEntry> = [];
  let replaced: boolean = false;
  for (let i = 0; i < entries.length; i++) {
    if (entries[i].sessionId === entry.sessionId) {
      result.push(entry);
      replaced = true;
    } else {
      result.push(entries[i]);
    }
  }
  if (!replaced) {
    result.push(entry);
  }
  return result;
}

/** 按条件筛选历史（时间倒序：最近终结在前）。 */
export function queryHistory(entries: Array<SessionHistoryEntry>,
  query?: SessionHistoryQuery): Array<SessionHistoryEntry> {
  let filtered: Array<SessionHistoryEntry> = [];
  for (let i = 0; i < entries.length; i++) {
    let e = entries[i];
    if (query !== undefined) {
      if (query.protocolKey !== undefined && e.protocolKey !== query.protocolKey) {
        continue;
      }
      if (query.dataFlow !== undefined && e.dataFlow !== query.dataFlow) {
        continue;
      }
    }
    filtered.push(e);
  }
  filtered.sort((a: SessionHistoryEntry, b: SessionHistoryEntry): number => b.finishedAt - a.finishedAt);
  return filtered;
}

/**
 * 清洗历史列表（读取即自愈）：按会话标识去重（同标识保留 finishedAt 最新一条），
 * 逐条以逐文件清单为准重建聚合字段（fileCount = files.length、totalBytes = Σ files.size），
 * files 为空但 fileCount>0 的脏条目不参与展示。纯函数，可独立测试。
 */
export function sanitizeHistory(entries: Array<SessionHistoryEntry>): Array<SessionHistoryEntry> {
  // 每个 sessionId 保留 finishedAt 最新的一条（最新度相等时保留后出现者），
  // 记录其在原数组中的下标，第二轮按下标过滤以保持原相对顺序
  let bestIndex: Map<string, number> = new Map();
  for (let i = 0; i < entries.length; i++) {
    let e = entries[i];
    let current: number | undefined = bestIndex.get(e.sessionId);
    if (current === undefined) {
      bestIndex.set(e.sessionId, i);
    } else {
      let currentEntry: SessionHistoryEntry = entries[current];
      if (e.finishedAt > currentEntry.finishedAt ||
        (e.finishedAt === currentEntry.finishedAt && i > current)) {
        bestIndex.set(e.sessionId, i);
      }
    }
  }
  let result: Array<SessionHistoryEntry> = [];
  for (let i = 0; i < entries.length; i++) {
    if (bestIndex.get(entries[i].sessionId) !== i) {
      continue;
    }
    let e = entries[i];
    // files 为空但 fileCount>0 的脏条目剔除
    if (e.files.length === 0 && e.fileCount > 0) {
      continue;
    }
    let totalBytes: number = 0;
    for (let k = 0; k < e.files.length; k++) {
      totalBytes += e.files[k].size;
    }
    // 聚合字段与逐文件清单不一致：以清单为准重建
    if (e.fileCount !== e.files.length || e.totalBytes !== totalBytes) {
      result.push(rebuildAggregatesFromFiles(e, totalBytes));
    } else {
      result.push(e);
    }
  }
  return result;
}

/** 以逐文件清单为准重建聚合字段（fileCount/totalBytes），其余字段原样保留。 */
function rebuildAggregatesFromFiles(e: SessionHistoryEntry, totalBytes: number): SessionHistoryEntry {
  return {
    sessionId: e.sessionId,
    protocolKey: e.protocolKey,
    protocolSessionId: e.protocolSessionId,
    dataFlow: e.dataFlow,
    initiatedBy: e.initiatedBy,
    peerName: e.peerName,
    peerFingerprint: e.peerFingerprint,
    peerIp: e.peerIp,
    peerDeviceType: e.peerDeviceType,
    peerDeviceModel: e.peerDeviceModel,
    // 原样保留可选品牌标识（重建聚合字段时不得丢失）
    peerMtaBrandId: e.peerMtaBrandId,
    files: e.files,
    fileCount: e.files.length,
    totalBytes: totalBytes,
    outcome: e.outcome,
    errorMessage: e.errorMessage,
    errorCode: e.errorCode,
    startedAt: e.startedAt,
    finishedAt: e.finishedAt,
    durationMs: e.durationMs,
    averageSpeedBps: e.averageSpeedBps,
    peakSpeedBps: e.peakSpeedBps,
    timeline: e.timeline,
    localAlias: e.localAlias,
    localIp: e.localIp,
    localInterfaceName: e.localInterfaceName,
    schemaVersion: e.schemaVersion
  };
}

/** 空容器工厂（避免调用方手写对象字面量）。 */
export function emptyHistoryFile(): SessionHistoryFile {
  return { schemaVersion: SESSION_HISTORY_SCHEMA_VERSION, entries: [] };
}
