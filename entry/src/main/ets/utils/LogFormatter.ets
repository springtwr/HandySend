import { LogEntry } from '../model/Types';

/**
 * LogFormatter
 * 纯逻辑：把日志数组格式化为可复制的文本。无 UI 状态、无副作用。
 */
export function formatLogsAsText(entries: Array<LogEntry>): string {
  let parts: Array<string> = [];
  let d = new Date(0);
  for (let i = 0; i < entries.length; i++) {
    let e = entries[i];
    d.setTime(e.timestamp);
    parts.push(d.toISOString() + ' [' + e.level + '] ' + e.message);
  }
  return parts.join('\n') + '\n';
}
