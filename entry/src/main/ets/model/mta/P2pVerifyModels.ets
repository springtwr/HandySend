/**
 * P2pVerifyModels.ets — MTA P2P 验证页数据类型与纯函数
 *
 * 本文件仅包含数据视图类型与可单测的纯函数（无系统 API 依赖），
 * 供 P2pVerifyService / MtaP2pVerifyViewModel / MtaP2pVerifyPage 共用。
 */

import { LogLevels } from '../../common/LogLevels';

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
  /** 已接入客户端设备地址列表（无客户端/地址缺失时为空，A 组实验对端标识采集来源） */
  clientDeviceAddresses: Array<string> = [];
}

/** p2pConnect 实验配置视图（六字段，供实验分区编辑与场景预设填充） */
export class P2pConnectConfigView {
  /** 对端 P2P 设备地址（人工采集，MAC 格式 XX:XX:XX:XX:XX:XX） */
  deviceAddress: string = '';
  /** 设备地址类型：0=RANDOM / 1=REAL（对应 DeviceAddressType） */
  deviceAddressType: number = 1;
  /** 网络 ID：-1 临时组 / -2 永久组（实验变量，消费语义待真机判定） */
  netId: number = -2;
  /** 组密码（MTA 凭据注入场景填写） */
  passphrase: string = '';
  /** 组名/SSID（MTA 凭据注入场景填写） */
  groupName: string = '';
  /** 频段：0 AUTO / 1 2.4G / 2 5G（对应 GroupOwnerBand） */
  goBand: number = 0;
}

/** 系统网络列表条目（getAllNets + getConnectionProperties 快照） */
export class NetworkListEntry {
  /** 网络标识 */
  netId: number = 0;
  /** 接口名称（判断是否含 p2p） */
  interfaceName: string = '';
  /** 链路地址列表（判断是否在 GO 网段） */
  addresses: Array<string> = [];
  /** 是否疑似 P2P 网络（接口名含 p2p 或地址与 GO 同网段） */
  isLikelyP2p: boolean = false;
}

/** TCP 可达性探测结果 */
export class TcpProbeResult {
  /** 目标 IP:端口 */
  targetText: string = '';
  /** 是否连通 */
  ok: boolean = false;
  /** 耗时（毫秒） */
  costMs: number = 0;
  /** 结果说明（成功/失败原因） */
  detail: string = '';
}

/** P2P 设备发现条目（p2pPeerDeviceChange 事件映射，可填入地址或直接发起连接） */
export class P2pDiscoveredDeviceView {
  /** 对端设备名（空则显示地址） */
  deviceName: string = '';
  /** 对端 P2P 设备地址（隐私化随机 MAC 原样展示） */
  deviceAddress: string = '';
  /** 设备地址类型（系统返回值：0=RANDOM / 1=REAL），连接时原样使用 */
  deviceAddressType: number = 1;
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
  /** 级别：规范五级 token（debug/info/warn/error/fatal） */
  level: string = LogLevels.INFO;
  /** 人工备注（互通验证观察结论） */
  remark: string = '';
}

/** 页面 HTTP 服务状态 */
@ObservedV2
export class HttpServerState {
  /** 服务是否运行中 */
  running: boolean = false;
  /** 绑定地址 */
  bindAddress: string = '';
  /** 监听端口 */
  port: number = 0;
  /** 已接收请求数（服务运行期间异步递增，需 @Trace 才能驱动 UI 刷新） */
  @Trace requestCount: number = 0;
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

// ── p2pConnect 实验预设 ──

/** 预设类型：标准协商（netId=-1，疑点 1 GO 协商流程对照） */
export const PRESET_STANDARD = 0;
/** 预设类型：永久组（netId=-2，对齐官方示例写法） */
export const PRESET_PERSISTENT = 1;
/** 预设类型：MTA 凭据注入（netId=-2 + 用户输入凭据，疑点 2 验证系统是否消费凭据字段） */
export const PRESET_MTA_CREDENTIAL = 2;

/**
 * 生成场景预设配置。
 * 预设只填充非设备地址字段（地址为每次实验人工采集，不应被预设覆盖），
 * mta-credential 预设将调用方传入的 ssid/psk 填入 groupName/passphrase。
 */
export function buildPresetConfig(kind: number, ssid: string, psk: string): P2pConnectConfigView {
  let config = new P2pConnectConfigView();
  // P2pInfo.mac 为发送端真实 p2p0 MAC（实测 U/L=0），地址类型固定取真实地址
  config.deviceAddressType = 1;
  config.goBand = 0;
  if (kind === PRESET_STANDARD) {
    config.netId = -1;
  } else {
    config.netId = -2;
    if (kind === PRESET_MTA_CREDENTIAL) {
      config.groupName = ssid;
      config.passphrase = psk;
    }
  }
  return config;
}

/** 预设类型文本（日志展示用） */
export function presetKindText(kind: number): string {
  switch (kind) {
    case PRESET_STANDARD:
      return '标准协商';
    case PRESET_PERSISTENT:
      return '永久组';
    case PRESET_MTA_CREDENTIAL:
      return 'MTA 凭据注入';
    default:
      return '未知预设';
  }
}

/** 校验 MAC 地址格式：XX:XX:XX:XX:XX:XX（不区分大小写十六进制） */
export function isMacAddressText(text: string): boolean {
  if (text.length !== 17) {
    return false;
  }
  for (let i = 0; i < 17; i++) {
    let ch = text.charAt(i);
    if (i % 3 === 2) {
      if (ch !== ':') {
        return false;
      }
    } else if (!isHexChar(ch)) {
      return false;
    }
  }
  return true;
}

function isHexChar(ch: string): boolean {
  return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
}
