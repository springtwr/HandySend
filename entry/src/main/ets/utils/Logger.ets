/**
 * Logger.ets — 统一日志模块
 *
 * 封装 hilog 调用，同时输出到 hilog 系统日志和 addLog 应用内日志（诊断日志页）。
 * 按业务域（domain）细分，支持结构化上下文（LogContext）。
 *
 * Logger 零业务依赖（不 import PreferencesUtil / AppCore），所有外部状态通过
 * 运行时注入：registerAddLog 注入 addLog 回调。
 *
 * Debug 开关策略：
 * - Debug 构建默认开启 DEBUG，Release 构建默认仅 INFO 及以上
 * - 用户可在诊断日志设置中切换「记录详细日志」，选择会持久化
 * - 未保存过用户选择时，才使用构建默认值
 *
 * 使用方式：
 *   import { getLogger } from '../utils/Logger';
 *   import { LogDomains } from '../common/LogDomains';
 *   const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendRepository', '发送');
 *   logger.info('发送完成');
 *
 * 模块标签：getLogger 的第三个参数为模块级稳定短标签，由 Logger 统一前置为 `[标签] `。
 * 输出形态为 `[标签] [上下文] 内容`；未传标签时退化为 `[上下文] 内容`。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import BuildProfile from 'entry/BuildProfile';
import { LogLevels, normalizeLevel } from '../common/LogLevels';
import { LogContext, composeLogMessage } from '../common/LogFormat';

// ── addLog 回调（运行时注入，避免循环依赖） ──

type AddLogFn = (level: string, msg: string, tag: string) => void;
let addLogFn: AddLogFn | null = null;

export function registerAddLog(fn: AddLogFn): void {
  addLogFn = fn;
}

function emitLog(level: string, msg: string, tag: string): void {
  if (addLogFn !== null) {
    addLogFn(level, msg, tag);
  }
}

// ── Debug 状态监听（供文件日志通道联动 detail 文件） ──

type DebugStateListener = (enabled: boolean) => void;
let debugStateListener: DebugStateListener | null = null;

export function registerDebugStateListener(fn: DebugStateListener): void {
  debugStateListener = fn;
}

function notifyDebugState(enabled: boolean): void {
  if (debugStateListener !== null) {
    debugStateListener(enabled);
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
      emitLog('debug', composeLogMessage('', context, msg), this.label);
    }
  }

  info(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.INFO)) {
      return;
    }
    let fullMsg = composeLogMessage(this.label, context, msg);
    hilog.info(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('info', composeLogMessage('', context, msg), this.label);
  }

  warn(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.WARN)) {
      return;
    }
    let fullMsg = composeLogMessage(this.label, context, msg);
    hilog.warn(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('warn', composeLogMessage('', context, msg), this.label);
  }

  error(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.ERROR)) {
      return;
    }
    let fullMsg = composeLogMessage(this.label, context, msg);
    hilog.error(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('error', composeLogMessage('', context, msg), this.label);
  }

  fatal(msg: string, context?: LogContext): void {
    if (!hilog.isLoggable(this.domain, this.tag, hilog.LogLevel.FATAL)) {
      return;
    }
    let fullMsg = composeLogMessage(this.label, context, msg);
    hilog.fatal(this.domain, this.tag, '%{public}s', fullMsg);
    emitLog('fatal', composeLogMessage('', context, msg), this.label);
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
// 未保存用户选择时，Debug 构建默认开启，Release 构建默认关闭；页面负责持久化用户选择。

let debugEnabled: boolean = false;

export function isDebugEnabled(): boolean {
  return debugEnabled;
}

/**
 * 运行时切换 debug 开关（内存 + hilog 级别）；持久化由日志设置页负责。
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
  notifyDebugState(enabled);
}

// 初始化只生效一次：Ability 重建时不能把用户选择或构建默认值重复覆盖。
let loggerInitialized: boolean = false;

/**
 * 初始化 Logger：优先使用用户持久化选择，未保存过选择时使用构建默认值。
 * Debug 构建默认 DEBUG，Release 构建默认 INFO。
 */
export function initLogger(persistedDebug?: boolean): void {
  if (loggerInitialized) {
    return;
  }
  loggerInitialized = true;
  debugEnabled = persistedDebug ?? BuildProfile.DEBUG;
  if (debugEnabled) {
    hilog.setLogLevel(hilog.LogLevel.DEBUG, hilog.PreferStrategy.PREFER_OPEN_LOG);
  } else {
    hilog.setLogLevel(hilog.LogLevel.INFO, hilog.PreferStrategy.UNSET_LOGLEVEL);
  }
  notifyDebugState(debugEnabled);
}

// ── getLogger ──

export function getLogger(domain: number, tag: string, label?: string): LoggerInstance {
  return new LoggerInstance(domain, tag, label ?? '');
}
