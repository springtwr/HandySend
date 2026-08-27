export interface NativeFileToSend {
  fileId: string
  filePath: string
  fileName: string
  fileType: string
  size: number
  preview?: string
  sha256?: string
}

export interface NativeHttpError {
  kind: string
  status?: number
  message?: string
}

export interface NativeSendResult {
  sessionId: string
  success: boolean
  failedFiles: Array<string>
  error?: NativeHttpError
}

export interface NativeServerConfig {
  alias: string
  deviceModel: string
  deviceType: string
  port: number
  saveDir: string
  useHttps: boolean
  verifyChecksums?: boolean
  pin?: string
  maxConcurrent?: number
  showToken?: string
}

export interface NativeServerHandle {
  fingerprint: string
  port: number
}

export interface NativeServerStatus {
  running: boolean
  activeSession?: string
  fingerprint?: string
}

export interface NativeTargetDevice {
  ip: string
  port: number
  fingerprint: string
  protocol: string
  publicKey?: string
  // 接收方要求 PIN 验证时携带（发送 prepare-upload 时作为 query 参数）
  pin?: string
}

export interface NativeTransferFileInfo {
  fileId: string
  fileName: string
  size: number
  fileType: string
  preview?: string
  sha256?: string
}

export interface NativeTransferRequest {
  sessionId: string
  senderAlias: string
  senderFingerprint: string
  senderProtocol: string
  files: Array<NativeTransferFileInfo>
}

export interface NativeShareLinkInfo {
  url: string
  port: number
  sessionId: string
}

export interface NativeCancelTarget {
  ip: string
  port: number
  fingerprint: string
  protocol: string
}

export interface NativeRegisterResult {
  alias: string
  version: string
  deviceModel: string
  deviceType: string
  fingerprint: string
  protocol: string
  certFingerprint: string
  publicKey: string
}

// ── 安全上下文（TLS 证书身份） ──

export interface NativeSecurityContext {
  privateKey: string
  publicKey: string
  certificate: string
  certificateHash: string
}

// ── 发现类型 ──

export interface NativeDiscoveryConfig {
  port: number
  protocol: string
  multicastGroup: string
  networkWhitelist?: Array<string>
  networkBlacklist?: Array<string>
  discoveryTimeoutMs: number
  download: boolean
}

export interface NativeDiscoveredDevice {
  alias: string
  fingerprint: string
  version: string
  deviceModel: string
  deviceType: string
  download: boolean
  host: string
  port: number
  protocol: string
  channels: Array<NativeDeviceChannel>
  publicKey?: string
}

export interface NativeDeviceChannel {
  host: string
  port: number
  protocol: string
}

// ── Web 分享事件类型（来自 Rust WebSendEvent 回调） ──

export interface NativeWebSendPrepare {
  type: 'web_prepare_download'
  sessionId: string
  ip: string
  userAgent?: string
}

export interface NativeWebSendFileDownload {
  type: 'web_file_download'
  sessionId: string
  fileId: string
  fileName: string
  size: number
  fileType: string
}

// ── 服务器事件类型（来自 Rust ServerEventV2 回调） ──

export interface NativeServerRegisterEvent {
  type: 'register'
  ip: string
  info: NativeRegisterInfo
}

export interface NativeRegisterInfo {
  alias: string
  version: string
  deviceModel?: string
  deviceType?: string
  fingerprint: string
  download: boolean
  port: number
  protocol?: string
}

export interface NativePrepareUploadEvent {
  type: 'prepare_upload'
  sessionId: string
  ip: string
  info: NativeRegisterInfo
  certFingerprint?: string
  files: Array<NativeTransferFileInfo>
}

export interface NativeFileUploadEvent {
  type: 'file_upload'
  sessionId: string
  fileId: string
  file: NativeTransferFileInfo
}

export interface NativeSessionEndEvent {
  type: 'session_end'
  sessionId: string
  reason: string
}

export interface NativePrepareUploadAbortedEvent {
  type: 'prepare_upload_aborted'
  sessionId: string
}

export interface NativeCancelReceivedEvent {
  type: 'cancel_received'
  ip: string
  sessionId: string
}

// ── 客户端事件类型（来自 Rust client 回调） ──

export interface NativeProgressUpdateEvent {
  type: 'progress_update'
  direction: string
  sessionId: string
  fileId: string
  bytesSent: number
  totalBytes: number
  filePath: string
}

// ── 哈希事件类型（来自 Rust hash 回调） ──

// ── 发现事件类型 ──

export interface NativeDiscoveryUpdateEvent {
  type: 'discovery_update'
  devices: Array<NativeDiscoveredDevice>
}

export interface NativeDeviceFoundEvent {
  type: 'device_found'
  device: Record<string, Object>
}

// ── 所有原生事件的联合 ──

export type NativeEvent =
  NativeServerRegisterEvent |
  NativePrepareUploadEvent |
  NativeFileUploadEvent |
  NativeSessionEndEvent |
  NativePrepareUploadAbortedEvent |
  NativeCancelReceivedEvent |
  NativeProgressUpdateEvent |
  NativeDiscoveryUpdateEvent |
  NativeDeviceFoundEvent |
  NativeWebSendPrepare |
  NativeWebSendFileDownload;

export function parseNativeEvent(json: string): NativeEvent | undefined {
  let obj: Record<string, Object> = {};
  try {
    obj = JSON.parse(json) as Record<string, Object>;
  } catch (_e) {
    return undefined;
  }
  let t: string = '';
  if (obj['type'] !== undefined) {
    t = obj['type'] as string;
  }
  switch (t) {
    case 'register':
      return {
        type: 'register',
        ip: obj['ip'] as string,
        info: parseRegisterInfo(obj['info'] as Record<string, Object>)
      } as NativeServerRegisterEvent;
    case 'prepare_upload':
      return parsePrepareUploadEvent(obj);
    case 'file_upload':
      return {
        type: 'file_upload',
        sessionId: obj['sessionId'] as string,
        fileId: obj['fileId'] as string,
        file: parseTransferFileInfo(obj['file'] as Record<string, Object>)
      } as NativeFileUploadEvent;
    case 'session_end':
      return { type: 'session_end', sessionId: obj['sessionId'] as string, reason: obj['reason'] as string } as
        NativeSessionEndEvent;
    case 'prepare_upload_aborted':
      return { type: 'prepare_upload_aborted', sessionId: obj['sessionId'] as string } as
        NativePrepareUploadAbortedEvent;
    case 'cancel_received':
      return { type: 'cancel_received', ip: obj['ip'] as string, sessionId: obj['sessionId'] as string } as
        NativeCancelReceivedEvent;
    case 'progress_update':
      return {
        type: 'progress_update',
        direction: obj['direction'] as string,
        sessionId: obj['sessionId'] as string,
        fileId: obj['fileId'] as string,
        bytesSent: obj['bytesSent'] as number,
        totalBytes: obj['totalBytes'] as number,
        filePath: obj['filePath'] as string
      } as NativeProgressUpdateEvent;
    case 'discovery_update':
      return { type: 'discovery_update', devices: obj['devices'] as Array<NativeDiscoveredDevice> } as
        NativeDiscoveryUpdateEvent;
    case 'device_found':
      return { type: 'device_found', device: obj['device'] as Record<string, Object> } as NativeDeviceFoundEvent;
    case 'web_prepare_download':
      return {
        type: 'web_prepare_download',
        sessionId: obj['sessionId'] as string,
        ip: obj['ip'] as string,
        userAgent: obj['userAgent'] as string | undefined
      } as NativeWebSendPrepare;
    case 'web_file_download':
      return {
        type: 'web_file_download',
        sessionId: obj['sessionId'] as string,
        fileId: obj['fileId'] as string,
        fileName: obj['fileName'] as string,
        size: obj['size'] as number,
        fileType: obj['fileType'] as string
      } as NativeWebSendFileDownload;
    default:
      return undefined;
  }
}

function parseRegisterInfo(obj: Record<string, Object> | undefined): NativeRegisterInfo {
  if (obj === undefined || obj === null) {
    return {
      alias: '',
      version: '',
      fingerprint: '',
      download: false,
      port: 0,
      protocol: 'https'
    } as NativeRegisterInfo;
  }
  return {
    alias: (obj['alias'] !== undefined && obj['alias'] !== null) ? obj['alias'] as string : '',
    version: (obj['version'] !== undefined && obj['version'] !== null) ? obj['version'] as string : '',
    deviceModel: (obj['deviceModel'] !== undefined && obj['deviceModel'] !== null) ? obj['deviceModel'] as string :
      undefined,
    deviceType: (obj['deviceType'] !== undefined && obj['deviceType'] !== null) ? obj['deviceType'] as string :
      undefined,
    fingerprint: (obj['fingerprint'] !== undefined && obj['fingerprint'] !== null) ? obj['fingerprint'] as string : '',
    download: (obj['download'] !== undefined && obj['download'] !== null) ? obj['download'] as boolean : false,
    port: (obj['port'] !== undefined && obj['port'] !== null) ? obj['port'] as number : 0,
    protocol: (obj['protocol'] !== undefined && obj['protocol'] !== null) ? obj['protocol'] as string : 'https',
  } as NativeRegisterInfo;
}

function parseTransferFileInfo(obj: Record<string, Object> | undefined): NativeTransferFileInfo {
  if (obj === undefined) {
    return {
      fileId: '',
      fileName: '',
      size: 0,
      fileType: ''
    } as NativeTransferFileInfo;
  }
  return {
    fileId: obj['id'] !== undefined ? obj['id'] as string : (obj['fileId'] as string),
    fileName: obj['fileName'] as string,
    size: obj['size'] as number,
    fileType: obj['fileType'] as string,
    preview: obj['preview'] as string | undefined,
    sha256: obj['sha256'] as string | undefined,
  } as NativeTransferFileInfo;
}

function parsePrepareUploadEvent(obj: Record<string, Object>): NativePrepareUploadEvent {
  let filesRaw: Object | undefined = obj['files'];
  let files: Array<NativeTransferFileInfo> = [];
  if (filesRaw !== undefined && Array.isArray(filesRaw)) {
    let arr = filesRaw as Array<Record<string, Object>>;
    for (let i = 0; i < arr.length; i++) {
      files.push(parseTransferFileInfo(arr[i]));
    }
  }
  return {
    type: 'prepare_upload',
    sessionId: obj['sessionId'] as string,
    ip: obj['ip'] as string,
    info: parseRegisterInfo(obj['info'] as Record<string, Object>),
    certFingerprint: obj['certFingerprint'] !== undefined && obj['certFingerprint'] !== null ?
      obj['certFingerprint'] as string : undefined,
    files: files,
  } as NativePrepareUploadEvent;
}

// ── CancellationToken ──

export interface NativeCancellationToken {
  id: string
}
