/**
 * MtaReceiveModels.ets — MTA 接收端数据类型与纯函数
 *
 * 本文件仅包含数据视图类型、事件回调集合与可单测的纯函数（无系统 API 依赖），
 * 供 MtaReceiveService / MtaReceiveViewModel / MtaReceivePage / 各 MTA 服务共用。
 * WS 消息与 P2pInfo/DeviceInfo 的解析函数放在此处，便于 Local Test 直接覆盖。
 */

// ── 接收阶段状态机 ──

/** 接收端阶段（与 MTA 协议状态机对齐，任意阶段失败进入 FAILED 后回到 SERVICE_RUNNING） */
export enum ReceiverStage {
  /** 未启动 */
  IDLE = 'idle',
  /** 广播 + GATT Server 就绪，等待 CatShare 连接 */
  SERVICE_RUNNING = 'service_running',
  /** 已收到并解密 P2pInfo */
  P2P_INFO_RECEIVED = 'p2p_info_received',
  /** 正在凭据直连 */
  P2P_CONNECTING = 'p2p_connecting',
  /** 已直连并取得 GO IP */
  P2P_CONNECTED = 'p2p_connected',
  /** 正在建立 WS 连接 */
  WS_CONNECTING = 'ws_connecting',
  /** 版本协商完成 */
  NEGOTIATED = 'negotiated',
  /** 收到 sendRequest，等待用户确认 */
  REQUEST_RECEIVED = 'request_received',
  /** 下载中 */
  DOWNLOADING = 'downloading',
  /** 解压落盘中 */
  SAVING = 'saving',
  /** 本次接收完成 */
  COMPLETED = 'completed',
  /** 本次接收失败 */
  FAILED = 'failed'
}

/** 阶段枚举 → 中文展示文本 */
export function receiverStageText(stage: ReceiverStage): string {
  switch (stage) {
    case ReceiverStage.IDLE:
      return '未启动';
    case ReceiverStage.SERVICE_RUNNING:
      return '等待连接';
    case ReceiverStage.P2P_INFO_RECEIVED:
      return '已收到凭据';
    case ReceiverStage.P2P_CONNECTING:
      return '直连中';
    case ReceiverStage.P2P_CONNECTED:
      return '已直连';
    case ReceiverStage.WS_CONNECTING:
      return 'WS 连接中';
    case ReceiverStage.NEGOTIATED:
      return '已协商';
    case ReceiverStage.REQUEST_RECEIVED:
      return '待确认';
    case ReceiverStage.DOWNLOADING:
      return '下载中';
    case ReceiverStage.SAVING:
      return '保存中';
    case ReceiverStage.COMPLETED:
      return '接收完成';
    case ReceiverStage.FAILED:
      return '失败';
    default:
      return '未知';
  }
}

// ── 协议数据类型 ──

/** DeviceInfo（CHAR_STATUS 读返回） */
export class DeviceInfoJson {
  /** 固定 0 */
  state: number = 0;
  /** 蓝牙 MAC（兜底值） */
  mac: string = '';
  /** Base64(X.509 SPKI DER) ECDH P-256 公钥 */
  key: string = '';
  /** CatShare 版本标识 */
  catShare: number = 0;
}

/** P2pInfo（CHAR_P2P 写入值） */
export class P2pInfoJson {
  /** 发送者 ID */
  id: string = '';
  /** 加密后 Base64（key 存在时） */
  ssid: string = '';
  /** 加密后 Base64（key 存在时） */
  psk: string = '';
  /** 加密后 Base64（key 存在时） */
  mac: string = '';
  /** 发送方 HTTPS/WS 端口 */
  port: number = 0;
  /** 群组频点（MHz，部分实现如荣耀会携带） */
  freq: number = 0;
  /** 发送端公钥 Base64（存在即触发解密） */
  key: string = '';
  /** CatShare 版本标识（可选） */
  catShare: number = 0;
}

/** 解密后的 P2P 凭据 */
export class DecryptedCredentials {
  /** WiFi Direct 组 SSID */
  ssid: string = '';
  /** 组密码 */
  psk: string = '';
  /** 发送端 p2p0 MAC */
  mac: string = '';
}

/** 接收请求（来自 sendRequest） */
export class ReceiveRequest {
  /** 任务 ID（同时用作下载 query 参数） */
  taskId: string = '';
  /** 发送方 ID */
  senderId: string = '';
  /** 发送方名称 */
  senderName: string = '';
  /** 主文件名（展示用） */
  fileName: string = '';
  /** 文件数 */
  fileCount: number = 0;
  /** 总字节数 */
  totalSize: number = 0;
}

/** 下载进度 */
export class DownloadProgress {
  /** 已接收字节 */
  receivedBytes: number = 0;
  /** 总字节（未知时为 0） */
  totalBytes: number = 0;
  /** 百分比（0-100，总字节未知时为 0） */
  percent: number = 0;
  /** 当前处理文件名（解压阶段） */
  currentFileName: string = '';
}

/** 接收日志条目 */
export class ReceiverLogEntry {
  /** 时间戳（HH:mm:ss.SSS） */
  timeText: string = '';
  /** 来源标签：广播/GATT/P2P/WS/下载/服务/权限 */
  source: string = '';
  /** 级别：信息/错误 */
  level: string = '信息';
  /** 日志内容 */
  content: string = '';
}

/** 接收端完整状态（服务持有，向 VM 推送快照） */
export class ReceiverState {
  /** 当前阶段 */
  stage: ReceiverStage = ReceiverStage.IDLE;
  /** 接收服务（广播 + GATT）是否运行 */
  serviceRunning: boolean = false;
  /** 广播子状态 */
  advertisingRunning: boolean = false;
  /** GATT Server 子状态 */
  gattRunning: boolean = false;
  /** 本会话 ECDH 公钥（Base64 SPKI DER） */
  ecdhPublicKey: string = '';
  /** 已连接 GATT 客户端标识 */
  connectedPeerId: string = '';
  /** 解密后的 P2P 凭据 */
  credentials: DecryptedCredentials | undefined = undefined;
  /** GO 网关地址 */
  goIpAddress: string = '';
  /** 发送方服务端口 */
  transferPort: number = 0;
  /** 收到的接收请求 */
  receiveRequest: ReceiveRequest | undefined = undefined;
  /** 下载进度 */
  progress: DownloadProgress = new DownloadProgress();
  /** 已保存文件完整路径 */
  savedFiles: Array<string> = [];
  /** 最近一次错误原因 */
  lastError: string = '';

  /** 复制当前状态为独立快照（V2 @Trace 需整体替换才触发刷新） */
  snapshot(): ReceiverState {
    let copy = new ReceiverState();
    copy.stage = this.stage;
    copy.serviceRunning = this.serviceRunning;
    copy.advertisingRunning = this.advertisingRunning;
    copy.gattRunning = this.gattRunning;
    copy.ecdhPublicKey = this.ecdhPublicKey;
    copy.connectedPeerId = this.connectedPeerId;
    copy.credentials = this.credentials;
    copy.goIpAddress = this.goIpAddress;
    copy.transferPort = this.transferPort;
    copy.receiveRequest = this.receiveRequest;
    copy.progress = this.progress;
    copy.savedFiles = this.savedFiles.slice();
    copy.lastError = this.lastError;
    return copy;
  }
}

// ── 事件回调集合 ──

/** MtaBleReceiver → 服务 事件回调 */
export class MtaBleEventHandlers {
  /** 蓝牙开关状态变化 */
  onBluetoothStateChange: (stateText: string) => void = (stateText: string): void => {
  };
  /** 广播状态变化 */
  onAdvertiseStateChange: (running: boolean, detail: string) => void = (running: boolean, detail: string): void => {
  };
  /** GATT 客户端连接状态变化 */
  onGattConnectionChange: (clientDeviceId: string, stateText: string) => void =
    (clientDeviceId: string, stateText: string): void => {
    };
  /** 收到读请求 */
  onGattReadRequest: (clientDeviceId: string, offset: number) => void =
    (clientDeviceId: string, offset: number): void => {
    };
  /** 写分片进度 */
  onGattWriteProgress: (deviceId: string, offset: number, totalLength: number, isPrepared: boolean) => void =
    (deviceId: string, offset: number, totalLength: number, isPrepared: boolean): void => {
    };
  /** 完整收到 P2pInfo 原始 JSON 文本 */
  onP2pInfoReceived: (deviceId: string, payloadText: string) => void =
    (deviceId: string, payloadText: string): void => {
    };
  /** 错误上报 */
  onError: (source: string, message: string) => void = (source: string, message: string): void => {
  };
}

/** MtaP2pConnector → 服务 事件回调 */
export class MtaP2pEventHandlers {
  /** P2P 连接状态变化摘要（p2pConnectionChange，凭据直连场景可能不触发） */
  onP2pConnectionChange: (summary: string) => void = (summary: string): void => {
  };
  /** WLAN 连接状态变化（wifiConnectionChange，凭据直连的可靠确认信号） */
  onWifiConnectionChange: (stateText: string) => void = (stateText: string): void => {
  };
  /** 取得 GO IP */
  onGoIp: (goIp: string) => void = (goIp: string): void => {
  };
  /** 错误上报 */
  onError: (source: string, message: string) => void = (source: string, message: string): void => {
  };
}

/** MtaTransferClient → 服务 事件回调 */
export class MtaTransferEventHandlers {
  /** WS 打开 */
  onWsOpen: () => void = (): void => {
  };
  /** 版本协商完成 */
  onVersionNegotiated: (version: number) => void = (version: number): void => {
  };
  /** 收到接收请求 */
  onReceiveRequest: (request: ReceiveRequest) => void = (request: ReceiveRequest): void => {
  };
  /** WS 关闭 */
  onWsClosed: (reason: string) => void = (reason: string): void => {
  };
  /** 下载进度 */
  onProgress: (progress: DownloadProgress) => void = (progress: DownloadProgress): void => {
  };
  /** 错误上报 */
  onError: (source: string, message: string) => void = (source: string, message: string): void => {
  };
}

/** MtaReceiveService → ViewModel 事件回调 */
export class MtaReceiveEventHandlers {
  /** 状态快照变化 */
  onStateChange: (state: ReceiverState) => void = (state: ReceiverState): void => {
  };
  /** 新增日志 */
  onLog: (entry: ReceiverLogEntry) => void = (entry: ReceiverLogEntry): void => {
  };
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

// ── 通用 JSON 解析辅助（仅此处使用 JSON.parse 类型断言） ──

/** 读取 Record 中的字符串字段，缺失或类型不符返回默认值 */
function readString(obj: Record<string, Object>, key: string, fallback: string): string {
  let value = obj[key];
  if (typeof value === 'string') {
    return value;
  }
  return fallback;
}

/** 读取 Record 中的数字字段，缺失或类型不符返回默认值 */
function readNumber(obj: Record<string, Object>, key: string, fallback: number): number {
  let value = obj[key];
  if (typeof value === 'number') {
    return value;
  }
  return fallback;
}

/** 按协议容错规则从原始文本提取 JSON：首个 `{` 到最后一个 `}`，无匹配则原样返回 */
export function extractJsonText(raw: string): string {
  let start = raw.indexOf('{');
  let end = raw.lastIndexOf('}');
  if (start >= 0 && end > start) {
    return raw.substring(start, end + 1);
  }
  return raw;
}

/** 解析 DeviceInfo JSON，失败返回 undefined */
export function parseDeviceInfo(raw: string): DeviceInfoJson | undefined {
  try {
    let obj = JSON.parse(raw) as Record<string, Object>;
    let info = new DeviceInfoJson();
    info.state = readNumber(obj, 'state', 0);
    info.mac = readString(obj, 'mac', '');
    info.key = readString(obj, 'key', '');
    info.catShare = readNumber(obj, 'catShare', 0);
    return info;
  } catch (e) {
    return undefined;
  }
}

/** 解析 P2pInfo JSON（容错提取 `{}`），失败返回 undefined */
export function parseP2pInfo(raw: string): P2pInfoJson | undefined {
  try {
    let text = extractJsonText(raw);
    let obj = JSON.parse(text) as Record<string, Object>;
    let info = new P2pInfoJson();
    info.id = readString(obj, 'id', '');
    info.ssid = readString(obj, 'ssid', '');
    info.psk = readString(obj, 'psk', '');
    info.mac = readString(obj, 'mac', '');
    info.port = readNumber(obj, 'port', 0);
    info.key = readString(obj, 'key', '');
    info.catShare = readNumber(obj, 'catShare', 0);
    return info;
  } catch (e) {
    return undefined;
  }
}

/** 解析 sendRequest payload，失败返回 undefined */
export function parseSendRequestPayload(payloadJson: string): ReceiveRequest | undefined {
  try {
    let obj = JSON.parse(payloadJson) as Record<string, Object>;
    let request = new ReceiveRequest();
    request.taskId = readString(obj, 'taskId', '');
    request.senderId = readString(obj, 'senderId', '');
    request.senderName = readString(obj, 'senderName', '');
    request.fileName = readString(obj, 'fileName', '');
    request.fileCount = readNumber(obj, 'fileCount', 0);
    request.totalSize = readNumber(obj, 'totalSize', 0);
    return request;
  } catch (e) {
    return undefined;
  }
}

// ── WS 应用层消息 ──

/** WS 消息（type:id:name?json_payload） */
export class WsMessage {
  /** 消息类型：action / ack */
  type: string = '';
  /** 消息 ID */
  id: number = 0;
  /** 消息名：versionNegotiation / sendRequest / status */
  name: string = '';
  /** 可选 JSON payload */
  payload: string = '';
}

/** 解析 `type:id:name?json_payload`，格式非法返回 undefined */
export function parseWsMessage(raw: string): WsMessage | undefined {
  let pattern = new RegExp('^(\\w+):(\\d+):(\\w+)(\\?(.*))?$');
  let match = pattern.exec(raw);
  if (match === null) {
    return undefined;
  }
  let message = new WsMessage();
  message.type = match[1];
  message.id = parseInt(match[2], 10);
  message.name = match[3];
  message.payload = match[5] !== undefined ? match[5] : '';
  return message;
}

/** 构造 `type:id:name?json_payload` 消息文本（payload 为空时省略 `?`） */
export function buildWsMessage(type: string, id: number, name: string, payloadJson: string): string {
  if (payloadJson.length > 0) {
    return `${type}:${id}:${name}?${payloadJson}`;
  }
  return `${type}:${id}:${name}`;
}

// ── 字节辅助 ──

/** 字节数组转小写十六进制字符串 */
export function bytesToHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    let h = bytes[i].toString(16);
    out += h.length === 1 ? '0' + h : h;
  }
  return out;
}

/** 字节数格式化为可读文本（B/KB/MB/GB，保留一位小数） */
export function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  let kb = bytes / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(1)} KB`;
  }
  let mb = kb / 1024;
  if (mb < 1024) {
    return `${mb.toFixed(1)} MB`;
  }
  let gb = mb / 1024;
  return `${gb.toFixed(1)} GB`;
}
