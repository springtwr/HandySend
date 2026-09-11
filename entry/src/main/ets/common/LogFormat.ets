/**
 * LogFormat.ets — 日志消息格式拼接（纯逻辑，零系统依赖）
 *
 * 统一日志消息形态为 `[模块标签] [结构化上下文] 内容`：
 * - 模块标签：模块/子系统级稳定短标签，由 getLogger 传入，集中前置；
 * - 结构化上下文：由 LogContext 生成 `[字段=值 …]` 前缀，用于串联会话日志。
 *
 * 抽离为无 Kit 依赖的纯模块，便于本地单测直接覆盖拼接顺序与缺省兼容。
 */

// ── 结构化日志上下文 ──

export interface LogContext {
  sessionId?: string;
  fileId?: string;
  direction?: string;
  targetIp?: string;
  targetAlias?: string;
  protocol?: string;
}

/** 生成上下文前缀 `[sid=.. dir=.. …] `；无有效字段时返回空串 */
export function buildContextPrefix(context: LogContext | undefined): string {
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

/**
 * 组装最终日志消息：`[模块标签] [上下文] 内容`。
 * 模块标签缺省（空字符串）时省略；上下文缺省时空串；均为纯字符串拼接。
 */
export function composeLogMessage(label: string, context: LogContext | undefined, msg: string): string {
  let labelPrefix = label.length > 0 ? '[' + label + '] ' : '';
  return labelPrefix + buildContextPrefix(context) + msg;
}
