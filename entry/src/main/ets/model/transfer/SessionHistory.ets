/**
 * SessionHistory.ets — 会话历史模型与存储接口契约
 *
 * 会话级历史台账（方向、来源协议、对端、文件数、总大小、结果、起止时间），
 * 有界 FIFO 保留、按会话标识幂等归档；与文件级接收历史相互独立。
 * 存储后端抽象为接口，本期由应用偏好存储实现。
 */

import { SessionDataFlow, SessionHistoryOutcome, SessionInitiator } from './TransferSession';

/** 当前会话历史 schema 版本（字段扩展时递增并按版本迁移）。 */
export const SESSION_HISTORY_SCHEMA_VERSION: number = 1;

/** 会话历史保留条数上限（有界 FIFO，最旧优先裁剪）。 */
export const SESSION_HISTORY_CAPACITY: number = 200;

/** 会话历史记录。 */
export interface SessionHistoryEntry {
  sessionId: string
  protocolKey: string
  dataFlow: SessionDataFlow
  initiatedBy: SessionInitiator
  peerName: string
  fileCount: number
  totalBytes: number
  outcome: SessionHistoryOutcome
  startedAt: number
  finishedAt: number
  schemaVersion: number
}

/** 持久化容器（单键 JSON）。 */
export interface SessionHistoryFile {
  schemaVersion: number
  entries: Array<SessionHistoryEntry>
}

/** 会话历史查询条件（字段缺省表示不筛）。 */
export interface SessionHistoryQuery {
  protocolKey?: string
  dataFlow?: SessionDataFlow
}

/**
 * 会话历史存储抽象接口。
 * 调用方只依赖本接口，未来可平滑替换存储后端（如关系型数据库）。
 */
export interface SessionHistoryStore {
  load(): Array<SessionHistoryEntry>
  persist(entries: Array<SessionHistoryEntry>): void
  clear(): void
}

// ── 纯逻辑辅助（可独立测试） ──

/**
 * 是否将终态会话归档为历史记录。
 * 被拒绝、以及因发送方撤回/取消而终结的「待确认」请求不写入历史：
 * 用户尚未与请求建立传输关系，不构成一次已发生的传输活动；
 * 已进入进行中之后的取消/失败仍照常归档。
 */
export function shouldArchiveSession(previouslyAwaitingConfirmation: boolean,
  outcome: SessionHistoryOutcome): boolean {
  if (!previouslyAwaitingConfirmation) {
    return true;
  }
  return outcome !== SessionHistoryOutcome.declined && outcome !== SessionHistoryOutcome.cancelled;
}

/** FIFO 裁剪：超出容量时丢弃最旧条目（按 finishedAt 升序为最旧）。 */
export function trimHistory(entries: Array<SessionHistoryEntry>,
  capacity: number = SESSION_HISTORY_CAPACITY): Array<SessionHistoryEntry> {
  if (capacity <= 0 || entries.length <= capacity) {
    return entries;
  }
  return entries.slice(entries.length - capacity);
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
 * schema 迁移：按版本补齐字段级默认值，保留旧字段可读。
 * 本期仅 v1；未知/更旧的版本统一补齐为当前版本。
 */
export function migrateHistoryFile(file: SessionHistoryFile): SessionHistoryFile {
  if (file.schemaVersion === SESSION_HISTORY_SCHEMA_VERSION) {
    return file;
  }
  let migrated: Array<SessionHistoryEntry> = [];
  for (let i = 0; i < file.entries.length; i++) {
    let e = file.entries[i];
    migrated.push({
      sessionId: e.sessionId,
      protocolKey: e.protocolKey,
      dataFlow: e.dataFlow,
      initiatedBy: e.initiatedBy,
      peerName: e.peerName,
      fileCount: e.fileCount,
      totalBytes: e.totalBytes,
      outcome: e.outcome,
      startedAt: e.startedAt,
      finishedAt: e.finishedAt,
      schemaVersion: SESSION_HISTORY_SCHEMA_VERSION
    });
  }
  return { schemaVersion: SESSION_HISTORY_SCHEMA_VERSION, entries: migrated };
}

/** 空容器工厂（避免调用方手写对象字面量）。 */
export function emptyHistoryFile(): SessionHistoryFile {
  return { schemaVersion: SESSION_HISTORY_SCHEMA_VERSION, entries: [] };
}
