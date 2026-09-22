/**
 * LogLevels.ets — 日志级别 token 单一事实源
 *
 * 统一规范五级日志标识（英文小写 debug/info/warn/error/fatal），供 MTA 服务、
 * 调试 ViewModel、页面渲染与导出文本共用，避免级别魔法字符串在各处重复。
 *
 * 同时提供归一/校验/排序纯函数：
 * - normalizeLevel：把 Rust `log` crate 级别（trace 等）与未知值归一到规范 token
 * - isValidLevel：判断 token 是否为规范五级之一
 * - levelRank：级别排序（debug < info < warn < error < fatal），供抑制判断与筛选
 */

export class LogLevels {
  /** 诊断/状态变化细节 */
  static readonly DEBUG: string = 'debug';
  /** 关键流程节点 */
  static readonly INFO: string = 'info';
  /** 可恢复告警 */
  static readonly WARN: string = 'warn';
  /** 失败 */
  static readonly ERROR: string = 'error';
  /** 致命不可恢复 */
  static readonly FATAL: string = 'fatal';
}

/** 判断 token 是否为规范五级之一 */
export function isValidLevel(token: string): boolean {
  return token === LogLevels.DEBUG ||
    token === LogLevels.INFO ||
    token === LogLevels.WARN ||
    token === LogLevels.ERROR ||
    token === LogLevels.FATAL;
}

/**
 * 归一级别 token：
 * - 规范五级原样返回（大小写不敏感，统一转为小写）
 * - Rust `log` crate 的 `trace` 归一到 `debug`
 * - 其余未知/非法值兜底为 `info`
 */
export function normalizeLevel(token: string): string {
  let lower = token.toLowerCase();
  if (lower === 'trace') {
    return LogLevels.DEBUG;
  }
  if (isValidLevel(lower)) {
    return lower;
  }
  return LogLevels.INFO;
}

/**
 * 级别排序值：debug=0、info=1、warn=2、error=3、fatal=4。
 * 未知/非法值按 `info` 兜底（返回 1）。
 */
export function levelRank(token: string): number {
  switch (normalizeLevel(token)) {
    case LogLevels.DEBUG:
      return 0;
    case LogLevels.INFO:
      return 1;
    case LogLevels.WARN:
      return 2;
    case LogLevels.ERROR:
      return 3;
    case LogLevels.FATAL:
      return 4;
    default:
      return 1;
  }
}
