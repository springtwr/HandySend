/** 日志中脱敏会话令牌：保留首尾各 4 位便于关联，其余隐藏。 */
export function redactSessionToken(token: string): string {
  if (token.length <= 12) {
    return '***';
  }
  return token.substring(0, 4) + '***' + token.substring(token.length - 4);
}

/** 日志中打码口令类敏感文本：保留首尾各 2 位，长度不足 5 时全部打码。 */
export function maskSecret(text: string): string {
  if (text.length === 0) {
    return '';
  }
  if (text.length <= 4) {
    return '*'.repeat(text.length);
  }
  return text.substring(0, 2) + '*'.repeat(text.length - 4) + text.substring(text.length - 2);
}
