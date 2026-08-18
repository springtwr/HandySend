import { LogEntry } from '../model/Types';

/**
 * LogFormatter
 * 纯逻辑：把日志数组格式化为可复制的文本。无 UI 状态、无副作用。
 */
export function formatLogsAsText(entries: Array<LogEntry>): string {
  let text = '';
  for (let i = 0; i < entries.length; i++) {
    let e = entries[i];
    text = text + new Date(e.timestamp).toISOString() + ' [' + e.level + '] ' + e.message + '\n';
  }
  return text;
}
