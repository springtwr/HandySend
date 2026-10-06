import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { ReceiveHistoryEntry } from '../../model/Types';
import { RECEIVE_HISTORY_CAPACITY } from '../../model/HistoryCapacity';
import { receiveHistoryPreferencesUtil } from '../../utils/PreferencesUtil';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:ReceiveHistoryService', '历史');
const HISTORY_KEY = 'receiveHistory';

let history: Array<ReceiveHistoryEntry> = [];

export function initHistory(context: common.UIAbilityContext): void {
  logger.debug('initHistory');
  // 确保读写前接收历史偏好存储已初始化
  receiveHistoryPreferencesUtil.init(context);
  let raw: string = receiveHistoryPreferencesUtil.getString(HISTORY_KEY, '[]');
  try {
    let parsed: Object = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      history = parsed as Array<ReceiveHistoryEntry>;
    } else {
      history = [];
    }
  } catch (_e) {
    history = [];
  }
  logger.debug('loaded ' + history.length + ' entries');
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
    logger.info('history trimmed dropped=' + dropped + ' capacity=' + RECEIVE_HISTORY_CAPACITY);
  }
}

// 追加一条或多条记录（一次传输的多个文件共用一次落盘）。
// 逐条追加每次都全量序列化整个列表（序列化次数 = 文件数），
// 批量后每次传输只序列化一次。
export function addEntries(entries: Array<ReceiveHistoryEntry>): void {
  if (entries.length === 0) {
    return;
  }
  for (let i = 0; i < entries.length; i++) {
    history.push(entries[i]);
  }
  trimToCapacity();
  saveHistory();
  logger.debug('added ' + entries.length + ' entries');
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
  logger.debug('removed id=' + id);
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
  logger.debug('removed ' + ids.length + ' entries');
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
  logger.debug('cleared all history');
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
      history[i].savedToGallery = saved;
      updated = true;
    }
  }
  if (updated) {
    saveHistory();
    logger.debug('sessionId=' + sessionId.substring(0, 8) + ' saved=' + saved);
  }
}

function saveHistory(): void {
  receiveHistoryPreferencesUtil.setString(HISTORY_KEY, JSON.stringify(history));
}
