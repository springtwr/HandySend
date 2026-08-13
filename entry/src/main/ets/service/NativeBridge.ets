import { createServer, stopServer, getServerStatus, pollPendingRequests, pollProgress, pollSendProgress, respondTransfer, sendFiles, createShareLink, stopShareServer, pollShareProgress, getRecvDiag, cancelTransferRemote, cancelLocalSession, getCurrentSendSessionId, pollDebugLog, getNativeVersion, getProtocolVersion,
  verifyCert, generateKeyPair, generateSecurityContext, hashFile, sanitizeFileName, isValidFileName, readFileMetadata, computeFingerprintHash, registerDevice,
  ProgressInfo, TransferRequest, ServerHandle, ServerStatus, SendResult, ShareLinkInfo, RecvDiag, KeyPair, SecurityContext, FileMetadataResult } from 'localsend_ohrs';

import { NativeServerConfig, NativeServerHandle, NativeServerStatus, NativeTargetDevice, NativeTransferRequest, NativeTransferFileInfo, NativeProgressInfo, NativeFileToSend, NativeSendResult, NativeShareLinkInfo, NativeRecvDiag, NativeCancelTarget, NativeKeyPair, NativeSecurityContext, NativeFileMetadata
} from '../model/NativeTypes';

// Expected native library version (must match Cargo.toml and oh-package.json5)
const EXPECTED_NATIVE_VERSION = '1.18.1';

/**
 * Verify native library version matches expected version.
 * Call this during app initialization.
 * @throws Error if version mismatch
 */
export function verifyNativeVersion(): void {
  const actualVersion = getNativeVersion();
  if (actualVersion !== EXPECTED_NATIVE_VERSION) {
    throw new Error(`Native library version mismatch: expected ${EXPECTED_NATIVE_VERSION}, got ${actualVersion}`);
  }
}

/**
 * Get native library version (for display/logging)
 */
export function getNativeLibraryVersion(): string {
  return getNativeVersion();
}

/**
 * Get the LocalSend protocol version (e.g. "2.2")
 */
export function getLocalSendProtocolVersion(): string {
  return getProtocolVersion();
}

export async function nativeCreateServer(config: NativeServerConfig): Promise<NativeServerHandle> {
  let handle: ServerHandle = await createServer(JSON.stringify(config));
  let result: NativeServerHandle = {
    fingerprint: handle.fingerprint,
    port: handle.port
  };
  return result;
}

export async function nativeStopServer(): Promise<void> {
  stopServer();
}

export function nativeGetServerStatus(): NativeServerStatus {
  let status: ServerStatus = getServerStatus();
  let result: NativeServerStatus = {
    running: status.running,
    activeSession: status.activeSession,
    fingerprint: status.fingerprint
  };
  return result;
}

export function nativePollPendingRequests(): Array<NativeTransferRequest> {
  let requests: Array<TransferRequest> = pollPendingRequests();
  let result: Array<NativeTransferRequest> = [];
  for (let i = 0; i < requests.length; i++) {
    let r: TransferRequest = requests[i];
    let nativeFiles: Array<NativeTransferFileInfo> = [];
    for (let j = 0; j < r.files.length; j++) {
      let f = r.files[j];
      nativeFiles.push({
        fileId: f.fileId,
        fileName: f.fileName,
        size: f.size,
        fileType: f.fileType,
        preview: f.preview,
        sha256: f.sha256
      });
    }
    result.push({
      sessionId: r.sessionId,
      senderAlias: r.senderAlias,
      senderFingerprint: r.senderFingerprint,
      senderProtocol: r.senderProtocol,
      files: nativeFiles
    });
  }
  return result;
}

export function nativePollProgress(): Array<NativeProgressInfo> {
  let items: Array<ProgressInfo> = pollProgress();
  let result: Array<NativeProgressInfo> = [];
  for (let i = 0; i < items.length; i++) {
    let p: ProgressInfo = items[i];
    result.push({
      sessionId: p.sessionId,
      fileId: p.fileId,
      bytesSent: p.bytesSent,
      totalBytes: p.totalBytes,
      filePath: p.filePath
    });
  }
  return result;
}

export function nativePollSendProgress(): Array<NativeProgressInfo> {
  let items: Array<ProgressInfo> = pollSendProgress();
  let result: Array<NativeProgressInfo> = [];
  for (let i = 0; i < items.length; i++) {
    let p: ProgressInfo = items[i];
    result.push({
      sessionId: p.sessionId,
      fileId: p.fileId,
      bytesSent: p.bytesSent,
      totalBytes: p.totalBytes,
      filePath: p.filePath
    });
  }
  return result;
}

export async function nativeCreateShareLink(files: Array<NativeFileToSend>, alias: string): Promise<NativeShareLinkInfo> {
  let info: ShareLinkInfo = await createShareLink(JSON.stringify(files), alias);
  let result: NativeShareLinkInfo = {
    url: info.url,
    port: info.port,
    sessionId: info.sessionId
  };
  return result;
}

export async function nativeStopShareServer(): Promise<void> {
  stopShareServer();
}

export function nativePollShareProgress(): Array<NativeProgressInfo> {
  let items: Array<ProgressInfo> = pollShareProgress();
  let result: Array<NativeProgressInfo> = [];
  for (let i = 0; i < items.length; i++) {
    let p: ProgressInfo = items[i];
    result.push({
      sessionId: p.sessionId,
      fileId: p.fileId,
      bytesSent: p.bytesSent,
      totalBytes: p.totalBytes,
      filePath: p.filePath
    });
  }
  return result;
}

export async function nativeRespondTransfer(sessionId: string, accept: boolean, acceptedFileIds: Array<string> = []): Promise<void> {
  await respondTransfer(sessionId, accept, acceptedFileIds);
}

export async function nativeSendFiles(target: NativeTargetDevice, senderAlias: string, files: Array<NativeFileToSend>): Promise<NativeSendResult> {
  let result: SendResult = await sendFiles(JSON.stringify(target), senderAlias, JSON.stringify(files));
  let nativeResult: NativeSendResult = {
    sessionId: result.sessionId,
    success: result.success,
    failedFiles: result.failedFiles
  };
  return nativeResult;
}

export function nativeGetRecvDiag(): NativeRecvDiag {
  let diag: RecvDiag = getRecvDiag();
  let result: NativeRecvDiag = {
    drainCount: diag.drainCount,
    queuedEvents: diag.queuedEvents
  };
  return result;
}

export async function nativeCancelTransfer(target: NativeCancelTarget, sessionId: string): Promise<void> {
  await cancelTransferRemote(JSON.stringify(target), sessionId);
}

export async function nativeCancelLocalSession(sessionId: string): Promise<void> {
  await cancelLocalSession(sessionId);
}

export function nativeGetCurrentSendSessionId(): string {
  return getCurrentSendSessionId();
}

export function nativePollDebugLog(): Array<string> {
  return pollDebugLog();
}

// ── Crypto / Security NAPI wrappers ──

/**
 * Verify a certificate against a public key.
 * Returns true if verification succeeds, false if it fails.
 * Throws only on unexpected internal errors (malformed input, etc.).
 */
export function nativeVerifyCert(certPem: string, publicKey: string): boolean {
  try {
    verifyCert(certPem, publicKey);
    return true;
  } catch (_e) {
    return false;
  }
}

export function nativeGenerateKeyPair(): NativeKeyPair {
  let kp: KeyPair = generateKeyPair();
  let result: NativeKeyPair = {
    privateKey: kp.privateKey,
    publicKey: kp.publicKey
  };
  return result;
}

export function nativeGenerateSecurityContext(): NativeSecurityContext {
  let ctx: SecurityContext = generateSecurityContext();
  let result: NativeSecurityContext = {
    privateKey: ctx.privateKey,
    publicKey: ctx.publicKey,
    certificate: ctx.certificate,
    certificateHash: ctx.certificateHash
  };
  return result;
}

// ── File hash NAPI wrapper ──

export async function nativeHashFile(path: string): Promise<string> {
  return await hashFile(path);
}

// ── Fingerprint hash NAPI wrapper ──

export function nativeComputeFingerprintHash(combined: string): string {
  return computeFingerprintHash(combined);
}

// ── File name utilities NAPI wrappers ──

export function nativeSanitizeFileName(name: string): string {
  return sanitizeFileName(name);
}

export function nativeIsValidFileName(name: string): boolean {
  return isValidFileName(name);
}

// ── File metadata NAPI wrapper ──

export function nativeReadFileMetadata(path: string): NativeFileMetadata | undefined {
  let result: FileMetadataResult | null = readFileMetadata(path);
  if (result === null) {
    return undefined;
  }
  let nativeResult: NativeFileMetadata = {
    lastModified: result.lastModified,
    lastAccessed: result.lastAccessed
  };
  return nativeResult;
}

// ── Discovery register NAPI wrapper (mTLS-capable) ──

export interface NativeRegisterResult {
  alias: string
  version: string
  deviceModel: string
  deviceType: string
  fingerprint: string
  protocol: string
  certFingerprint: string
}

export async function nativeRegisterDevice(
  targetIp: string,
  targetPort: number,
  ourAlias: string,
  ourFingerprint: string,
  ourProtocol: string,
  ourDeviceModel: string,
  ourDeviceType: string,
  ourPort: number,
  ourIp: string
): Promise<NativeRegisterResult> {
  let resultStr: string = await registerDevice(
    targetIp, targetPort,
    ourAlias, ourFingerprint, ourProtocol,
    ourDeviceModel.length > 0 ? ourDeviceModel : undefined,
    ourDeviceType.length > 0 ? ourDeviceType : undefined,
    ourPort,
    ourIp.length > 0 ? ourIp : undefined
  );
  let data = JSON.parse(resultStr) as Record<string, string>;
  return {
    alias: data['alias'] !== undefined ? data['alias'] : '',
    version: data['version'] !== undefined ? data['version'] : '2.0',
    deviceModel: data['deviceModel'] !== undefined ? data['deviceModel'] : '',
    deviceType: data['deviceType'] !== undefined ? data['deviceType'] : 'desktop',
    fingerprint: data['fingerprint'] !== undefined ? data['fingerprint'] : '',
    protocol: data['protocol'] !== undefined ? data['protocol'] : 'https',
    certFingerprint: data['certFingerprint'] !== undefined ? data['certFingerprint'] : ''
  };
}
