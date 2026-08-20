import { common } from '@kit.AbilityKit';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { ReceiveHistoryEntry } from '../model/Types';
import { preferencesUtil } from '../utils/PreferencesUtil';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:ReceiveHistoryService');
const HISTORY_KEY = 'receiveHistory';
const MAX_HISTORY = 30;

let history: Array<ReceiveHistoryEntry> = [];

export function initHistory(context: common.UIAbilityContext): void {
  logger.info('initHistory');
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
  logger.info('initHistory: loaded ' + history.length + ' entries');
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
  logger.info('addEntry: added ' + entry.fileName);
}

export function removeEntry(id: string): void {
  let updated: Array<ReceiveHistoryEntry> = [];
  for (let i = 0; i < history.length; i++) {
    if (history[i].id !== id) {
      updated.push(history[i]);
    }
  }
  history = updated;
  saveHistory();
  logger.info('removeEntry: removed id=' + id);
}

export function clearAll(): void {
  history = [];
  saveHistory();
  logger.info('clearAll: cleared all history');
}

function saveHistory(): void {
  preferencesUtil.setString(HISTORY_KEY, JSON.stringify(history));
}
