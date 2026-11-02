import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/**
 * 生成指定长度的密码学安全随机字节。
 *
 * 访问码与会话凭据不能依赖 `Math.random`；长度不符时抛错，由调用方按失败处理，
 * 不退回弱随机源。
 */
export function secureRandomBytes(length: number): Uint8Array {
  try {
    let result: cryptoFramework.DataBlob =
      cryptoFramework.createRandom().generateRandomSync(length);
    if (result.data.length !== length) {
      throw new Error('安全随机数长度不符');
    }
    return result.data;
  } catch (e) {
    // 统一为可识别的错误，调用方按失败处理，不退回弱随机源。
    throw new Error('安全随机数生成失败：' + String(e));
  }
}

/** 生成十六进制安全随机串（`byteLength` 字节对应 `2 * byteLength` 个字符）。 */
export function secureRandomHex(byteLength: number): string {
  let bytes: Uint8Array = secureRandomBytes(byteLength);
  let hex: string = '';
  for (let i = 0; i < bytes.length; i++) {
    let value: number = bytes[i];
    hex += (value < 16 ? '0' : '') + value.toString(16);
  }
  return hex;
}
