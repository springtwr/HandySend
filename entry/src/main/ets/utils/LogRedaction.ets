/** 日志中脱敏会话令牌：保留首尾各 4 位便于关联，其余隐藏。 */
export function redactSessionToken(token: string): string {
  if (token.length <= 12) {
    return '***';
  }
  return token.substring(0, 4) + '***' + token.substring(token.length - 4);
}
