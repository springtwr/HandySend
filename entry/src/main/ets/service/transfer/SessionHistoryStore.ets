/**
 * SessionHistoryStore.ets — 会话历史存储（抽象接口 + Preferences 实现）
 *
 * 单键 JSON 数组、有界 FIFO、携带 schemaVersion、按会话标识幂等归档。
 * 与注册表的终态可见窗口回收相互独立。
 *
 * Preferences 实现以**内存权威列表**承载读取：首次访问加载一次，写入先改内存再触发落盘，
 * 读取直命中内存，避免高频读取（传输中进度事件触发中心刷新）反复解析全量 JSON。
 */

import { preferencesUtil } from '../../utils/PreferencesUtil';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import {
  SESSION_HISTORY_CAPACITY,
  SESSION_HISTORY_SCHEMA_VERSION,
  SessionHistoryEntry,
  SessionHistoryFile,
  SessionHistoryFileEntry,
  SessionHistoryQuery,
  SessionHistoryStore,
  boundTimeline,
  emptyHistoryFile,
  queryHistory,
  sanitizeHistory,
  trimHistory,
  upsertHistory
} from '../../model/transfer/SessionHistory';
import { TransferSession, outcomeForStage } from '../../model/transfer/TransferSession';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionHistory', '会话历史');

// 与既有文件历史并列的独立 Preferences 键（互不干扰）
const SESSION_HISTORY_KEY: string = 'transferSessionHistory';

/**
 * 由会话派生历史记录（纯函数，可独立测试）。
 * 仅终态会话可归档；非终态返回 undefined。
 * 装配完整 v2 字段：对端设备信息、逐文件清单、时间与耗时、性能、结果与错误、
 * 完整时间线（有界）、本机设备与标识。
 */
export function buildHistoryEntry(session: TransferSession): SessionHistoryEntry | undefined {
  let outcome = outcomeForStage(session.stage);
  if (outcome === undefined) {
    return undefined;
  }
  let finishedAt: number = session.finishedAt > 0 ? session.finishedAt : Date.now();
  let durationMs: number = finishedAt > session.startedAt ? finishedAt - session.startedAt : 0;
  let files: Array<SessionHistoryFileEntry> = [];
  for (let i = 0; i < session.files.length; i++) {
    let f = session.files[i];
    files.push({
      fileId: f.fileId,
      fileName: f.fileName,
      fileType: f.fileType,
      size: f.totalBytes,
      stage: f.stage,
      checksum: f.checksum,
      path: f.path
    });
  }
  return {
    sessionId: session.id,
    protocolKey: session.protocolKey,
    protocolSessionId: session.protocolSessionId,
    dataFlow: session.dataFlow,
    initiatedBy: session.initiatedBy,
    peerName: session.peer.displayName,
    peerFingerprint: session.peer.fingerprint ?? '',
    peerIp: session.peer.ip ?? '',
    peerDeviceType: session.peer.deviceType ?? '',
    peerDeviceModel: session.peer.badges.length > 0 ? session.peer.badges[0] : '',
    files: files,
    fileCount: session.files.length,
    totalBytes: session.totalBytes,
    outcome: outcome,
    errorMessage: session.errorMessage,
    errorCode: session.errorCode,
    startedAt: session.startedAt,
    finishedAt: finishedAt,
    durationMs: durationMs,
    averageSpeedBps: session.averageSpeedBps,
    peakSpeedBps: session.peakSpeedBps,
    timeline: boundTimeline(session.timeline),
    localAlias: session.localAlias,
    localIp: session.localIp,
    localInterfaceName: session.localInterfaceName,
    schemaVersion: SESSION_HISTORY_SCHEMA_VERSION
  };
}

/**
 * 基于应用偏好存储的会话历史实现（本期默认后端）。
 *
 * 持有**内存权威列表**：首次访问时从偏好存储加载一次并缓存；此后读取直接命中内存，
 * 避免每次注册表变更（传输中进度事件高频触发）都做一次同步读 + 全量 JSON 解析。
 * 写入先更新内存（立即对读取可见）再触发落盘；偏好存储自身对刷盘做防抖合并。
 */
class PreferencesSessionHistoryStore implements SessionHistoryStore {
  // null 表示尚未从偏好存储加载（惰性加载一次）
  private cache: Array<SessionHistoryEntry> | null = null;

  load(): Array<SessionHistoryEntry> {
    let cached: Array<SessionHistoryEntry> | null = this.cache;
    if (cached === null) {
      cached = this.readFromPreferences();
      this.cache = cached;
    }
    return cached;
  }

  persist(entries: Array<SessionHistoryEntry>): void {
    // 先更新内存权威列表，再触发落盘（FIFO 裁剪语义不变）
    let trimmed: Array<SessionHistoryEntry> = trimHistory(entries, SESSION_HISTORY_CAPACITY);
    this.cache = trimmed;
    this.writeToPreferences(trimmed);
  }

  clear(): void {
    // 先更新内存（清空立即对读取可见），再触发落盘
    this.cache = [];
    this.writeToPreferences([]);
    // 破坏性操作立即落盘：避免防抖刷盘窗口内进程被杀导致冷启动后历史重现
    preferencesUtil.flushNow();
  }

  /** 失效内存缓存：下次读取重新从偏好存储加载（测试与重置场景）。 */
  reset(): void {
    this.cache = null;
  }

  private readFromPreferences(): Array<SessionHistoryEntry> {
    let file: SessionHistoryFile = preferencesUtil.getObject<SessionHistoryFile>(
      SESSION_HISTORY_KEY, emptyHistoryFile());
    if (file.entries === undefined) {
      return [];
    }
    // 读取即自愈：去重 + 聚合字段以逐文件清单为准重建，一次性清理既有脏数据
    let sanitized: Array<SessionHistoryEntry> = sanitizeHistory(file.entries);
    // 清洗结果回写持久化：既有污点数据在此自动修正，后续读取恒为干净数据
    this.writeToPreferences(sanitized);
    return sanitized;
  }

  private writeToPreferences(entries: Array<SessionHistoryEntry>): void {
    let file: SessionHistoryFile = {
      schemaVersion: SESSION_HISTORY_SCHEMA_VERSION,
      entries: entries
    };
    preferencesUtil.setObject<SessionHistoryFile>(SESSION_HISTORY_KEY, file);
  }
}

// 保留具体实现引用：对外仅暴露抽象接口，缓存失效入口经此转发
const preferencesHistoryStore: PreferencesSessionHistoryStore = new PreferencesSessionHistoryStore();

/** 当前生效的会话历史存储（调用方只依赖抽象接口）。 */
export const sessionHistoryStore: SessionHistoryStore = preferencesHistoryStore;

/**
 * 失效会话历史内存缓存：下次读取重新从偏好存储加载。
 * 供测试与重置场景使用；清空历史请走 clearSessionHistory（其会直接更新内存权威列表）。
 */
export function resetSessionHistoryCache(): void {
  preferencesHistoryStore.reset();
}

/**
 * 归档一个终态会话（幂等；非终态为 no-op）。
 * 所有终态会话统一归档，包含待确认阶段被拒绝/撤回/超时终结的会话，
 * 保证终态可见窗口结束后仍有唯一可进入的历史入口。
 */
export function archiveSession(session: TransferSession): void {
  let outcome = outcomeForStage(session.stage);
  if (outcome === undefined) {
    return;
  }
  let entry = buildHistoryEntry(session);
  if (entry === undefined) {
    return;
  }
  let current: Array<SessionHistoryEntry> = sessionHistoryStore.load();
  sessionHistoryStore.persist(upsertHistory(current, entry));
  logger.debug('archived session ' + session.id + ' files=' + session.files.length + ' outcome=' + entry.outcome);
}

/** 读取会话历史（按条件筛选、时间倒序）。 */
export function getSessionHistory(query?: SessionHistoryQuery): Array<SessionHistoryEntry> {
  return queryHistory(sessionHistoryStore.load(), query);
}

/** 清空会话历史。 */
export function clearSessionHistory(): void {
  sessionHistoryStore.clear();
  logger.info('session history cleared');
}
