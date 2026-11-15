// 发送文件夹的相对路径构造：复用接收侧的逐段解析/净化规则，
// 但输入来自本机目录树，不信任外部请求。
import {
  ParsedRelativePath,
  ReceivedPathError,
  ReceivedPathParseResult,
  parseReceivedPath,
  relativePathOf,
  sanitizeReceivedPath
} from './ReceivedPath';

/** 发送相对路径上限（字符数）：避免异常深层目录生成超长 JSON 名字。 */
export const MAX_SEND_RELATIVE_PATH_LENGTH: number = 1024;

export class SendPathResult {
  relativeName: string = ''
  ok: boolean = false
  error: ReceivedPathError = ReceivedPathError.none

  constructor(relativeName: string, ok: boolean, error: ReceivedPathError) {
    this.relativeName = relativeName;
    this.ok = ok;
    this.error = error;
  }
}

/**
 * 构造 `<根目录名>/<相对路径>` 并逐段净化。
 * relative 可带首 `/`（listFile 的递归结果），空段会被丢弃。
 */
export function buildSendRelativePath(rootName: string, relative: string,
  sanitize: (name: string) => string): SendPathResult {
  let normalized: string = relative.startsWith('/') ? relative.substring(1) : relative;
  if (rootName.length === 0 || normalized.length === 0) {
    return new SendPathResult('', false, ReceivedPathError.empty);
  }
  let parsed: ReceivedPathParseResult = parseReceivedPath(rootName + '/' + normalized);
  if (parsed.path === undefined) {
    return new SendPathResult('', false, parsed.error);
  }
  let sanitized: ReceivedPathParseResult = sanitizeReceivedPath(parsed.path, sanitize);
  if (sanitized.path === undefined) {
    return new SendPathResult('', false, sanitized.error);
  }
  let path: ParsedRelativePath = sanitized.path;
  let name: string = relativePathOf(path);
  if (name.length === 0 || name.length > MAX_SEND_RELATIVE_PATH_LENGTH) {
    return new SendPathResult('', false, ReceivedPathError.missingName);
  }
  return new SendPathResult(name, true, ReceivedPathError.none);
}
