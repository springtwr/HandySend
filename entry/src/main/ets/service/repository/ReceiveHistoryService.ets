import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { ReceiveHistoryEntry } from '../../model/Types';
import {
  HISTORY_SEGMENT_SIZE,
  RECEIVE_HISTORY_CAPACITY,
  RECEIVE_HISTORY_SEGMENT_COUNT
} from '../../model/HistoryCapacity';
import {
  DirtyRange,
  dirtyRange,
  existingSegments,
  planSegments,
  segmentKey,
  segmentsOfDirtyRange
} from '../../model/HistorySegments';
import { receiveHistoryPreferencesUtil } from '../../utils/PreferencesUtil';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:ReceiveHistoryService', '历史');

// 独立存储文件（handysend_receive_history）中的段键前缀；布局契约见 model/HistorySegments.ets。
// LEGACY_HISTORY_KEY 是分段之前的单键，仅在一次性迁移中读取后删除。
const HISTORY_PREFIX: string = 'receiveHistory';
const LEGACY_HISTORY_KEY: string = 'receiveHistory';

let history: Array<ReceiveHistoryEntry> = [];
// 上一次落盘的条目快照：用于比对出变更区间，只重写受影响的段
let lastPersisted: Array<ReceiveHistoryEntry> = [];

export function initHistory(context: common.UIAbilityContext): void {
  logger.debug('初始化历史');
  // 确保读写前接收历史偏好存储已初始化
  receiveHistoryPreferencesUtil.init(context);
  history = readAllSegments();
  lastPersisted = history.slice();
  logger.debug('已加载 ' + history.length + ' 条记录');
}

export function getHistory(): Array<ReceiveHistoryEntry> {
  return history;
}

// FIFO 裁剪到上限：丢弃最旧条目。裁剪会静默移除用户可见的历史记录，
// 故按次留痕（每轮裁剪一条日志，不逐条刷屏），使「记录为何消失」在日志中可追溯。
function trimToCapacity(): void {
  let dropped: number = 0;
  while (history.length > RECEIVE_HISTORY_CAPACITY) {
    history.shift();
    dropped++;
  }
  if (dropped > 0) {
    logger.debug('历史已裁剪 dropped=' + dropped + ' capacity=' + RECEIVE_HISTORY_CAPACITY);
  }
}

// 追加一条或多条记录（一次传输的多个文件共用一次落盘）。
// 逐条追加每次都序列化该追加触及的段（追加只触及末段），批量后每次传输只落盘一次。
export function addEntries(entries: Array<ReceiveHistoryEntry>): void {
  if (entries.length === 0) {
    return;
  }
  for (let i = 0; i < entries.length; i++) {
    history.push(entries[i]);
  }
  trimToCapacity();
  saveHistory();
  logger.debug('已添加 ' + entries.length + ' 条记录');
}

export function removeEntry(id: string, deleteFile?: boolean): void {
  // 需要同时删除磁盘文件时，先找到目标条目并删除其文件
  if (deleteFile === true) {
    for (let i = 0; i < history.length; i++) {
      if (history[i].id === id) {
        deleteEntryFile(history[i]);
        break;
      }
    }
  }
  let updated: Array<ReceiveHistoryEntry> = [];
  for (let i = 0; i < history.length; i++) {
    if (history[i].id !== id) {
      updated.push(history[i]);
    }
  }
  history = updated;
  saveHistory();
  logger.debug('已移除 id=' + id);
}

// 按 id 集合批量移除记录（多选删除）：集合为空直接返回，避免无谓落盘；
// deleteFiles 为真时先删除命中条目的磁盘文件（单个失败不中断），再统一移除记录并落盘一次。
export function removeEntries(ids: Array<string>, deleteFiles?: boolean): void {
  if (ids.length === 0) {
    return;
  }
  if (deleteFiles === true) {
    for (let i = 0; i < history.length; i++) {
      if (ids.indexOf(history[i].id) >= 0) {
        deleteEntryFile(history[i]);
      }
    }
  }
  let updated: Array<ReceiveHistoryEntry> = [];
  for (let i = 0; i < history.length; i++) {
    if (ids.indexOf(history[i].id) < 0) {
      updated.push(history[i]);
    }
  }
  history = updated;
  saveHistory();
  logger.debug('已移除 ' + ids.length + ' 条记录');
}

export function clearAll(deleteFiles?: boolean): void {
  // 需要同时删除磁盘文件时，先遍历全部条目删除对应文件（单个失败不中断）
  if (deleteFiles === true) {
    for (let i = 0; i < history.length; i++) {
      deleteEntryFile(history[i]);
    }
  }
  history = [];
  saveHistory();
  logger.debug('已清空全部历史');
}

// 删除单条历史记录对应的磁盘文件（best-effort）。
// 文本文件与普通文件一致删除（文本即文件，不再有"文本跳过删除"造成的孤儿文件）；
// 空 path 或文件缺失时静默跳过。
function deleteEntryFile(entry: ReceiveHistoryEntry): void {
  if (entry.path.length === 0) {
    return;
  }
  try {
    fs.unlinkSync(entry.path);
  } catch (_e) {
    // 文件不存在或删除失败——静默跳过
  }
}

// 更新历史记录的 savedToGallery 标记（相册保存成功后调用）
export function updateGallerySavedStatus(sessionId: string, saved: boolean): void {
  let updated: boolean = false;
  for (let i = 0; i < history.length; i++) {
    if (history[i].id.startsWith(sessionId + '_')) {
      // 写时复制而非原地修改：落盘按对象引用比对变更区间，原地修改引用不变会被误判为无变化而跳过落盘
      let old: ReceiveHistoryEntry = history[i];
      history[i] = {
        id: old.id,
        fileName: old.fileName,
        fileType: old.fileType,
        path: old.path,
        savedToGallery: saved,
        isMessage: old.isMessage,
        fileSize: old.fileSize,
        senderAlias: old.senderAlias,
        timestamp: old.timestamp,
        textContent: old.textContent
      };
      updated = true;
    }
  }
  if (updated) {
    saveHistory();
    logger.debug('sessionId=' + sessionId.substring(0, 8) + ' saved=' + saved);
  }
}

/**
 * 落盘：按分段写入（段键布局见 model/HistorySegments.ets）。
 * 偏好存储只能按键整体覆写，单键方案每次写入都要序列化全量历史，代价随保留条数
 * 线性增长；分段后只重写变更区间覆盖的段，追加（最常见的写入）仅触及末段。
 */
function saveHistory(): void {
  if (history.length === 0) {
    // 必须删键而非写入空段：残留的段键会在下次加载时被拼接回来，使已清空的历史重现
    deleteAllSegments();
    // 老键同删：崩溃窗口遗留的老键若不清理，会在段键清空后的下次加载中复活历史
    receiveHistoryPreferencesUtil.delete(LEGACY_HISTORY_KEY);
    lastPersisted = [];
    return;
  }
  let segments: Array<Array<ReceiveHistoryEntry>> = planSegments(history,
    RECEIVE_HISTORY_CAPACITY, HISTORY_SEGMENT_SIZE);
  let range: DirtyRange | undefined = dirtyRange(lastPersisted, history);
  if (range !== undefined) {
    let dirty: Array<number> = segmentsOfDirtyRange(range, HISTORY_SEGMENT_SIZE);
    for (let i = 0; i < dirty.length; i++) {
      let segIndex: number = dirty[i];
      if (segIndex < segments.length) {
        writeSegment(segIndex, segments[segIndex]);
      }
    }
  }
  // 段数减少（裁剪）时删除尾部残留段键
  let previousCount: number = Math.ceil(lastPersisted.length / HISTORY_SEGMENT_SIZE);
  for (let i = segments.length; i < previousCount; i++) {
    receiveHistoryPreferencesUtil.delete(segmentKey(HISTORY_PREFIX, i));
  }
  lastPersisted = history.slice();
}

/**
 * 读取全部分段并按「最旧在前」拼接，同时完成单键历史的一次性迁移。
 * 迁移方向单向且幂等：老键存在即读出并切成段写入，随后删除老键；老键即迁移标记，
 * 删除后该分支不再命中，无需额外的迁移状态或版本协商。
 */
function readAllSegments(): Array<ReceiveHistoryEntry> {
  let indices: Array<number> = existingSegments(HISTORY_PREFIX, (key: string): boolean => {
    return receiveHistoryPreferencesUtil.has(key);
  }, RECEIVE_HISTORY_SEGMENT_COUNT);
  if (indices.length === 0) {
    return migrateFromLegacyKey();
  }
  // 分段已存在但老键残留（迁移写入后、删老键前进程退出）：以段为准，老键为过期残留，直接删除。
  // 否则后续清空删除全部段键后，下次加载会误命中老键而使已清空的历史复活
  if (receiveHistoryPreferencesUtil.has(LEGACY_HISTORY_KEY)) {
    receiveHistoryPreferencesUtil.delete(LEGACY_HISTORY_KEY);
  }
  let entries: Array<ReceiveHistoryEntry> = [];
  for (let i = 0; i < indices.length; i++) {
    let segmentEntries: Array<ReceiveHistoryEntry> = parseEntries(
      receiveHistoryPreferencesUtil.getString(segmentKey(HISTORY_PREFIX, indices[i]), '[]'));
    for (let k = 0; k < segmentEntries.length; k++) {
      entries.push(segmentEntries[k]);
    }
  }
  return entries;
}

/** 单键历史迁移：切段写入并删除老键；老键不存在时返回空。 */
function migrateFromLegacyKey(): Array<ReceiveHistoryEntry> {
  if (!receiveHistoryPreferencesUtil.has(LEGACY_HISTORY_KEY)) {
    return [];
  }
  let entries: Array<ReceiveHistoryEntry> = parseEntries(
    receiveHistoryPreferencesUtil.getString(LEGACY_HISTORY_KEY, '[]'));
  let trimmed: Array<ReceiveHistoryEntry> = entries;
  while (trimmed.length > RECEIVE_HISTORY_CAPACITY) {
    trimmed.shift();
  }
  let segments: Array<Array<ReceiveHistoryEntry>> = planSegments(trimmed,
    RECEIVE_HISTORY_CAPACITY, HISTORY_SEGMENT_SIZE);
  for (let i = 0; i < segments.length; i++) {
    writeSegment(i, segments[i]);
  }
  for (let i = segments.length; i < RECEIVE_HISTORY_SEGMENT_COUNT; i++) {
    receiveHistoryPreferencesUtil.delete(segmentKey(HISTORY_PREFIX, i));
  }
  receiveHistoryPreferencesUtil.delete(LEGACY_HISTORY_KEY);
  logger.info('历史已迁移为分段存储 count=' + trimmed.length);
  return trimmed;
}

function writeSegment(segIndex: number, entries: Array<ReceiveHistoryEntry>): void {
  receiveHistoryPreferencesUtil.setString(segmentKey(HISTORY_PREFIX, segIndex),
    JSON.stringify(entries));
}

/** 删除全部分段键（含空档）：键不存在时静默跳过。 */
function deleteAllSegments(): void {
  for (let i = 0; i < RECEIVE_HISTORY_SEGMENT_COUNT; i++) {
    receiveHistoryPreferencesUtil.delete(segmentKey(HISTORY_PREFIX, i));
  }
}

/** 解析条目数组：非数组或解析失败时返回空数组。 */
function parseEntries(raw: string): Array<ReceiveHistoryEntry> {
  try {
    let parsed: Object = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      return parsed as Array<ReceiveHistoryEntry>;
    }
  } catch (_e) {
    // 解析失败按空历史处理
  }
  return [];
}
