/**
 * MtaSendModels.ets — MTA 发送端数据类型与纯函数
 *
 * 本文件仅包含发送端数据视图类型、事件回调集合与可单测的纯函数（无系统 API 依赖），
 * 供 MtaBleClient / MtaP2pGroup / MtaSendService 共用。
 * 协议类型（DeviceInfoJson/P2pInfoJson/WsMessage 等）复用 MtaProtocolModels，避免双份定义。
 */

import { DeviceInfoJson, bytesToHex } from './MtaProtocolModels';
import { MtaConstants } from '../../service/mta/MtaConstants';
import { LogLevels } from '../../common/LogLevels';
import { resolveMtaBrandName } from './MtaBrandRegistry';

// ── 发送阶段状态机 ──

/** 发送端阶段（连接 → 建组 → 启动服务器 → 写凭据 → WS 协商 → 传输 → 终态） */
export enum MtaSenderStage {
  /** 未启动 */
  IDLE = 'idle',
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
  /** 已发送 sendRequest、等待对端确认（对端开始下载前的有界等待阶段） */
  WAITING_PEER_CONFIRM = 'waiting_peer_confirm',
  /** 传输中 */
  TRANSFERRING = 'transferring',
  /** 本次发送完成 */
  COMPLETED = 'completed',
  /** 本次发送仅部分完成（对端回送成功类型 + 部分接收原因，只收了部分文件） */
  PARTIAL = 'partial',
  /** 本次发送失败（含对端拒绝） */
  FAILED = 'failed',
  /** 用户已取消，正在通知对端取消（非终态：终态仍为 CANCELLED） */
  CANCEL_NOTIFYING = 'cancel_notifying',
  /** 用户取消 */
  CANCELLED = 'cancelled'
}

/** 对端拒绝接收（含未在确认窗口内开始接收）时面向用户的结果文案 */
export const MTA_PEER_REJECTED_TEXT: string = '对方拒绝接收';

/**
 * 等待确认阶段对端已放弃接收时面向用户的结果文案：
 * 覆盖对端关闭连接 / 读取失败 / 状态等待超时 / 退出本次 P2P 组四类「对端放弃」信号，
 * 原始失败原因仍完整保留在日志中以便定位。
 */
export const MTA_PEER_ABANDONED_TEXT: string = '对方已放弃接收';

/** 对端仅接收部分文件（成功类型 + 部分接收原因）时面向用户的结果文案 */
export const MTA_PARTIAL_COMPLETED_TEXT: string = '部分完成（仅接收部分文件）';

/** 用户取消且已通知对端时面向用户的结果文案 */
export const MTA_CANCELLED_TEXT: string = '已取消';

/** 用户取消但未能通知对端（等待上限到期或用户直接返回）时面向用户的结果文案 */
export const MTA_CANCEL_NOTIFY_FAILED_TEXT: string = '已取消（未能通知对方）';

/** 对端忙（DeviceInfo.state 非就绪值）时面向用户的结果文案 */
export const MTA_PEER_BUSY_TEXT: string = '对端设备正忙，请稍后重试';

/**
 * 对端拒绝状态的原因文本 → 面向用户的可读文案。
 * `user refuse` / `timeout` 为协议约定原因；未知原因保留原文，空原因回退默认文案。
 */
export function mtaRejectReasonText(reason: string): string {
  if (reason === 'user refuse') {
    return MTA_PEER_REJECTED_TEXT;
  }
  if (reason === 'timeout') {
    return '对方未在时限内响应';
  }
  return reason.length > 0 ? `对方拒绝：${reason}` : MTA_PEER_REJECTED_TEXT;
}

/**
 * 判定对端是否处于「忙」状态（纯函数，无副作用、可单测）。
 * 严格「非就绪即忙」：对端 DeviceInfo.state 为就绪值（MtaConstants.DEVICE_INFO_STATE）
 * 以外任何值即视为忙；就绪值不触发任何短路，保证既有发送流程零回归。
 */
export function isMtaPeerBusy(state: number): boolean {
  return state !== MtaConstants.DEVICE_INFO_STATE;
}

/**
 * 对端忙原因码 → 诊断日志可读原因（纯函数，无副作用、可单测）：
 * 1 镜像占用、2 热点占用，其余（含缺省 0）为通用未知原因。
 * 仅用于日志归因，面向用户统一使用 MTA_PEER_BUSY_TEXT。
 */
export function mtaPeerBusyReasonText(reason: number): string {
  if (reason === MtaConstants.PEER_BUSY_REASON_MIRROR) {
    return '镜像占用';
  }
  if (reason === MtaConstants.PEER_BUSY_REASON_HOTSPOT) {
    return '热点占用';
  }
  return '未知原因';
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
  /** 最近发现的毫秒时间戳（用于扫描收尾的陈旧条目剔除） */
  lastSeen: number = 0;
}

/** 待发送文件 */
export class MtaSendFile {
  /** 选择器返回的原始 URI（fd 直读的数据源） */
  uri: string = '';
  /** 显示文件名 */
  displayName: string = '';
  /** 文件大小（字节，取自源 URI statSync） */
  sizeBytes: number = 0;
  /** ZIP 条目名（"{序号}/{显示文件名}"） */
  entryName: string = '';
  /** 源文件修改时间（Unix 毫秒，可缺省）；取自源 URI statSync，用于写入 ZIP 条目时间 */
  lastModified: number | undefined = undefined;
  /** 下载发送读取 fd（-1 表示未打开） */
  fdSend: number = -1;
}

/** 发送进度 */
export class MtaSendProgress {
  /** 已读源字节（有效数据口径，进度分子） */
  sentBytes: number = 0;
  /** 总字节（进度分母，声明源总大小） */
  totalBytes: number = 0;
  /** 百分比（0-100） */
  percent: number = 0;
  /** 出网字节累计（网络口径，速率分子；压缩生效时与 sentBytes 不同） */
  networkBytes: number = 0;
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
  /** 选中文件清单 */
  files: Array<MtaSendFile> = [];
  /** 任务 ID（同时用作下载 query 参数） */
  taskId: string = '';
  /** 发送者 ID 十六进制 */
  senderIdHex: string = '';
  /** 发送者显示名（由发送服务按设备昵称填充） */
  senderName: string = '';
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
  /** 总字节 */
  totalBytes: number = 0;
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
    copy.lastError = this.lastError;
    copy.serverRunning = this.serverRunning;
    copy.groupCreated = this.groupCreated;
    return copy;
  }
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
  /** MTU 协商结果回填 */
  onMtuChange: (mtu: number) => void = (mtu: number): void => {
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
}

// ── 纯函数 ──

/** 构造 ZIP 条目名："{序号}/{显示文件名}"（序号从 1 开始） */
export function buildEntryName(index: number, displayName: string): string {
  return `${index + 1}/${displayName}`;
}

/** 生成随机群组口令（数字 + 小写字母，长度见 GROUP_PASSPHRASE_LENGTH） */
export function randomPassphrase(): string {
  let chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let out = '';
  for (let i = 0; i < MtaConstants.GROUP_PASSPHRASE_LENGTH; i++) {
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

/** 生成随机群组名（前缀 + 8 位十六进制，前缀见 GROUP_NAME_PREFIX） */
export function randomGroupName(): string {
  let suffix = Math.floor(Math.random() * 0x100000000).toString(16);
  while (suffix.length < 8) {
    suffix = '0' + suffix;
  }
  return `${MtaConstants.GROUP_NAME_PREFIX}${suffix}`;
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

/** 建组候选：群主频段 + 限定频点（按优先级排列；5GHz 候选同时携带频段与频点） */
export class MtaGroupBandCandidate {
  /** 群主频段（对齐 GroupOwnerBand） */
  band: number = 0;
  /** 限定频点（MHz，0 表示不设 goFreq，仅按频段请求） */
  freqMhz: number = 0;
}

/**
 * 按目标品牌与 5GHz 支持能力给出建组候选（按优先级排列）。
 * Samsung 的 WiFi Direct 在 5GHz 下与三方建组存在兼容问题，只用 2.4GHz；
 * 非 Samsung 且对端声明支持 5GHz 时显式优先请求 5GHz（频段 + 非 DFS 限定频点），
 * 失败/超时再快速回退 2.4GHz；其余情况只用 2.4GHz。品牌未知（-1）视为非 Samsung。
 */
export function resolvePreferredGroupBands(brandId: number, is5Ghz: boolean): MtaGroupBandCandidate[] {
  let band2ghz = new MtaGroupBandCandidate();
  band2ghz.band = MtaConstants.GROUP_OWNER_BAND_2GHZ;
  band2ghz.freqMhz = 0;
  if (isSamsungBrandId(brandId) || !is5Ghz) {
    return [band2ghz];
  }
  let band5ghz = new MtaGroupBandCandidate();
  band5ghz.band = MtaConstants.GROUP_OWNER_BAND_5GHZ;
  band5ghz.freqMhz = MtaConstants.GROUP_5GHZ_FREQUENCY_MHZ;
  return [band5ghz, band2ghz];
}

/** 群组实际频点（MHz）→ 频段标签；0 或落在已知区间外返回 `未知` */
export function bandLabelFromFrequency(freqMhz: number): string {
  if (freqMhz >= MtaConstants.FREQUENCY_2GHZ_MIN && freqMhz <= MtaConstants.FREQUENCY_2GHZ_MAX) {
    return '2.4GHz';
  }
  if (freqMhz >= MtaConstants.FREQUENCY_5GHZ_MIN && freqMhz <= MtaConstants.FREQUENCY_5GHZ_MAX) {
    return '5GHz';
  }
  return '未知';
}

/** 群组实际频点（MHz）是否落在 2.4GHz 受限区间（吞吐上限较低） */
export function isWeakBand(freqMhz: number): boolean {
  return freqMhz >= MtaConstants.FREQUENCY_2GHZ_MIN && freqMhz <= MtaConstants.FREQUENCY_2GHZ_MAX;
}

/**
 * 品牌 ID → 品牌名（委托 MtaBrandRegistry 这一单一事实源查询）。
 * 无法匹配返回 `未知(id)`，展示层由 mtaBrandBadgeText 回退为固定文案。
 */
export function mtaBrandNameOf(brandId: number): string {
  return resolveMtaBrandName(brandId);
}

/**
 * MTA 设备身份键：`senderIdHex` 非空时优先取其小写（去空白），否则回退 `bleAddress` 小写（去空白）。
 * 用于发现合并去重，使同一设备跨 BLE 地址变化时仍被识别为同一条目。
 */
export function mtaDeviceIdentityKey(device: MtaDiscoveredDevice): string {
  let senderId = device.senderIdHex.trim().toLowerCase();
  if (senderId.length > 0) {
    return senderId;
  }
  return device.bleAddress.trim().toLowerCase();
}

/** MTA 广播 serviceData 的解析产物：扫描响应提供发送者 ID 与设备名字节，主广播提供品牌与 5GHz 标识 */
export class MtaAdvParseResult {
  /** 发送者 ID 十六进制（扫描响应第 8~9 字节；无则空串） */
  senderIdHex: string = '';
  /** 设备名字段原始字节（扫描响应第 10~25 字节；无则空数组） */
  nameBytes: Uint8Array = new Uint8Array(0);
  /** 品牌 ID（主广播 UUID 字节解析；无则 -1） */
  brandId: number = -1;
  /** 品牌名（品牌 ID 无法匹配时为 `未知(id)`） */
  brandName: string = '未知';
  /** 是否支持 5GHz */
  is5Ghz: boolean = false;
  /** 原始 serviceData 描述（`UUID=字节hex`，多个以逗号连接） */
  rawServiceData: string = '';
  /** 解析异常描述 */
  anomalies: Array<string> = [];
}

/**
 * 解析 MTA 广播的 serviceData（`Map<UUID, 字节>`）。
 *
 * 与参考实现（CatShare/EasyShare）一致，**按值的字节长度分类而非 UUID**：
 * 27 字节为扫描响应（第 8~9 字节发送者 ID、第 10~25 字节设备名），
 * 6 字节为主广播（5GHz 标识与品牌 ID 编码在 serviceData UUID 的第 3、4 字节），
 * 其余长度忽略。不按 UUID 判断是必要的：部分厂商（如荣耀）扫描响应的 serviceData
 * UUID 并非约定的 `0000ffff`，仅按 UUID 匹配会漏掉设备名。
 */
export function parseMtaAdvServiceData(serviceData: Map<string, Uint8Array>): MtaAdvParseResult {
  let result = new MtaAdvParseResult();
  let rawParts: Array<string> = [];
  serviceData.forEach((value: Uint8Array, uuid: string): void => {
    rawParts.push(`${uuid}=${bytesToHex(value)}`);
    if (value.length === MtaConstants.SCAN_RSP_LENGTH) {
      result.senderIdHex = bytesToHex(value.slice(8, 10));
      result.nameBytes = value.slice(MtaConstants.SCAN_RSP_NAME_OFFSET,
        MtaConstants.SCAN_RSP_NAME_OFFSET + MtaConstants.SCAN_RSP_NAME_LENGTH);
    } else if (value.length === MtaConstants.ADV_DATA_LENGTH) {
      let compact = uuid.split('-').join('').toLowerCase();
      let flag = parseInt(compact.substring(4, 6), 16);
      let brandId = parseInt(compact.substring(6, 8), 16);
      if (!isNaN(flag)) {
        result.is5Ghz = flag === 0x01;
      }
      if (!isNaN(brandId)) {
        result.brandId = brandId;
        result.brandName = mtaBrandNameOf(brandId);
      } else {
        result.anomalies.push(`品牌字节解析失败 uuid=${uuid}`);
      }
    } else {
      result.anomalies.push(`serviceData 长度未知 uuid=${uuid} len=${value.length}`);
    }
  });
  result.rawServiceData = rawParts.length > 0 ? rawParts.join(', ') : '无';
  return result;
}

/** Rust 日志桥接行的解析结果（级别 token + 正文） */
export class RustLogLine {
  /** 级别 token（Rust 原始 token，由调用方归一到规范五级） */
  level: string = LogLevels.INFO;
  /** 日志正文 */
  message: string = '';
}

/**
 * 解析 Rust 日志桥接行 `level|message`：
 * 按首个 `|` 分割，左为级别右为正文；无分隔符时级别按 info 兜底、整串为正文。
 */
export function parseRustLogLine(line: string): RustLogLine {
  let parsed = new RustLogLine();
  let sep = line.indexOf('|');
  if (sep >= 0) {
    parsed.level = line.substring(0, sep);
    parsed.message = line.substring(sep + 1);
  } else {
    parsed.level = LogLevels.INFO;
    parsed.message = line;
  }
  return parsed;
}
