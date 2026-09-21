import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { ReceiveHistoryEntry } from '../../model/Types';
import { preferencesUtil } from '../../utils/PreferencesUtil';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:ReceiveHistoryService', '历史');
const HISTORY_KEY = 'receiveHistory';
const MAX_HISTORY = 200;

let history: Array<ReceiveHistoryEntry> = [];

export function initHistory(context: common.UIAbilityContext): void {
  logger.debug('initHistory');
  // 确保读写前 preferences 已初始化
  preferencesUtil.init(context);
  let raw: string = preferencesUtil.getString(HISTORY_KEY, '[]');
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

export function addEntry(entry: ReceiveHistoryEntry): void {
  history.push(entry);
  // FIFO：超过上限时移除最旧的
  while (history.length > MAX_HISTORY) {
    history.shift();
  }
  saveHistory();
  logger.debug('added ' + entry.fileName);
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
  preferencesUtil.setString(HISTORY_KEY, JSON.stringify(history));
}
