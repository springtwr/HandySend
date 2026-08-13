export interface NativeFileToSend {
  fileId: string
  filePath: string
  fileName: string
  fileType: string
  size: number
  preview?: string
  sha256?: string
}

export interface NativeProgressInfo {
  sessionId: string
  fileId: string
  bytesSent: number
  totalBytes: number
  filePath: string
}

export interface NativeSendResult {
  sessionId: string
  success: boolean
  failedFiles: Array<string>
}

export interface NativeServerConfig {
  alias: string
  deviceModel: string
  deviceType: string
  port: number
  saveDir: string
  useHttps: boolean
  pin?: string
  maxConcurrent?: number
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

export interface NativeRecvDiag {
  drainCount: number
  queuedEvents: number
}

export interface NativeCancelTarget {
  ip: string
  port: number
  fingerprint: string
  protocol: string
}

export interface NativeKeyPair {
  privateKey: string
  publicKey: string
}

export interface NativeSecurityContext {
  privateKey: string
  publicKey: string
  certificate: string
  certificateHash: string
}

export interface NativeFileMetadata {
  lastModified?: string
  lastAccessed?: string
}

export interface NativeRegisterResult {
  alias: string
  version: string
  deviceModel: string
  deviceType: string
  fingerprint: string
  protocol: string
  certFingerprint: string
}

export const CANCEL_EVENT_FILE_ID = '_cancel_';

// ── Future NAPI types for Web Share integration ──

export interface WebUploadConfig {
  ssl: boolean
  pin: string
  autoAccept: boolean
}

export interface ChecksumConfig {
  create: boolean
  verify: boolean
}
