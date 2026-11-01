import { LogEntry } from '../model/Types';
import { formatLocalIsoTimestamp } from './LogFileFormat';

/**
 * LogFormatter
 * 纯逻辑：把日志数组格式化为可复制的文本。无 UI 状态、无副作用。
 */
export function formatLogsAsText(entries: Array<LogEntry>): string {
  let parts: Array<string> = [];
  for (let i = 0; i < entries.length; i++) {
    let e = entries[i];
    let tagPrefix: string = e.tag.length > 0 ? '[' + e.tag + '] ' : '';
    parts.push(formatLocalIsoTimestamp(e.timestamp) + ' [' + e.level + '] ' + tagPrefix + e.message);
  }
  return parts.join('\n') + '\n';
}
