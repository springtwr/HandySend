import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReceiveHistoryEntry } from '../model/Types';
import { preferencesUtil } from '../utils/PreferencesUtil';

const TAG = 'LocalSend:ReceiveHistoryService';
const DOMAIN = 0x0001;
const HISTORY_KEY = 'receiveHistory';
const MAX_HISTORY = 30;

let history: Array<ReceiveHistoryEntry> = [];

export function initHistory(context: common.UIAbilityContext): void {
  hilog.info(DOMAIN, TAG, 'initHistory');
  // Ensure preferences is initialized before reading/writing
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
  hilog.info(DOMAIN, TAG, 'initHistory: loaded %{public}d entries', history.length);
}

export function getHistory(): Array<ReceiveHistoryEntry> {
  return history;
}

export function addEntry(entry: ReceiveHistoryEntry): void {
  history.push(entry);
  // FIFO: remove oldest if over limit
  while (history.length > MAX_HISTORY) {
    history.shift();
  }
  saveHistory();
  hilog.info(DOMAIN, TAG, 'addEntry: added %{public}s', entry.fileName);
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
  hilog.info(DOMAIN, TAG, 'removeEntry: removed id=%{public}s', id);
}

export function clearAll(): void {
  history = [];
  saveHistory();
  hilog.info(DOMAIN, TAG, 'clearAll: cleared all history');
}

function saveHistory(): void {
  preferencesUtil.setString(HISTORY_KEY, JSON.stringify(history));
}
