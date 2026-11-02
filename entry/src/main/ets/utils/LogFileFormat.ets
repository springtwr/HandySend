/**
 * LogFileFormat.ets — 诊断日志文件的行格式与解析（纯逻辑，无文件 IO）
 *
 * 行格式：`<本地时区 ISO 时间> [<级别>] [<模块标签>] <正文>`
 * 会话标记：`# session-start ...` / `# session-end ...`；
 * 诊断标记：`# detail=on|off ...` / `# debug-suppressed ...`
 */

import { LogViewEntry } from '../model/Types';

export interface LogSessionHeader {
  sessionId: string
  part: number
  kind: string
  startedAt: number
  debug: boolean
  device: string
}

function pad2(value: number): string {
  return value < 10 ? '0' + value : '' + value;
}

/**
 * 日志文件时间使用带时区偏移的本地 ISO 时间，例如 2026-11-01T03:48:47.184+08:00。
 * 直接使用 toISOString() 会输出 UTC，在设备本地时间上看起来会差时区小时数。
 */
export function formatLocalIsoTimestamp(timestamp: number): string {
  let date: Date = new Date(timestamp);
  let offsetMinutes: number = -date.getTimezoneOffset();
  let sign: string = offsetMinutes >= 0 ? '+' : '-';
  let absOffset: number = Math.abs(offsetMinutes);
  let millis: number = date.getMilliseconds();
  let millisText: string = millis < 10 ? '00' + millis : (millis < 100 ? '0' + millis : '' + millis);
  return date.getFullYear() + '-' + pad2(date.getMonth() + 1) + '-' + pad2(date.getDate()) +
    'T' + pad2(date.getHours()) + ':' + pad2(date.getMinutes()) + ':' + pad2(date.getSeconds()) +
    '.' + millisText + sign + pad2(Math.floor(absOffset / 60)) + ':' + pad2(absOffset % 60);
}

/** 本地 24 小时制时钟时间（HH:mm:ss），供诊断日志页显示。 */
export function formatLocalClockTime(timestamp: number): string {
  let date: Date = new Date(timestamp);
  return pad2(date.getHours()) + ':' + pad2(date.getMinutes()) + ':' + pad2(date.getSeconds());
}

/** 计算 UTF-8 字节数（用于 file offset 与容量统计）。 */
export function utf8ByteLength(text: string): number {
  let bytes: number = 0;
  for (let i = 0; i < text.length; i++) {
    let code: number = text.charCodeAt(i);
    if (code < 0x80) {
      bytes += 1;
    } else if (code < 0x800) {
      bytes += 2;
    } else if (code >= 0xD800 && code <= 0xDBFF) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

export function formatLogLine(level: string, tag: string, message: string, timestamp: number): string {
  let tagText: string = tag.length > 0 ? tag : '-';
  let singleLine: string = message.split('\n').join('\\n').split('\r').join('\\r');
  return formatLocalIsoTimestamp(timestamp) + ' [' + level + '] [' + tagText + '] ' + singleLine + '\n';
}

export function formatSessionStart(header: LogSessionHeader): string {
  let debugText: string = header.debug ? 'true' : 'false';
  return '# session-start session=' + header.sessionId + ' part=' + header.part +
    ' kind=' + header.kind + ' started=' + formatLocalIsoTimestamp(header.startedAt) +
    ' debug=' + debugText + ' device=' + header.device.split('\n').join(' ') + '\n';
}

export function formatSessionEnd(timestamp: number, clean: boolean): string {
  return '# session-end ' + formatLocalIsoTimestamp(timestamp) +
    ' clean=' + (clean ? 'true' : 'false') + '\n';
}

export function isMarkerLine(line: string): boolean {
  return line.startsWith('#');
}

/** 解析一行日志；模块标记行或格式不符时返回 undefined。 */
export function parseLogLine(line: string, offset: number): LogViewEntry | undefined {
  if (line.length === 0 || line.startsWith('#')) {
    return undefined;
  }
  let firstSpace: number = line.indexOf(' ');
  if (firstSpace <= 0) {
    return undefined;
  }
  let levelStart: number = line.indexOf('[', firstSpace + 1);
  let levelEnd: number = levelStart >= 0 ? line.indexOf(']', levelStart + 1) : -1;
  let tagStart: number = levelEnd >= 0 ? line.indexOf('[', levelEnd + 1) : -1;
  let tagEnd: number = tagStart >= 0 ? line.indexOf(']', tagStart + 1) : -1;
  if (levelStart < 0 || levelEnd < 0 || tagStart < 0 || tagEnd < 0) {
    return undefined;
  }
  let timestamp: number = Date.parse(line.substring(0, firstSpace));
  if (Number.isNaN(timestamp)) {
    timestamp = 0;
  }
  let tag: string = line.substring(tagStart + 1, tagEnd);
  let message: string = tagEnd + 2 <= line.length ? line.substring(tagEnd + 2) : '';
  return {
    timestamp: timestamp,
    level: line.substring(levelStart + 1, levelEnd),
    tag: tag === '-' ? '' : tag,
    message: message,
    offset: offset
  };
}


