// ── Enum types ──

export enum QuickSaveMode {
  off = 'off',
  paired = 'paired',
  on = 'on'
}

export enum SendSessionStatus {
  waiting = 'waiting',
  calculatingHash = 'calculatingHash',
  sending = 'sending',
  finished = 'finished',
  finishedWithErrors = 'finishedWithErrors',
  declined = 'declined',
  canceled = 'canceled',
  canceledByReceiver = 'canceledByReceiver',
  tooManyAttempts = 'tooManyAttempts'
}

export enum SendMode {
  single = 'single',
  multiple = 'multiple',
  link = 'link'
}

// ── Data types ──

export interface DeviceChannel {
  host: string
  port: number
  protocol: string
}

export interface DiscoveredDevice {
  alias: string
  ip: string
  port: number
  fingerprint: string
  version: string
  deviceModel: string
  deviceType: string
  protocol: string
  lastSeen: number
  channels: Array<DeviceChannel>
  publicKey?: string
}

// ── Network interface types ──

export enum NetworkType {
  wifi = 'wifi',
  cellular = 'cellular',
  ethernet = 'ethernet',
  unknown = 'unknown'
}

export interface NetworkInterface {
  ip: string
  prefixLength: number
  type: NetworkType
  isDefault: boolean  // 是否为默认网络
}

export interface LocalDeviceInfo {
  alias: string
  fingerprint: string
  ip: string  // 默认IP（向后兼容）
  interfaces: Array<NetworkInterface>  // 所有网卡
}

export interface PendingRequestFile {
  fileId: string
  fileName: string
  size: number
  fileType: string
  preview?: string
  sha256?: string
}

export interface PendingRequest {
  sessionId: string
  senderAlias: string
  senderFingerprint: string
  senderProtocol: string
  files: Array<PendingRequestFile>
}

export interface TransferProgress {
  sessionId: string
  fileId: string
  bytesSent: number
  totalBytes: number
  filePath: string
}

export interface SendFileItem {
  fileId: string
  filePath: string
  fileName: string
  fileType: string
  size: number
  preview?: string
  hash?: string
}

export interface LogEntry {
  timestamp: number
  level: string
  message: string
}

export interface StagedFile {
  uri: string
  fileName: string
  fileType: string
  isImage: boolean
  isManualText?: boolean
}

// ── New data types for feature alignment ──

export interface FavoriteDevice {
  id: string
  fingerprint: string
  ip: string
  port: number
  alias: string
  customAlias: boolean
}

export interface ReceiveHistoryEntry {
  id: string
  fileName: string
  fileType: string
  path: string
  savedToGallery: boolean
  isMessage: boolean
  fileSize: number
  senderAlias: string
  timestamp: number
}

export interface SendSessionState {
  sessionId: string
  targetIp: string
  targetAlias: string
  status: SendSessionStatus
  files: Array<SendFileItem>
  hashedFileCount: number
  totalFiles: number
}

export interface WebSendSession {
  sessionId: string
  pending: boolean
  ip: string
  deviceInfo: string
}
