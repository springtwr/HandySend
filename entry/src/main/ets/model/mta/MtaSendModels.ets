/**
 * MtaSendModels.ets — MTA 发送端数据类型与纯函数
 *
 * 本文件仅包含发送端数据视图类型、事件回调集合与可单测的纯函数（无系统 API 依赖），
 * 供 MtaBleClient / MtaP2pGroup / MtaSendService / MtaSendViewModel / MtaSendPage 共用。
 * 协议类型（DeviceInfoJson/P2pInfoJson/WsMessage 等）复用 MtaReceiveModels，避免双份定义。
 */

import { DeviceInfoJson, ReceiverLogEntry } from './MtaReceiveModels';
import { MtaConstants } from '../../service/mta/MtaConstants';

// ── 发送阶段状态机 ──

/** 发送端阶段（扫描 → 连接 → 建组 → 启动服务器 → 写凭据 → WS 协商 → 传输 → 终态） */
export enum MtaSenderStage {
  /** 未启动 */
  IDLE = 'idle',
  /** 扫描中 */
  SCANNING = 'scanning',
  /** 连接对端 GATT Server */
  GATT_CONNECTING = 'gatt_connecting',
  /** 创建 WiFi Direct 群组 */
  GROUP_CREATING = 'group_creating',
  /** 启动本机 TLS 服务器 */
  SERVER_STARTING = 'server_starting',
  /** 已写回 P2pInfo */
  P2P_INFO_WRITTEN = 'p2p_info_written',
  /** 等待对端建立 WS 连接 */
  WAITING_WS = 'waiting_ws',
  /** 版本协商完成 */
  NEGOTIATED = 'negotiated',
  /** 已发送 sendRequest */
  REQUEST_SENT = 'request_sent',
  /** 传输中 */
  TRANSFERRING = 'transferring',
  /** 本次发送完成 */
  COMPLETED = 'completed',
  /** 本次发送失败（含对端拒绝） */
  FAILED = 'failed',
  /** 用户取消 */
  CANCELLED = 'cancelled'
}

/** 阶段枚举 → 中文展示文本 */
export function mtaSenderStageText(stage: MtaSenderStage): string {
  switch (stage) {
    case MtaSenderStage.IDLE:
      return '未启动';
    case MtaSenderStage.SCANNING:
      return '扫描中';
    case MtaSenderStage.GATT_CONNECTING:
      return '连接中';
    case MtaSenderStage.GROUP_CREATING:
      return '建组中';
    case MtaSenderStage.SERVER_STARTING:
      return '启动服务器';
    case MtaSenderStage.P2P_INFO_WRITTEN:
      return '已写凭据';
    case MtaSenderStage.WAITING_WS:
      return '等待连接';
    case MtaSenderStage.NEGOTIATED:
      return '已协商';
    case MtaSenderStage.REQUEST_SENT:
      return '已请求';
    case MtaSenderStage.TRANSFERRING:
      return '传输中';
    case MtaSenderStage.COMPLETED:
      return '发送完成';
    case MtaSenderStage.FAILED:
      return '失败';
    case MtaSenderStage.CANCELLED:
      return '已取消';
    default:
      return '未知';
  }
}

// ── 发送端数据视图 ──

/** 扫描发现的 MTA 接收端设备 */
export class MtaDiscoveredDevice {
  /** BLE 设备标识（GATT 连接用） */
  bleAddress: string = '';
  /** 设备名 */
  deviceName: string = '';
  /** 2 字节发送者 ID 十六进制 */
  senderIdHex: string = '';
  /** 品牌名 */
  brandName: string = '未知';
  /** 品牌 ID（主广播 serviceData UUID 中的品牌字节，-1 表示未知） */
  brandId: number = -1;
  /** 是否支持 5GHz */
  is5Ghz: boolean = false;
  /** 信号强度（dBm） */
  rssi: number = 0;
  /** 最近发现时间（HH:mm:ss.SSS） */
  lastSeenText: string = '';
}

/** 待发送文件 */
export class MtaSendFile {
  /** 选择器返回的原始 URI */
  uri: string = '';
  /** 显示文件名 */
  displayName: string = '';
  /** 文件大小（字节） */
  sizeBytes: number = 0;
  /** 暂存到 cacheDir 后的沙箱路径（传给 Rust） */
  stagedPath: string = '';
  /** ZIP 条目名（"{序号}/{显示文件名}"） */
  entryName: string = '';
}

/** 发送进度 */
export class MtaSendProgress {
  /** 已发送字节 */
  sentBytes: number = 0;
  /** 总字节 */
  totalBytes: number = 0;
  /** 百分比（0-100） */
  percent: number = 0;
}

/** 加密后的 P2P 凭据（Base64 字段） */
export class EncryptedCredentials {
  /** AES-256-CTR 加密后的 SSID（Base64） */
  ssid: string = '';
  /** AES-256-CTR 加密后的 PSK（Base64） */
  psk: string = '';
  /** AES-256-CTR 加密后的 MAC（Base64） */
  mac: string = '';
}

/** WiFi Direct 群组信息视图 */
export class MtaGroupInfo {
  /** 群组 SSID */
  ssid: string = '';
  /** 群组口令 */
  psk: string = '';
  /** 本机 GO 网关地址 */
  goIp: string = '';
  /** 群主设备地址（本机 p2p0 MAC） */
  ownerMac: string = '';
  /** 已接入客户端数 */
  clientCount: number = 0;
  /** 频段 */
  frequency: number = 0;
}

/** 一次发送的完整会话上下文 */
export class MtaSendSession {
  /** 目标设备 */
  target: MtaDiscoveredDevice | undefined = undefined;
  /** 选中文件清单 */
  files: Array<MtaSendFile> = [];
  /** 任务 ID（同时用作下载 query 参数） */
  taskId: string = '';
  /** 发送者 ID 十六进制 */
  senderIdHex: string = '';
  /** 发送者显示名 */
  senderName: string = 'HandySend';
  /** WiFi Direct 群组 SSID */
  groupSsid: string = '';
  /** WiFi Direct 群组口令 */
  groupPsk: string = '';
  /** WiFi Direct 群组频点（MHz，写入 P2pInfo.freq） */
  groupFrequency: number = 0;
  /** 对端可访问的 GO 网关地址 */
  goIp: string = '';
  /** 本机 p2p0 MAC */
  localMac: string = '';
  /** 本机 TLS 服务器端口 */
  port: number = 0;
  /** 本机 ECDH 公钥（Base64 SPKI DER） */
  localPublicKey: string = '';
  /** 预打包 ZIP 路径 */
  zipPath: string = '';
  /** 已发送字节 */
  sentBytes: number = 0;
  /** 总字节 */
  totalBytes: number = 0;
  /** 对端 DeviceInfo（含公钥） */
  remoteDeviceInfo: DeviceInfoJson | undefined = undefined;
}

/** 发送端完整状态（服务持有，向 VM 推送快照） */
export class SenderState {
  /** 当前阶段 */
  stage: MtaSenderStage = MtaSenderStage.IDLE;
  /** 是否扫描中 */
  scanning: boolean = false;
  /** 已发现设备列表 */
  devices: Array<MtaDiscoveredDevice> = [];
  /** 已选中设备 */
  selected: MtaDiscoveredDevice | undefined = undefined;
  /** 当前发送会话 */
  session: MtaSendSession | undefined = undefined;
  /** 发送进度 */
  progress: MtaSendProgress = new MtaSendProgress();
  /** 当前文件显示名 */
  currentFileName: string = '';
  /** 最近一次错误原因 */
  lastError: string = '';
  /** Rust 服务器是否运行 */
  serverRunning: boolean = false;
  /** 是否已建组 */
  groupCreated: boolean = false;

  /** 复制当前状态为独立快照（V2 @Trace 需整体替换才触发刷新） */
  snapshot(): SenderState {
    let copy = new SenderState();
    copy.stage = this.stage;
    copy.scanning = this.scanning;
    copy.devices = this.devices.slice();
    copy.selected = this.selected;
    copy.session = this.session;
    copy.progress = this.progress;
    copy.currentFileName = this.currentFileName;
    copy.lastError = this.lastError;
    copy.serverRunning = this.serverRunning;
    copy.groupCreated = this.groupCreated;
    return copy;
  }
}

/** sendRequest 消息 payload */
export class SendRequestPayload {
  /** 任务 ID */
  taskId: string = '';
  /** 发送方 ID */
  senderId: string = '';
  /** 发送方名称 */
  senderName: string = '';
  /** 主文件名（展示用） */
  fileName: string = '';
  /** 文件类型 */
  mimeType: string = 'application/zip';
  /** 文件数 */
  fileCount: number = 0;
  /** 总字节数 */
  totalSize: number = 0;
}

// ── 事件回调集合 ──

/** MtaBleClient → 服务 事件回调 */
export class MtaBleClientEventHandlers {
  /** 发现/更新设备（按 bleAddress 去重后） */
  onDeviceFound: (device: MtaDiscoveredDevice) => void = (device: MtaDiscoveredDevice): void => {
  };
  /** 扫描状态变化 */
  onScanStateChange: (scanning: boolean, detail: string) => void = (scanning: boolean, detail: string): void => {
  };
  /** 蓝牙开关状态变化 */
  onBluetoothStateChange: (stateText: string) => void = (stateText: string): void => {
  };
  /** GATT Client 连接状态变化 */
  onGattConnectionChange: (stateText: string) => void = (stateText: string): void => {
  };
  /** 读回对端 DeviceInfo */
  onRemoteDeviceInfo: (info: DeviceInfoJson) => void = (info: DeviceInfoJson): void => {
  };
  /** 错误上报 */
  onError: (source: string, message: string) => void = (source: string, message: string): void => {
  };
}

/** MtaP2pGroup → 服务 事件回调 */
export class MtaP2pGroupEventHandlers {
  /** 建组完成并取得群组信息 */
  onGroupCreated: (info: MtaGroupInfo) => void = (info: MtaGroupInfo): void => {
  };
  /** p2pConnectionChange 状态摘要 */
  onConnectionChange: (summary: string) => void = (summary: string): void => {
  };
  /** 取得 GO IP */
  onGoIp: (goIp: string) => void = (goIp: string): void => {
  };
  /** 错误上报 */
  onError: (source: string, message: string) => void = (source: string, message: string): void => {
  };
}

/** MtaSendService → ViewModel 事件回调 */
export class MtaSendEventHandlers {
  /** 状态快照变化 */
  onStateChange: (state: SenderState) => void = (state: SenderState): void => {
  };
  /** 新增日志 */
  onLog: (entry: ReceiverLogEntry) => void = (entry: ReceiverLogEntry): void => {
  };
}

// ── 纯函数 ──

/** 构造 ZIP 条目名："{序号}/{显示文件名}"（序号从 1 开始） */
export function buildEntryName(index: number, displayName: string): string {
  return `${index + 1}/${displayName}`;
}

/** 生成 8 位随机群组口令（数字 + 小写字母） */
export function randomPassphrase(): string {
  let chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let out = '';
  for (let i = 0; i < 8; i++) {
    let idx = Math.floor(Math.random() * chars.length);
    out += chars.charAt(idx);
  }
  return out;
}

/** 生成随机任务 ID（时间戳 + 随机后缀） */
export function randomTaskId(): string {
  let suffix = Math.floor(Math.random() * 0x1000000).toString(16);
  while (suffix.length < 6) {
    suffix = '0' + suffix;
  }
  return `mta-${Date.now().toString(16)}-${suffix}`;
}

/** 生成随机群组名（DIRECT- + 8 位十六进制） */
export function randomGroupName(): string {
  let suffix = Math.floor(Math.random() * 0x100000000).toString(16);
  while (suffix.length < 8) {
    suffix = '0' + suffix;
  }
  return `DIRECT-${suffix}`;
}

/** 从选中文件清单计算总字节数 */
export function totalFileBytes(files: Array<MtaSendFile>): number {
  let total = 0;
  for (let i = 0; i < files.length; i++) {
    total += files[i].sizeBytes;
  }
  return total;
}

/** 品牌 ID 是否属于 Samsung 区间 [70, 75] */
export function isSamsungBrandId(brandId: number): boolean {
  return brandId >= 70 && brandId <= 75;
}

/**
 * 按目标品牌与 5GHz 支持能力选择建组频段。
 * Samsung 的 WiFi Direct 在自动/5GHz 频段下与三方建组存在兼容问题，强制用 2.4GHz；
 * 其余品牌按 5GHz 支持能力选择（支持则自动，否则 2.4GHz）。品牌未知（-1）视为非 Samsung。
 */
export function resolveGroupBand(brandId: number, is5Ghz: boolean): number {
  if (isSamsungBrandId(brandId) || !is5Ghz) {
    return MtaConstants.GROUP_OWNER_BAND_2GHZ;
  }
  return MtaConstants.GROUP_OWNER_BAND_AUTO;
}
