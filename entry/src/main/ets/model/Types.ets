// ── 枚举类型 ──

import { image } from '@kit.ImageKit';

export enum AutoConfirmMode {
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
  tooManyAttempts = 'tooManyAttempts',
  viewed = 'viewed',
  recipientBusy = 'recipientBusy'
}

export enum SendMode {
  single = 'single',
  multiple = 'multiple',
  link = 'link'
}

// ── 数据类型 ──

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

// ── 网络接口类型 ──

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
  isDefault: boolean // 是否为默认网络
  name: string // 接口名（如 "wlan0"、"ancowlan0"）
}

export interface LocalDeviceInfo {
  alias: string
  fingerprint: string
  ip: string // 默认IP（向后兼容）
  interfaces: Array<NetworkInterface> // 所有网卡
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
  // 原生 prepare_upload 事件携带的发送方网络身份。
  // 在轮询回退路径上为空（该路径缺少这些字段）；调用方
  // 然后回退到基于发现的查找。
  senderIp: string
  senderDeviceType: string
  senderDeviceModel: string
  // 事件层已自动确认并接收请求时为 true。
  // 传输页仍会路由并自动确认，使用户看到
  // 进度/完成而非静默后台保存。
  autoConfirmed: boolean
  files: Array<PendingRequestFile>
}

export interface TransferProgress {
  sessionId: string
  fileId: string
  bytesSent: number
  totalBytes: number
  filePath: string
}

// ── 传输页展示层类型（文件清单 + 逐文件进度） ──

// 逐文件传输状态枚举。
export enum FileProgressStatus {
  waiting = 'waiting',
  transferring = 'transferring',
  completed = 'completed',
  failed = 'failed'
}

// 传输页文件元数据，经 TransferPageParams 传入，
// 供渲染文件清单（无需重复查询仓库）。
export interface TransferFileDescriptor {
  fileId: string
  fileName: string
  size: number
  fileType: string
}

// 单个文件的 UI 进度状态，绑定逐文件进度条。
export interface TransferFileProgress {
  fileId: string
  fileName: string
  size: number
  fileType: string
  bytesSent: number
  percent: number
  status: FileProgressStatus
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
  // 视频缩略图（异步懒加载生成）；未生成/失败时为 undefined（显示类型图标）
  previewPixelMap?: image.PixelMap
}

// ── 相册保存相关类型 ──

export interface MediaFileInfo {
  filePath: string
  fileName: string
  fileType: string
  isImage: boolean
}

export interface GallerySaveResult {
  successCount: number
  failCount: number
  errors: Array<string>
}

// ── 功能对齐新增的数据类型 ──

export interface FavoriteDevice {
  id: string
  fingerprint: string
  ip: string
  port: number
  alias: string
  customAlias: boolean
  lastProtocol?: string // 上次成功连接的协议 ('http'|'https')，运行时更新，不持久化
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
  textContent?: string
}

export interface SendSessionState {
  sessionId: string
  targetIp: string
  targetAlias: string
  status: SendSessionStatus
  files: Array<SendFileItem>
  hashedFileCount: number
  totalFiles: number
  // 接收方返回的会话 id（UUID），用于按接收方会话清除/归属该会话的进度条目。
  // 单目标/多目标发送完成时记录；重新发送到同一设备时据此清除旧会话残留进度。
  receiverSessionId?: string
}

export interface WebSendSession {
  sessionId: string
  pending: boolean
  ip: string
  deviceInfo: string
}

// ── Web 下载请求确认相关类型 ──

export interface PendingWebDownload {
  sessionId: string
  ip: string
  userAgent?: string
  timestamp: number
}
