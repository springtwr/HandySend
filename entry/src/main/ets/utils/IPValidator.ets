// IPv4 地址校验唯一实现（供弹窗 IP 输入校验与测试复用）。
// 四段 0-255 十进制数，以点分隔；不允许前导零（单独的 0 合法）。
export function isValidIpAddress(ip: string): boolean {
  if (ip.length === 0) {
    return false;
  }
  let parts: Array<string> = ip.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (let i = 0; i < 4; i++) {
    let part: string = parts[i];
    if (part.length === 0 || part.length > 3) {
      return false;
    }
    if (part.length > 1 && part.charAt(0) === '0') {
      return false;
    }
    let num: number = 0;
    for (let j = 0; j < part.length; j++) {
      let c: string = part.charAt(j);
      if (c < '0' || c > '9') {
        return false;
      }
      num = num * 10 + (c.charCodeAt(0) - '0'.charCodeAt(0));
    }
    if (num < 0 || num > 255) {
      return false;
    }
    // 最后一段不允许为 0（如 192.168.1.0 不是有效的主机地址）
    if (i === 3 && num === 0) {
      return false;
    }
  }
  return true;
}

// URL 格式校验（http/https 协议头 + 非空白字符）。
export function isUrl(text: string): boolean {
  return /^https?:\/\/\S+/.test(text.trim());
}
