/**
 * Logger.ets — 统一日志模块
 *
 * 封装 hilog 调用，同时输出到 hilog 系统日志和 addLog 应用内日志（DebugPage）。
 * 按业务域（domain）细分，支持结构化上下文（LogContext）。
 *
 * Logger 零业务依赖（不 import PreferencesUtil / AppCore），所有外部状态通过
 * 运行时注入：registerAddLog 注入 addLog 回调。
 *
 * Debug 开关策略：
 * - Debug 版本：默认开启 DEBUG 级别，始终输出全量日志
 * - Release 版本：默认仅 INFO 及以上，可通过 setDebugEnabled 临时开启 DEBUG，
 *   重启应用后恢复默认（不持久化）
 *
 * 使用方式：
 *   import { getLogger } from '../utils/Logger';
 *   import { LogDomains } from '../common/LogDomains';
 *   const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendRepository');
 *   logger.info('Send completed');
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import BuildProfile from 'entry/BuildProfile';

// ── 结构化日志上下文 ──

export interface LogContext {
  sessionId?: string;
  fileId?: string;
  direction?: string;
  targetIp?: string;
  targetAlias?: string;
  protocol?: string;
}

// ── addLog 回调（运行时注入，避免循环依赖） ──

type AddLogFn = (level: string, msg: string) => void;
let addLogFn: AddLogFn | null = null;

export function registerAddLog(fn: AddLogFn): void {
  addLogFn = fn;
}

function emitLog(level: string, msg: string): void {
  if (addLogFn !== null) {
    addLogFn(level, msg);
  }
}

// ── LoggerInstance（类） ──

export class LoggerInstance {
  private domain: number;
  private tag: string;

  constructor(domain: number, tag: string) {
    this.domain = domain;
    this.tag = tag;
  }

  debug(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.DEBUG)) {
      return;
    }
    let fullMsg = buildContextPrefix(context) + msg;
    hilog.debug(this.domain, this.tag, '%{public}s', fullMsg);
    if (debugEnabled) {
      emitLog('debug', fullMsg);
    }
  }

  info(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.INFO)) {
      return;
    }
    let fullMsg = buildContextPrefix(context) + msg;
    hilog.info(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('info', fullMsg);
  }

  warn(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.WARN)) {
      return;
    }
    let fullMsg = buildContextPrefix(context) + msg;
    hilog.warn(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('warn', fullMsg);
  }

  error(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.ERROR)) {
      return;
    }
    let fullMsg = buildContextPrefix(context) + msg;
    hilog.error(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('error', fullMsg);
  }

  fatal(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.FATAL)) {
      return;
    }
    let fullMsg = buildContextPrefix(context) + msg;
    hilog.fatal(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('error', fullMsg);
  }
}

// ── Debug 开关 ──
// Debug 版默认开启，Release 版默认关闭。不持久化，重启恢复默认。

let debugEnabled: boolean = false;

export function isDebugEnabled(): boolean {
  return debugEnabled;
}

/**
 * 临时切换 debug 开关（仅内存 + hilog 级别，不持久化，重启恢复默认）。
 */
export function setDebugEnabled(enabled: boolean): void {
  debugEnabled = enabled;
  if (enabled) {
    hilog.setMinLogLevel(hilog.LogLevel.DEBUG);
  } else {
    hilog.setMinLogLevel(hilog.LogLevel.INFO);
  }
}

/**
 * 初始化 Logger：根据编译模式设定默认级别。
 * Debug 版 = DEBUG 全量输出，Release 版 = INFO 及以上。
 */
export function initLogger(): void {
  debugEnabled = BuildProfile.DEBUG;
  if (debugEnabled) {
    hilog.setMinLogLevel(hilog.LogLevel.DEBUG);
  } else {
    hilog.setMinLogLevel(hilog.LogLevel.INFO);
  }
}

// ── 上下文拼接 ──

function buildContextPrefix(context: LogContext | undefined): string {
  if (context === undefined) {
    return '';
  }
  let parts: Array<string> = [];
  if (context.sessionId !== undefined && context.sessionId.length > 0) {
    let short = context.sessionId.length > 8 ? context.sessionId.substring(0, 8) : context.sessionId;
    parts.push('sid=' + short);
  }
  if (context.fileId !== undefined && context.fileId.length > 0) {
    parts.push('fid=' + context.fileId);
  }
  if (context.direction !== undefined && context.direction.length > 0) {
    parts.push('dir=' + context.direction);
  }
  if (context.targetAlias !== undefined && context.targetAlias.length > 0) {
    parts.push('alias=' + context.targetAlias);
  }
  if (context.protocol !== undefined && context.protocol.length > 0) {
    parts.push('proto=' + context.protocol);
  }
  if (parts.length === 0) {
    return '';
  }
  return '[' + parts.join(' ') + '] ';
}

// ── getLogger ──

export function getLogger(domain: number, tag: string): LoggerInstance {
  return new LoggerInstance(domain, tag);
}
