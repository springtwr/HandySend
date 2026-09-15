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
 *   const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendRepository', '发送');
 *   logger.info('Send completed');
 *
 * 模块标签：getLogger 的第三个参数为模块级稳定短标签，由 Logger 统一前置为 `[标签] `。
 * 输出形态为 `[标签] [上下文] 内容`；未传标签时退化为 `[上下文] 内容`。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import BuildProfile from 'entry/BuildProfile';
import { LogLevels, normalizeLevel } from '../common/LogLevels';
import { LogContext, composeLogMessage } from '../common/LogFormat';

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

class LoggerInstance {
  private domain: number;
  private tag: string;
  private label: string;

  constructor(domain: number, tag: string, label: string) {
    this.domain = domain;
    this.tag = tag;
    this.label = label;
  }

  debug(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.DEBUG)) {
      return;
    }
    let fullMsg = composeLogMessage(this.label, context, msg);
    hilog.debug(this.domain, this.tag, '%{public}s', fullMsg);
    if (debugEnabled) {
      emitLog('debug', fullMsg);
    }
  }

  info(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.INFO)) {
      return;
    }
    let fullMsg = composeLogMessage(this.label, context, msg);
    hilog.info(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('info', fullMsg);
  }

  warn(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.WARN)) {
      return;
    }
    let fullMsg = composeLogMessage(this.label, context, msg);
    hilog.warn(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('warn', fullMsg);
  }

  error(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.ERROR)) {
      return;
    }
    let fullMsg = composeLogMessage(this.label, context, msg);
    hilog.error(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('error', fullMsg);
  }

  fatal(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.FATAL)) {
      return;
    }
    let fullMsg = composeLogMessage(this.label, context, msg);
    hilog.fatal(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('error', fullMsg);
  }

  /**
   * 通用分级出口：按规范级别 token 分发到对应 hilog 级别。
   * 未知/非法 token 归一并兜底为 info，保证调用方无需自行判空。
   */
  log(level: string, msg: string, context?: LogContext): void {
    switch (normalizeLevel(level)) {
      case LogLevels.DEBUG:
        this.debug(msg, context);
        break;
      case LogLevels.WARN:
        this.warn(msg, context);
        break;
      case LogLevels.ERROR:
        this.error(msg, context);
        break;
      case LogLevels.FATAL:
        this.fatal(msg, context);
        break;
      default:
        this.info(msg, context);
        break;
    }
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
 *
 * 使用 API 21 的 setLogLevel + PREFER_OPEN_LOG 策略：
 * - 开启时 PREFER_OPEN_LOG 取 min(DEBUG, 系统级别)，Release 下也能降级到 DEBUG
 * - 关闭时 UNSET_LOGLEVEL 恢复系统控制级别
 *
 * 注：setMinLogLevel 无法将级别降到系统全局级别之下，是 Release 模式下
 * 调试日志开关不生效的根因。
 */
export function setDebugEnabled(enabled: boolean): void {
  debugEnabled = enabled;
  if (enabled) {
    hilog.setLogLevel(hilog.LogLevel.DEBUG, hilog.PreferStrategy.PREFER_OPEN_LOG);
  } else {
    hilog.setLogLevel(hilog.LogLevel.INFO, hilog.PreferStrategy.UNSET_LOGLEVEL);
  }
}

/**
 * 初始化 Logger：根据编译模式设定默认级别。
 * Debug 版 = DEBUG 全量输出，Release 版 = INFO 及以上。
 */
export function initLogger(): void {
  debugEnabled = BuildProfile.DEBUG;
  if (debugEnabled) {
    hilog.setLogLevel(hilog.LogLevel.DEBUG, hilog.PreferStrategy.PREFER_OPEN_LOG);
  } else {
    hilog.setLogLevel(hilog.LogLevel.INFO, hilog.PreferStrategy.UNSET_LOGLEVEL);
  }
}

// ── getLogger ──

export function getLogger(domain: number, tag: string, label?: string): LoggerInstance {
  return new LoggerInstance(domain, tag, label ?? '');
}
