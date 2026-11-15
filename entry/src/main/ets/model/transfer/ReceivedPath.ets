/**
 * ReceivedPath.ets — 接收相对路径的解析与净化
 *
 * LocalSend 的 fileName 可以携带目录分量（如 `Photos/2024/a.jpg`）。
 * 本模块只做纯字符串处理：
 * - 解析、识别路径穿越/绝对路径/应用临时区保留名；
 * - 逐段调用注入的 sanitize（生产为 nativeSanitizeFileName）；
 * - 不触碰文件系统，不依赖 UI/原生状态，便于设备端用例直接覆盖。
 */

import { LEGACY_TEMP_DIR_NAMES, TEMP_DIR_NAME } from './TransferTempPaths';

/** 解析失败原因。 */
export enum ReceivedPathError {
  none = 'none',
  empty = 'empty',
  absolute = 'absolute',
  traversal = 'traversal',
  reserved = 'reserved',
  missingName = 'missingName'
}

/** 解析后的相对路径：目录段 + 文件名。 */
export class ParsedRelativePath {
  dirs: Array<string> = []
  name: string = ''

  constructor(dirs: Array<string>, name: string) {
    this.dirs = dirs;
    this.name = name;
  }
}

/** 解析/净化结果：path 为空时 error 给出原因。 */
export class ReceivedPathParseResult {
  path: ParsedRelativePath | undefined = undefined
  error: ReceivedPathError = ReceivedPathError.none

  constructor(path: ParsedRelativePath | undefined, error: ReceivedPathError) {
    this.path = path;
    this.error = error;
  }
}

/** 应用临时区目录名：接收路径不能使用，避免与临时区/启动清扫重叠。 */
export function isReservedReceivedComponent(name: string): boolean {
  if (name === TEMP_DIR_NAME) {
    return true;
  }
  for (let i = 0; i < LEGACY_TEMP_DIR_NAMES.length; i++) {
    if (name === LEGACY_TEMP_DIR_NAMES[i]) {
      return true;
    }
  }
  return false;
}

/** 是否为 Windows 盘符绝对路径（如 C:/x、C:\x）。 */
function isDriveAbsolutePath(raw: string): boolean {
  if (raw.length < 3) {
    return false;
  }
  let first: string = raw.charAt(0);
  let isLetter: boolean = (first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z');
  let third: string = raw.charAt(2);
  return isLetter && raw.charAt(1) === ':' && (third === '/' || third === '\\');
}

/**
 * 解析接收到的文件名。
 *
 * 规则：
 * - 只按 `/` 分段；`\` 在 OHOS 是合法文件名字符（上游 Windows 发送端已转 `/`）；
 * - 丢弃空段与 `.`；`..`、首字符 `/`、盘符路径、UNC 前缀直接判为非法；
 * - 最后一段为空或 `.` 表示没有文件名，判为非法；
 * - 任一段为应用临时区名（`.handysend-temp` 等）判为保留名。
 */
export function parseReceivedPath(raw: string): ReceivedPathParseResult {
  if (raw.length === 0) {
    return new ReceivedPathParseResult(undefined, ReceivedPathError.empty);
  }
  if (raw.charAt(0) === '/') {
    return new ReceivedPathParseResult(undefined, ReceivedPathError.absolute);
  }
  if (raw.startsWith('\\\\')) {
    return new ReceivedPathParseResult(undefined, ReceivedPathError.absolute);
  }
  if (isDriveAbsolutePath(raw)) {
    return new ReceivedPathParseResult(undefined, ReceivedPathError.absolute);
  }
  let parts: Array<string> = raw.split('/');
  let last: string = parts[parts.length - 1];
  // 以 `/` 或 `/.` 结尾代表没有文件名；不要把它误当成同名文件。
  if (last.length === 0 || last === '.') {
    return new ReceivedPathParseResult(undefined, ReceivedPathError.missingName);
  }
  if (last === '..') {
    return new ReceivedPathParseResult(undefined, ReceivedPathError.traversal);
  }
  if (isReservedReceivedComponent(last)) {
    return new ReceivedPathParseResult(undefined, ReceivedPathError.reserved);
  }
  let dirs: Array<string> = [];
  for (let i = 0; i < parts.length - 1; i++) {
    let part: string = parts[i];
    if (part.length === 0 || part === '.') {
      continue;
    }
    if (part === '..') {
      return new ReceivedPathParseResult(undefined, ReceivedPathError.traversal);
    }
    if (isReservedReceivedComponent(part)) {
      return new ReceivedPathParseResult(undefined, ReceivedPathError.reserved);
    }
    dirs.push(part);
  }
  return new ReceivedPathParseResult(new ParsedRelativePath(dirs, last), ReceivedPathError.none);
}

/**
 * 逐段净化（目录段与文件名分别处理）。
 * 净化后再检查一次保留名：避免控制字符替换等规则把某段变成保留名。
 */
export function sanitizeReceivedPath(path: ParsedRelativePath,
  sanitize: (name: string) => string): ReceivedPathParseResult {
  let dirs: Array<string> = [];
  for (let i = 0; i < path.dirs.length; i++) {
    let sanitized: string = sanitize(path.dirs[i]);
    if (isReservedReceivedComponent(sanitized)) {
      return new ReceivedPathParseResult(undefined, ReceivedPathError.reserved);
    }
    dirs.push(sanitized);
  }
  let name: string = sanitize(path.name);
  if (isReservedReceivedComponent(name)) {
    return new ReceivedPathParseResult(undefined, ReceivedPathError.reserved);
  }
  return new ReceivedPathParseResult(new ParsedRelativePath(dirs, name), ReceivedPathError.none);
}

/** 相对路径字符串（目录 + 文件名）。 */
export function relativePathOf(path: ParsedRelativePath): string {
  let parts: Array<string> = path.dirs.slice();
  parts.push(path.name);
  return parts.join('/');
}
