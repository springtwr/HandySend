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
}

export interface LocalDeviceInfo {
  alias: string
  fingerprint: string
  ip: string
}

export interface PendingRequestFile {
  fileId: string
  fileName: string
  size: number
  fileType: string
  preview?: string
}

export interface PendingRequest {
  sessionId: string
  senderAlias: string
  senderFingerprint: string
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
