// 网页分享的本次访问码：每次服务启动生成，仅用于裸地址手动输入。
// 扫码/链接仍以能力令牌免密进入；访问码随分享停止或服务重启失效，不持久化。

/** 访问码长度（6 位数字，便于口述与手输）。 */
export const WEB_ACCESS_CODE_LENGTH: number = 6;

/** 生成 6 位数字访问码（保留前导零）。 */
export function generateWebAccessCode(): string {
  let value: number = Math.floor(Math.random() * 1000000);
  let code: string = value.toString();
  while (code.length < WEB_ACCESS_CODE_LENGTH) {
    code = '0' + code;
  }
  return code;
}

/** 是否为合法的 6 位数字访问码。 */
export function isWebAccessCode(code: string): boolean {
  if (code.length !== WEB_ACCESS_CODE_LENGTH) {
    return false;
  }
  for (let i = 0; i < code.length; i++) {
    let value: number = code.charCodeAt(i);
    if (value < 0x30 || value > 0x39) {
      return false;
    }
  }
  return true;
}
