export interface NativeFileToSend {
  fileId: string
  filePath: string
  fileName: string
  fileType: string
  size: number
}

export interface NativeProgressInfo {
  sessionId: string
  fileId: string
  bytesSent: number
  totalBytes: number
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
}

export interface NativeTransferFileInfo {
  fileId: string
  fileName: string
  size: number
  fileType: string
}

export interface NativeTransferRequest {
  sessionId: string
  senderAlias: string
  senderFingerprint: string
  files: Array<NativeTransferFileInfo>
}
