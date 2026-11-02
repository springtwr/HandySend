// 网页分享的本次访问码：每次服务启动生成，仅用于裸地址手动输入。
// 扫码/链接仍以能力令牌免密进入；访问码随分享停止或服务重启失效，不持久化。

import { secureRandomBytes } from './SecureRandom';

/** 访问码长度（6 位数字，便于口述与手输）。 */
export const WEB_ACCESS_CODE_LENGTH: number = 6;

/** 生成 6 位数字访问码（保留前导零）。 */
export function generateWebAccessCode(): string {
  // 访问码是网页访问凭据，使用密码学安全随机数。24 位随机值先拒绝采样到
  // 16,000,000（1,000,000 的整数倍），再取模，保证 6 位数字均匀分布。
  let value: number = 0;
  do {
    let bytes: Uint8Array = secureRandomBytes(3);
    value = bytes[0] * 65536 + bytes[1] * 256 + bytes[2];
  } while (value >= 16000000);
  let code: string = (value % 1000000).toString();
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
