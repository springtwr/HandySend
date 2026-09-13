/**
 * MtaProtocolModels.ets — MTA 共享协议层数据类型与纯函数
 *
 * 本文件仅包含数据视图类型、事件回调集合与可单测的纯函数（无系统 API 依赖），
 * 供 MTA 接收端与发送端各服务共用。
 * WS 消息与 P2pInfo/DeviceInfo 的解析函数放在此处，便于 Local Test 直接覆盖。
 */

import { MediaFileInfo } from '../Types';

// ── 接收阶段状态机 ──

/** 接收端阶段（与 MTA 协议状态机对齐，任意阶段失败进入 FAILED 后回到 SERVICE_RUNNING） */
export enum ReceiverStage {
  /** 未启动 */
  IDLE = 'idle',
  /** 广播 + GATT Server 就绪，等待互传设备连接 */
  SERVICE_RUNNING = 'service_running',
  /** 已收到并解密 P2pInfo */
  P2P_INFO_RECEIVED = 'p2p_info_received',
  /** 正在经 p2pConnect 加入发送方群组 */
  P2P_CONNECTING = 'p2p_connecting',
  /** 已加入群组并取得 GO IP */
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
      return '连接中';
    case ReceiverStage.P2P_CONNECTED:
      return '已连接';
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

// ── WS 握手诊断 ──

/** WS 单轮失败类型 */
export enum WsFailureKind {
  /** 无失败（成功） */
  NONE = 'none',
  /** 本地超时 */
  TIMEOUT = 'timeout',
  /** error 事件 */
  ERROR = 'error',
  /** connect 发起被拒绝 */
  CONNECT_REJECT = 'connect_reject'
}

/** WS 单轮失败类型 → 中文展示文本 */
export function wsFailureKindText(kind: WsFailureKind): string {
  switch (kind) {
    case WsFailureKind.TIMEOUT:
      return '超时';
    case WsFailureKind.ERROR:
      return 'error 事件';
    case WsFailureKind.CONNECT_REJECT:
      return '发起拒绝';
    default:
      return '无';
  }
}

/** WS 单轮尝试记录 */
export class WsAttemptRecord {
  /** 轮次序号（1 起） */
  round: number = 0;
  /** 本轮是否成功 */
  success: boolean = false;
  /** 本轮耗时（毫秒） */
  costMs: number = 0;
  /** 失败类型（成功为 NONE） */
  failureKind: WsFailureKind = WsFailureKind.NONE;
  /** 原始错误码文本（无则空串） */
  failureCode: string = '';
  /** 原始错误文本（无则空串） */
  failureText: string = '';
}

/** WS 单轮尝试 → 时间线展示文本 */
export function formatWsAttemptLine(record: WsAttemptRecord): string {
  if (record.success) {
    return `第 ${record.round} 轮：成功 耗时 ${record.costMs}ms`;
  }
  let kindText = wsFailureKindText(record.failureKind);
  let codeText = record.failureCode.length > 0 ? ` code=${record.failureCode}` : '';
  let msgText = record.failureText.length > 0 ? ` ${record.failureText}` : '';
  return `第 ${record.round} 轮：失败（${kindText}） 耗时 ${record.costMs}ms${codeText}${msgText}`;
}

/** WS 握手结果 */
export class WsHandshakeResult {
  /** 目标地址（wss://IP:端口/路径） */
  targetUrl: string = '';
  /** 是否握手成功 */
  success: boolean = false;
  /** 总耗时（毫秒） */
  totalMs: number = 0;
  /** 每轮尝试记录（按轮次顺序） */
  attempts: Array<WsAttemptRecord> = [];
  /** 结果摘要文本 */
  summary: string = '';
}

/** 由握手结果生成摘要文本（成功与否、总耗时、尝试轮数） */
export function buildWsHandshakeSummary(result: WsHandshakeResult): string {
  let resultText = result.success ? '成功' : '失败';
  return `目标 ${result.targetUrl}：${resultText}，共 ${result.attempts.length} 轮，总耗时 ${result.totalMs}ms`;
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
  /** WiFi Direct 组 SSID（注入 p2pConnect 的 groupName） */
  ssid: string = '';
  /** 组密码（注入 p2pConnect 的 passphrase） */
  psk: string = '';
  /** 发送端 p2p0 MAC（仅日志诊断，连接路线不消费） */
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
  /** MTA 原生文本内容（来自 sendRequest 的 catShareText，缺省为空串） */
  textContent: string = '';
}

/** 已接收文件条目（展示用：文件名 + 大小） */
export class ReceivedFileEntry {
  /** 文件显示名（不含目录） */
  name: string = '';
  /** 文件字节大小 */
  size: number = 0;
  /** 真实文件类型（按扩展名解析的 MIME；空串表示未解析） */
  fileType: string = '';
}

/** 下载进度 */
export class DownloadProgress {
  /** 已接收字节 */
  receivedBytes: number = 0;
  /** 总字节（未知时为 0） */
  totalBytes: number = 0;
  /** 百分比（0-100，总字节未知时为 0） */
  percent: number = 0;
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
  /** 对端群组实际频点（MHz，0 表示未知/读取失败） */
  groupFrequency: number = 0;
  /** 收到的接收请求 */
  receiveRequest: ReceiveRequest | undefined = undefined;
  /** 下载进度 */
  progress: DownloadProgress = new DownloadProgress();
  /** 已保存文件完整路径 */
  savedFiles: Array<string> = [];
  /** 本次接收已落盘的文件条目（文件名 + 大小 + 真实类型），保存完成后填充 */
  receivedFiles: Array<ReceivedFileEntry> = [];
  /** 待保存到相册的媒体文件（"保存到相册"开启且有图片/视频时填充） */
  pendingMediaFiles: Array<MediaFileInfo> = [];
  /** 最近一次错误原因 */
  lastError: string = '';
  /** 最近一次 WS 握手结果（未执行时未定义） */
  wsHandshakeResult: WsHandshakeResult | undefined = undefined;
  /** 网络并存汇总文本（本机 IP/网关 + 默认网络 + 网络条目） */
  networkSummary: string = '';

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
    copy.groupFrequency = this.groupFrequency;
    copy.receiveRequest = this.receiveRequest;
    copy.progress = this.progress;
    copy.savedFiles = this.savedFiles.slice();
    copy.receivedFiles = this.receivedFiles.slice();
    copy.pendingMediaFiles = this.pendingMediaFiles.slice();
    copy.lastError = this.lastError;
    copy.wsHandshakeResult = this.wsHandshakeResult;
    copy.networkSummary = this.networkSummary;
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
  /** P2P 连接状态变化摘要（p2pConnectionChange，连接成功的主确认信号） */
  onP2pConnectionChange: (summary: string) => void = (summary: string): void => {
  };
  /** P2P 总开关状态变化（p2pStateChange） */
  onP2pStateChange: (stateText: string) => void = (stateText: string): void => {
  };
  /** 取得 GO IP */
  onGoIp: (goIp: string) => void = (goIp: string): void => {
  };
  /** 读取到对端群组实际频点（MHz，0 表示未知/读取失败） */
  onGroupFrequency: (freqMhz: number) => void = (freqMhz: number): void => {
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

/**
 * 按 UTF-8 字节上限截断文本，超限时在边界字符前截断（不切断代理对）。
 * 未超限返回原文本。
 */
export function truncateUtf8Text(text: string, maxBytes: number): string {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    let code = text.charCodeAt(i);
    let size = 1;
    if (code < 0x80) {
      size = 1;
    } else if (code < 0x800) {
      size = 2;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      // 高代理项：与其低代理项合占 4 字节，避免在代理对中间截断
      size = 4;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      // 孤立低代理项按 3 字节计（正常文本不会出现）
      size = 3;
    } else {
      size = 3;
    }
    if (bytes + size > maxBytes) {
      return text.substring(0, i);
    }
    bytes += size;
  }
  return text;
}

/**
 * 校验版本协商 payload 是否包含本机支持的协议版本。
 * 宽松策略：payload 为空、解析失败或未携带版本字段均视为支持（老对端不受影响）；
 * 携带 versions 数组时检查是否含 supported，否则检查 version 是否等于 supported。
 */
export function isVersionNegotiationSupported(payload: string, supported: number): boolean {
  if (payload.length === 0) {
    return true;
  }
  let obj: Record<string, Object>;
  try {
    obj = JSON.parse(payload) as Record<string, Object>;
  } catch (e) {
    return true;
  }
  let versionsVal = obj['versions'];
  if (Array.isArray(versionsVal)) {
    let versions = versionsVal as Object[];
    for (let i = 0; i < versions.length; i++) {
      if (versions[i] === supported) {
        return true;
      }
    }
    return false;
  }
  let versionVal = obj['version'];
  if (typeof versionVal === 'number') {
    return versionVal === supported;
  }
  return true;
}

/** 解析 sendRequest payload，失败返回 undefined */
export function parseSendRequestPayload(payloadJson: string): ReceiveRequest | undefined {
  try {
    let obj = JSON.parse(payloadJson) as Record<string, Object>;
    let request = new ReceiveRequest();
    // MTA 约定任务 ID 同时写入 taskId/id：优先取 taskId，缺失时回退 id（部分实现仅写 id）
    request.taskId = readString(obj, 'taskId', '');
    if (request.taskId.length === 0) {
      request.taskId = readString(obj, 'id', '');
    }
    request.senderId = readString(obj, 'senderId', '');
    request.senderName = readString(obj, 'senderName', '');
    request.fileName = readString(obj, 'fileName', '');
    request.fileCount = readNumber(obj, 'fileCount', 0);
    request.totalSize = readNumber(obj, 'totalSize', 0);
    // MTA 原生文本：catShareText 缺省时为空串（行为与既有完全一致）
    request.textContent = readString(obj, 'catShareText', '');
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

/** 接收端 status 回执的 JSON 形状（MTA 约定携带 taskId/type/reason） */
interface MtaStatusPayload {
  /** 任务 ID */
  taskId: string;
  /** 状态类型：1 成功 / 3 拒绝 */
  type: number;
  /** 状态原因 */
  reason: string;
}

/** 构造接收端 status 回执 payload（对 taskId/reason 做 JSON 转义，避免特殊字符破坏报文） */
export function buildStatusPayload(taskId: string, type: number, reason: string): string {
  let payload: MtaStatusPayload = { taskId: taskId, type: type, reason: reason };
  return JSON.stringify(payload);
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
