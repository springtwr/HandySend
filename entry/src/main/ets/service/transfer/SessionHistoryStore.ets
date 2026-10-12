/**
 * SessionHistoryStore.ets — 任务历史存储（抽象接口 + Preferences 实现）
 *
 * 分段 JSON、有界 FIFO、携带 schemaVersion、按会话标识幂等归档。
 * 与注册表的终态可见窗口回收相互独立。
 *
 * Preferences 实现以**内存权威列表**承载读取：首次访问加载一次，写入先改内存再触发落盘，
 * 读取直命中内存，避免高频读取（传输中进度事件触发中心刷新）反复解析全量 JSON。
 */

import { sessionHistoryPreferencesUtil } from '../../utils/PreferencesUtil';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { notifyChange } from '../repository/AppCore';
import {
  SESSION_HISTORY_SCHEMA_VERSION,
  SessionHistoryEntry,
  SessionHistoryFile,
  SessionHistoryFileEntry,
  SessionHistoryQuery,
  SessionHistoryStore,
  boundTimeline,
  collectSelfBuiltFilePaths,
  emptyHistoryFile,
  persistedTimelineOf,
  queryHistory,
  removeHistoryByIds,
  sanitizeHistory,
  trimHistory,
  upsertHistory
} from '../../model/transfer/SessionHistory';
import { TransferSession, outcomeForStage } from '../../model/transfer/TransferSession';
import {
  HISTORY_SEGMENT_SIZE,
  SESSION_HISTORY_CAPACITY,
  SESSION_HISTORY_SEGMENT_COUNT
} from '../../model/HistoryCapacity';
import {
  DirtyRange,
  dirtyRange,
  existingSegments,
  planSegments,
  segmentKey,
  segmentsOfDirtyRange
} from '../../model/HistorySegments';
import { removeSendTextFiles, sendTextDir } from '../repository/SendRepository';
import { recvTextDir } from '../repository/ReceiveTargets';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionHistory', '任务历史');

// 独立的任务历史 Preferences 存储（handysend_session_history）中的段键前缀；
// 段键为「前缀 + # + 段号」，布局契约见 model/HistorySegments.ets。
// LEGACY_SESSION_HISTORY_KEY 是分段之前的单键，仅在一次性迁移中读取后删除。
const SESSION_HISTORY_PREFIX: string = 'transferSessionHistory';
const LEGACY_SESSION_HISTORY_KEY: string = 'transferSessionHistory';

/**
 * 任务历史内容版本号（进程内信号，不参与持久化）。
 * 仅在持久化内容可能变化时自增：归档、清除、删除，以及读取时清洗确有改动而回写。
 * 展示层据此判断历史行是否需要重建——传输中进度事件会高频触发列表刷新，
 * 而历史条目在这些刷新间完全不变，无需逐次重建全量历史行。
 */
let historyRevision: number = 0;

/** 当前任务历史内容版本号；内容可能已变化则较上次取值不同。 */
export function getHistoryRevision(): number {
  return historyRevision;
}

/**
 * 两个条目集合是否逐项同引用（纯函数，可独立测试）。
 * sanitizeHistory 对未受影响的条目保持原对象引用，只有被剔除的条目与
 * 被重建聚合字段的条目才产生新引用，故长度 + 引用全等即等价，无需深比较。
 */
export function isSameEntries(a: Array<SessionHistoryEntry>,
  b: Array<SessionHistoryEntry>): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

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
  // 耗时与时间线口径严格一致（与详情页实时口径相同）：起止时间各自截断毫秒后取差，
  // 避免「毫秒差向下取整」与「时间线绝对时间之差」偶发 1 秒偏差
  let durationMs: number = 0;
  if (finishedAt > session.startedAt) {
    durationMs = (Math.floor(finishedAt / 1000) - Math.floor(session.startedAt / 1000)) * 1000;
  }
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
  let entry: SessionHistoryEntry = {
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
    timeline: persistedTimelineOf(boundTimeline(session.timeline)),
    localAlias: session.localAlias,
    localIp: session.localIp,
    localInterfaceName: session.localInterfaceName,
    schemaVersion: SESSION_HISTORY_SCHEMA_VERSION
  };
  // MTA 品牌标识：仅当会话携带时写入（非 MTA 来源/旧数据缺省为 undefined，展示层按非 MTA 降级）
  if (session.peer.mtaBrandId !== undefined) {
    entry.peerMtaBrandId = session.peer.mtaBrandId;
  }
  return entry;
}

/**
 * 基于应用偏好存储的任务历史实现（本期默认后端）。
 *
 * 持有**内存权威列表**：首次访问时从偏好存储加载一次并缓存；此后读取直接命中内存，
 * 避免每次注册表变更（传输中进度事件高频触发）都做一次同步读 + 全量 JSON 解析。
 * 写入先更新内存（立即对读取可见）再触发落盘；偏好存储自身对刷盘做防抖合并。
 *
 * 落盘按**分段**进行（段键布局见 model/HistorySegments.ets）：偏好存储只能按键整体
 * 覆写，单键方案每次写入都要序列化全量历史，代价随保留条数线性增长。分段后新增条目
 * 只重写当前活跃段，代价与总量解耦；裁剪只丢弃最旧的整段。
 */
class PreferencesSessionHistoryStore implements SessionHistoryStore {
  // null 表示尚未从偏好存储加载（惰性加载一次）
  private cache: Array<SessionHistoryEntry> | null = null;
  // 上一次落盘的条目快照：用于比对出变更区间，只重写受影响的段
  private lastPersisted: Array<SessionHistoryEntry> = [];

  load(): Array<SessionHistoryEntry> {
    let cached: Array<SessionHistoryEntry> | null = this.cache;
    if (cached === null) {
      cached = this.readFromPreferences();
      this.cache = cached;
      this.lastPersisted = cached.slice();
    }
    return cached;
  }

  persist(entries: Array<SessionHistoryEntry>): void {
    // 先更新内存权威列表，再触发落盘（FIFO 裁剪语义不变）
    let trimmed: Array<SessionHistoryEntry> = trimHistory(entries, SESSION_HISTORY_CAPACITY);
    this.cache = trimmed;
    this.writeDirtySegments(trimmed);
    historyRevision++;
  }

  clear(): void {
    // 先更新内存（清空立即对读取可见），再删除全部分段键。
    // 必须删键而非写入空段：残留的段键会在下次读取时被拼接回来，使已清空的历史重现
    this.cache = [];
    this.deleteAllSegments();
    // 老键同删：崩溃窗口遗留的老键若不清理，会在段键清空后的下次读取中复活历史
    sessionHistoryPreferencesUtil.delete(LEGACY_SESSION_HISTORY_KEY);
    this.lastPersisted = [];
    historyRevision++;
    // 破坏性操作立即落盘：避免防抖刷盘窗口内进程被杀导致冷启动后历史重现
    sessionHistoryPreferencesUtil.flushNow();
  }

  /** 失效内存缓存：下次读取重新从偏好存储加载（测试与重置场景）。 */
  reset(): void {
    this.cache = null;
    this.lastPersisted = [];
  }

  private readFromPreferences(): Array<SessionHistoryEntry> {
    let entries: Array<SessionHistoryEntry> = this.readAllSegments();
    // 读取即自愈：去重 + 聚合字段以逐文件清单为准重建，一次性清理既有脏数据
    let sanitized: Array<SessionHistoryEntry> = sanitizeHistory(entries);
    // 仅在清洗确有改动时回写：健康数据此前每次冷启动都要全量序列化并覆写一遍，
    // 属纯浪费。判定按引用与顺序比对——sanitizeHistory 未改动的条目保持原对象引用，
    // 被剔除或重建聚合字段的条目才会导致不等。
    if (!isSameEntries(entries, sanitized)) {
      // 清洗结果回写持久化：既有污点数据在此自动修正，后续读取恒为干净数据
      this.writeDirtySegments(sanitized);
      this.lastPersisted = sanitized.slice();
      historyRevision++;
    }
    return sanitized;
  }

  /**
   * 读取全部分段并按「最旧在前」拼接，同时完成单键历史的一次性迁移。
   * 迁移方向单向且幂等：老键存在即读出并切成段写入，随后删除老键；老键即迁移标记，
   * 删除后该分支不再命中，无需额外的迁移状态或版本协商。
   */
  private readAllSegments(): Array<SessionHistoryEntry> {
    let indices: Array<number> = existingSegments(SESSION_HISTORY_PREFIX, (key: string): boolean => {
      return sessionHistoryPreferencesUtil.has(key);
    }, SESSION_HISTORY_SEGMENT_COUNT);
    if (indices.length === 0) {
      return this.migrateFromLegacyKey();
    }
    // 分段已存在但老键残留（迁移写入后、删老键前进程退出）：以段为准，老键为过期残留，直接删除。
    // 否则后续清空删除全部段键后，下次读取会误命中老键而使已清空的历史复活
    if (sessionHistoryPreferencesUtil.has(LEGACY_SESSION_HISTORY_KEY)) {
      sessionHistoryPreferencesUtil.delete(LEGACY_SESSION_HISTORY_KEY);
    }
    let entries: Array<SessionHistoryEntry> = [];
    for (let i = 0; i < indices.length; i++) {
      let file: SessionHistoryFile = sessionHistoryPreferencesUtil.getObject<SessionHistoryFile>(
        segmentKey(SESSION_HISTORY_PREFIX, indices[i]), emptyHistoryFile());
      if (file.entries === undefined) {
        continue;
      }
      for (let k = 0; k < file.entries.length; k++) {
        entries.push(file.entries[k]);
      }
    }
    return entries;
  }

  /** 单键历史迁移：切段写入并删除老键；老键不存在时返回空。 */
  private migrateFromLegacyKey(): Array<SessionHistoryEntry> {
    if (!sessionHistoryPreferencesUtil.has(LEGACY_SESSION_HISTORY_KEY)) {
      return [];
    }
    let legacy: SessionHistoryFile = sessionHistoryPreferencesUtil.getObject<SessionHistoryFile>(
      LEGACY_SESSION_HISTORY_KEY, emptyHistoryFile());
    let entries: Array<SessionHistoryEntry> = legacy.entries ?? [];
    let trimmed: Array<SessionHistoryEntry> = trimHistory(entries, SESSION_HISTORY_CAPACITY);
    this.writeAllSegments(trimmed);
    this.lastPersisted = trimmed.slice();
    sessionHistoryPreferencesUtil.delete(LEGACY_SESSION_HISTORY_KEY);
    logger.info('历史已迁移为分段 count=' + trimmed.length);
    return trimmed;
  }

  /**
   * 只重写变更区间覆盖的段，并删除超出段数的残留段键。
   * 追加（最常见的写入）变更区间落在末段，故每次只序列化一段。
   */
  private writeDirtySegments(entries: Array<SessionHistoryEntry>): void {
    let segments: Array<Array<SessionHistoryEntry>> = planSegments(entries,
      SESSION_HISTORY_CAPACITY, HISTORY_SEGMENT_SIZE);
    let range: DirtyRange | undefined = dirtyRange(this.lastPersisted, entries);
    if (range !== undefined) {
      let dirty: Array<number> = segmentsOfDirtyRange(range, HISTORY_SEGMENT_SIZE);
      for (let i = 0; i < dirty.length; i++) {
        let segIndex: number = dirty[i];
        if (segIndex < segments.length) {
          this.writeSegment(segIndex, segments[segIndex]);
        }
      }
    }
    // 段数减少（裁剪）时删除尾部残留段键
    let previousCount: number = Math.ceil(this.lastPersisted.length / HISTORY_SEGMENT_SIZE);
    for (let i = segments.length; i < previousCount; i++) {
      sessionHistoryPreferencesUtil.delete(segmentKey(SESSION_HISTORY_PREFIX, i));
    }
    this.lastPersisted = entries.slice();
  }

  /** 全量重写所有段（迁移与无条件回写场景）。 */
  private writeAllSegments(entries: Array<SessionHistoryEntry>): void {
    let segments: Array<Array<SessionHistoryEntry>> = planSegments(entries,
      SESSION_HISTORY_CAPACITY, HISTORY_SEGMENT_SIZE);
    for (let i = 0; i < segments.length; i++) {
      this.writeSegment(i, segments[i]);
    }
    for (let i = segments.length; i < SESSION_HISTORY_SEGMENT_COUNT; i++) {
      sessionHistoryPreferencesUtil.delete(segmentKey(SESSION_HISTORY_PREFIX, i));
    }
  }

  private writeSegment(segIndex: number, entries: Array<SessionHistoryEntry>): void {
    let file: SessionHistoryFile = {
      schemaVersion: SESSION_HISTORY_SCHEMA_VERSION,
      entries: entries
    };
    sessionHistoryPreferencesUtil.setObject<SessionHistoryFile>(
      segmentKey(SESSION_HISTORY_PREFIX, segIndex), file);
  }

  /** 删除全部分段键（含空档）：键不存在时静默跳过。 */
  private deleteAllSegments(): void {
    for (let i = 0; i < SESSION_HISTORY_SEGMENT_COUNT; i++) {
      sessionHistoryPreferencesUtil.delete(segmentKey(SESSION_HISTORY_PREFIX, i));
    }
  }
}

// 保留具体实现引用：对外仅暴露抽象接口，缓存失效入口经此转发
const preferencesHistoryStore: PreferencesSessionHistoryStore = new PreferencesSessionHistoryStore();

/** 当前生效的任务历史存储（调用方只依赖抽象接口）。 */
export const sessionHistoryStore: SessionHistoryStore = preferencesHistoryStore;

/**
 * 失效任务历史内存缓存：下次读取重新从偏好存储加载。
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
  logger.debug('已归档会话 ' + session.id + ' files=' + session.files.length + ' outcome=' + entry.outcome);
}

/** 读取任务历史（按条件筛选、时间倒序）。 */
export function getSessionHistory(query?: SessionHistoryQuery): Array<SessionHistoryEntry> {
  return queryHistory(sessionHistoryStore.load(), query);
}

/**
 * 清理一组条目对应的应用自建文件：按发送/接收文本目录前缀筛出可删路径后逐个删除，
 * 随后发布变更总线通知，驱动发送暂存列表自检移除底层文件已消失的手动文本条目。
 * 仅清理随记录失效即失去引用价值的自建产物（详见 collectSelfBuiltFilePaths 的判据说明）；
 * picker 原始文件与 Download 落盘文件不在此列。
 */
function removeSelfBuiltFilesOf(entries: Array<SessionHistoryEntry>): void {
  let paths: Array<string> = collectSelfBuiltFilePaths(entries, sendTextDir(), recvTextDir());
  if (paths.length === 0) {
    return;
  }
  let removedFiles: number = removeSendTextFiles(paths);
  if (removedFiles > 0) {
    logger.debug('已清理自建文件 count=' + removedFiles);
    notifyChange();
  }
}

/** 清空任务历史：清空记录并清理这些记录对应的应用自建文件。 */
export function clearSessionHistory(): void {
  let removedEntries: Array<SessionHistoryEntry> = sessionHistoryStore.load();
  sessionHistoryStore.clear();
  removeSelfBuiltFilesOf(removedEntries);
  logger.info('任务历史已清空');
}

/**
 * 按会话标识集合移除任务历史（多选删除），并清理这些记录对应的应用自建文件。
 * 与清空同为不可撤销的破坏性操作，故同样立即落盘，避免防抖刷盘窗口内进程被杀导致已删记录重现。
 * 集合为空或无命中记录时不产生任何变更（含不清理文件——无记录即无文件归属）。
 * @returns 被移除的条目数
 */
export function removeSessionHistoryByIds(ids: Array<string>): number {
  if (ids.length === 0) {
    return 0;
  }
  let current: Array<SessionHistoryEntry> = sessionHistoryStore.load();
  let remaining: Array<SessionHistoryEntry> = removeHistoryByIds(current, ids);
  if (remaining.length === current.length) {
    return 0;
  }
  let removed: number = current.length - remaining.length;
  // 命中条目为 current 与 remaining 的差集：逐条比对标识取出，供文件清理使用
  let removedEntries: Array<SessionHistoryEntry> = [];
  for (let i = 0; i < current.length; i++) {
    if (remaining.indexOf(current[i]) < 0) {
      removedEntries.push(current[i]);
    }
  }
  sessionHistoryStore.persist(remaining);
  sessionHistoryPreferencesUtil.flushNow();
  removeSelfBuiltFilesOf(removedEntries);
  logger.info('已移除任务历史 count=' + removed);
  return removed;
}
