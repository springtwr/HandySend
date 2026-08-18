import { createServer, stopServer, getServerStatus, pollPendingRequests, respondTransfer, sendFiles, createShareLink, stopShareServer, acceptWebDownload, startWebUpload, cancelTransferRemote, cancelLocalSession, getCurrentSendSessionId, pollDebugLog, getNativeVersion, getProtocolVersion, sanitizeFileName, computeFingerprintHash, registerDevice, startDiscoveryV2, discoveryDiscoverStaged, discoveryScanSubnet, discoveryAddDevice, discoverySetAnswerAnnouncements, discoveryStop, discoveryGetDevice, discoveryMulticastError, clientInfo, prepareDownload, downloadFile, createCancelToken, hashFileStream, cancelHash, hashBuffer, failFileDownload, failFileUpload, uploadFromBuffer, registerEventListener as nativeRegisterEventListener, TransferRequest, ServerHandle, ServerStatus, SendResult, ShareLinkInfo, RsCancellationToken, RsHttpServer, RsDiscovery, RsHttpClient} from 'localsend_ohrs';

import { NativeServerConfig, NativeServerHandle, NativeServerStatus, NativeTargetDevice, NativeTransferRequest, NativeTransferFileInfo, NativeFileToSend, NativeSendResult, NativeHttpError, NativeShareLinkInfo, NativeCancelTarget, NativeDiscoveryConfig, NativeDiscoveredDevice, NativeDeviceChannel, NativeCancellationToken, NativeRegisterResult} from '../model/NativeTypes';

import { DeviceChannel, DiscoveredDevice} from '../model/Types';

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

export function nativeAcceptWebDownload(sessionId: string): void {
  acceptWebDownload(sessionId);
}


export async function nativeStartWebUpload(): Promise<number> {
  return await startWebUpload();
}

export async function nativeRespondTransfer(sessionId: string, accept: boolean, acceptedFileIds: Array<string> = []): Promise<void> {
  await respondTransfer(sessionId, accept, acceptedFileIds);
}

export async function nativeSendFiles(target: NativeTargetDevice, senderAlias: string, files: Array<NativeFileToSend>): Promise<NativeSendResult> {
  let result: SendResult = await sendFiles(JSON.stringify(target), senderAlias, JSON.stringify(files));
  let httpError: NativeHttpError | undefined = undefined;
  if (result.error !== undefined && result.error !== null) {
    let e = result.error;
    httpError = {
      kind: e.kind,
      status: e.status,
      message: e.message
    };
  }
  let nativeResult: NativeSendResult = {
    sessionId: result.sessionId,
    success: result.success,
    failedFiles: result.failedFiles,
    error: httpError
  };
  return nativeResult;
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



// ── File hash NAPI wrapper ──


export async function nativeHashFileStream(path: string, cancelId?: string): Promise<string> {
  return await hashFileStream(path, cancelId);
}

/**
 * Hash file stream with RsCancellationToken object (object-oriented API).
 * The cancel token object is passed directly instead of using a string ID.
 */

export async function nativeCancelHash(cancelId: string): Promise<void> {
  await cancelHash(cancelId);
}

// ── Upload with cancel support ──

// Note: nativeUploadFile is not directly exposed here because upload is handled
// through nativeSendFiles. The cancelId parameter is available on the Rust side
// for direct upload_file calls when needed.

// ── Fingerprint hash NAPI wrapper ──

export function nativeComputeFingerprintHash(combined: string): string {
  return computeFingerprintHash(combined);
}

// ── File name utilities NAPI wrappers ──

export function nativeSanitizeFileName(name: string): string {
  return sanitizeFileName(name);
}


// ── File metadata NAPI wrapper ──


// ── Discovery register NAPI wrapper (mTLS-capable) ──

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
    certFingerprint: data['certFingerprint'] !== undefined ? data['certFingerprint'] : '',
    publicKey: data['publicKey'] !== undefined ? data['publicKey'] : ''
  };
}

// ── Discovery v2 NAPI wrappers ──

/**
 * Start discovery with full configuration (replaces old DiscoveryService.startDiscovery).
 */
export async function nativeStartDiscoveryV2(config: NativeDiscoveryConfig): Promise<void> {
  await startDiscoveryV2(JSON.stringify(config));
}

/**
 * Send an announcement burst to the network.
 */

/**
 * Discover devices in stages: announce → probe known channels → wait grace period → fallback subnet scan.
 */
export async function nativeDiscoveryDiscoverStaged(
  channels: Array<NativeDeviceChannel>,
  interfaceIps: Array<string>,
  port: number,
  protocol: string,
  graceMs: number
): Promise<void> {
  await discoveryDiscoverStaged(JSON.stringify(channels), JSON.stringify(interfaceIps), port, protocol, graceMs);
}

/**
 * Scan the /24 subnet of a specific interface.
 */
export async function nativeDiscoveryScanSubnet(
  interfaceIp: string,
  port: number,
  protocol: string
): Promise<void> {
  await discoveryScanSubnet(interfaceIp, port, protocol);
}

/**
 * Add a device confirmed outside of discovery (e.g. from server register event) into the store.
 */
export async function nativeDiscoveryAddDevice(device: NativeDiscoveredDevice): Promise<void> {
  await discoveryAddDevice(JSON.stringify(device));
}

/**
 * Set whether to answer announcements of other devices.
 */
export function nativeDiscoverySetAnswerAnnouncements(answer: boolean): void {
  discoverySetAnswerAnnouncements(answer);
}

/**
 * Stop discovery and release all sockets.
 */
export function nativeDiscoveryStop(): void {
  discoveryStop();
}

/**
 * Get all discovered devices as JSON string, parsed into DiscoveredDevice array.
 */

/**
 * Get a single device by fingerprint.
 */
export function nativeDiscoveryGetDevice(fingerprint: string): DiscoveredDevice | undefined {
  let jsonStr: string = discoveryGetDevice(fingerprint);
  if (jsonStr === 'null') {
    return undefined;
  }
  let d: NativeDiscoveredDevice = JSON.parse(jsonStr) as NativeDiscoveredDevice;
  let channels: Array<DeviceChannel> = [];
  if (d.channels !== undefined) {
    for (let j = 0; j < d.channels.length; j++) {
      let ch: NativeDeviceChannel = d.channels[j];
      channels.push({ host: ch.host, port: ch.port, protocol: ch.protocol });
    }
  }
  let result: DiscoveredDevice = {
    alias: d.alias,
    ip: d.host,
    port: d.port,
    fingerprint: d.fingerprint,
    version: d.version,
    deviceModel: d.deviceModel !== undefined ? d.deviceModel : '',
    deviceType: d.deviceType !== undefined ? d.deviceType : 'mobile',
    protocol: d.protocol,
    lastSeen: Date.now(),
    channels: channels
  };
  return result;
}

/**
 * Get the multicast error, if any.
 */
export function nativeDiscoveryMulticastError(): string {
  return discoveryMulticastError();
}

/**
 * Get device confirmation logs by fingerprint.
 */

// ── Client Info NAPI wrapper ──

export async function nativeClientInfo(protocol: string, ip: string, port: number): Promise<string> {
  return await clientInfo(protocol, ip, port);
}

// ── Cancel Token NAPI wrappers ──

export function nativeCreateCancelToken(): NativeCancellationToken {
  let id: string = createCancelToken();
  let result: NativeCancellationToken = { id: id };
  return result;
}


// ── Fail file download/upload NAPI wrappers ──

export function nativeFailFileDownload(sessionId: string, fileId: string): void {
  failFileDownload(sessionId, fileId);
}

export function nativeFailFileUpload(sessionId: string, fileId: string): void {
  failFileUpload(sessionId, fileId);
}

// ── Event Listener Registration ──

/**
 * Register a callback to receive events from the Rust native layer.
 * Events are delivered as JSON strings and should be dispatched by type.
 */
export function registerEventListener(callback: (err: Error | null, eventJson: string) => void): void {
  nativeRegisterEventListener(callback);
}

// ── Download API NAPI wrappers ──

export async function nativePrepareDownload(
  targetIp: string,
  port: number,
  protocol: string,
  sessionId?: string,
  pin?: string
): Promise<string> {
  return await prepareDownload(targetIp, port, protocol, sessionId, pin);
}

export async function nativeDownloadFile(
  targetIp: string,
  port: number,
  protocol: string,
  sessionId: string,
  fileId: string,
  savePath: string,
  publicKey?: string
): Promise<number> {
  let bytes: number = await downloadFile(targetIp, port, protocol, sessionId, fileId, savePath, publicKey);
  return bytes;
}

export async function nativeUploadFromBuffer(
  targetIp: string,
  port: number,
  protocol: string,
  sessionId: string,
  fileId: string,
  token: string,
  buffer: ArrayBuffer,
  publicKey?: string,
  cancelId?: string
): Promise<void> {
  await uploadFromBuffer(targetIp, port, protocol, sessionId, fileId, token, buffer, publicKey, cancelId);
}

export function nativeHashBuffer(buffer: ArrayBuffer): string {
  return hashBuffer(buffer);
}

// ── Utility Function Bridging (US5) ──

/**
 * Get local device info as a structured object.
 */

/**
 * Get the certificate fingerprint.
 */

/**
 * Get local IP addresses.
 */

/**
 * Compute fingerprint from a PEM certificate.
 */

/**
 * Verify that a certificate fingerprint matches an expected value.
 */

/**
 * Initialize the native bridge with alias and device type.
 */

/**
 * Deinitialize the native bridge and release all resources.
 */

// ── RsCancellationToken (object-oriented API) ──

/**
 * Create a new RsCancellationToken object.
 * The returned object has a `.cancel()` method that can be called to
 * cancel operations that received this token.
 */

// ── RsHttpServer (object-oriented API) ──

/**
 * Start an RsHttpServer instance (object-oriented API).
 * Returns an RsHttpServer object with methods for responding to requests.
 */

// ── RsDiscovery (object-oriented API) ──

/**
 * Start an RsDiscovery instance (object-oriented API).
 * Returns an RsDiscovery object with methods for discovery operations.
 */

// ── RsHttpClient (object-oriented API) ──

/**
 * Create an RsHttpClient instance (object-oriented API).
 * Returns an RsHttpClient object with methods for upload/register/cancel operations.
 */
