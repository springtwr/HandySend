/**
 * P2pVerifyModels.ets — MTA P2P 验证页数据类型与纯函数
 *
 * 本文件仅包含数据视图类型与可单测的纯函数（无系统 API 依赖），
 * 供 P2pVerifyService / MtaP2pVerifyViewModel / MtaP2pVerifyPage 共用。
 */

/** 建组后 getCurrentGroup() 返回信息的视图投影 */
export class P2pGroupInfoView {
  /** 本机是否为群主 */
  isGo: boolean = false;
  /** 群组名称（SSID） */
  groupName: string = '';
  /** 群组密钥 */
  passphrase: string = '';
  /** 群组 IP 地址（GO IP） */
  goIpAddress: string = '';
  /** 接口名称 */
  interfaceName: string = '';
  /** 群组频率 */
  frequency: number = 0;
  /** 已接入的客户端数量 */
  clientCount: number = 0;
  /** 群主设备地址（ownerInfo.deviceAddress，实测返回本机真实 p2p0 MAC） */
  ownerAddress: string = '';
}

/** 网络状态快照（多网络并行验证的对比数据） */
export class NetworkSnapshot {
  /** 本机 IPv4（点分十进制） */
  ipAddressText: string = '';
  /** 网关（点分十进制） */
  gatewayText: string = '';
  /** 掩码（点分十进制） */
  netmaskText: string = '';
  /** P2P 连接状态文本 */
  p2pConnectStateText: string = '';
  /** 本机是否群主 */
  isGroupOwner: boolean = false;
  /** 群组 IP 地址 */
  groupOwnerAddr: string = '';
  /** 快照时间（HH:mm:ss.SSS） */
  snapshotTime: string = '';
}

/** 验证日志条目 */
export class VerifyLogEntry {
  /** 时间戳（HH:mm:ss.SSS） */
  timeText: string = '';
  /** 操作名称 */
  action: string = '';
  /** 结果文本（成功返回值或错误信息） */
  resultText: string = '';
  /** 级别：'info' / 'error' */
  level: string = 'info';
  /** 人工备注（互通验证观察结论） */
  remark: string = '';
}

/** 页面 HTTP 服务状态 */
export class HttpServerState {
  /** 服务是否运行中 */
  running: boolean = false;
  /** 绑定地址 */
  bindAddress: string = '';
  /** 监听端口 */
  port: number = 0;
  /** 已接收请求数 */
  requestCount: number = 0;
}

// ── 时间格式化 ──

/** 将 Date 格式化为 HH:mm:ss.SSS（不足两位补零） */
export function formatTimeText(date: Date): string {
  let hh = pad2(date.getHours());
  let mm = pad2(date.getMinutes());
  let ss = pad2(date.getSeconds());
  let ms = pad3(date.getMilliseconds());
  return `${hh}:${mm}:${ss}.${ms}`;
}

function pad2(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}

function pad3(n: number): string {
  if (n < 10) {
    return '00' + n.toString();
  }
  if (n < 100) {
    return '0' + n.toString();
  }
  return n.toString();
}

// ── 纯函数（可 Local Test） ──

const DIRECT_PREFIX = 'DIRECT-';
const NAME_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

/**
 * 生成 MTA 约定的群组名：DIRECT- 前缀 + 8 位随机字符。
 * 对应 Android WiFi Direct 的 SSID 约定。
 */
export function generateRandomGroupName(): string {
  return DIRECT_PREFIX + randomString(8);
}

/** 生成 8 位随机密码（WiFi Direct 群组密钥要求） */
export function generateRandomPassphrase(): string {
  return randomString(8);
}

function randomString(length: number): string {
  let result = '';
  for (let i = 0; i < length; i++) {
    let idx = Math.floor(Math.random() * NAME_CHARS.length);
    result += NAME_CHARS.charAt(idx);
  }
  return result;
}

/**
 * 将 IpInfo 返回的十进制整数 IP 转换为点分十进制文本。
 * 例：3232235777 → "192.168.1.1"；0 → "0.0.0.0"。
 */
export function numberIpToText(n: number): string {
  let v = n >>> 0;
  let b0 = (v >> 24) & 0xff;
  let b1 = (v >> 16) & 0xff;
  let b2 = (v >> 8) & 0xff;
  let b3 = v & 0xff;
  return `${b0}.${b1}.${b2}.${b3}`;
}
