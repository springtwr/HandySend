import { createServer, stopServer, getServerStatus, pollPendingRequests, respondTransfer, sendFiles, createShareLink, stopShareServer, acceptWebDownload, declineWebDownload, startWebUpload, getRecvDiag, cancelTransferRemote, cancelLocalSession, getCurrentSendSessionId, pollDebugLog, getNativeVersion, getProtocolVersion,
  verifyCert, generateKeyPair, generateSecurityContext, hashFile, sanitizeFileName, isValidFileName, readFileMetadata, computeFingerprintHash, registerDevice,
  startDiscoveryV2, discoveryAnnounce, discoveryDiscoverStaged, discoveryScanSubnet, discoveryAddDevice, discoverySetAnswerAnnouncements, discoveryStop, discoveryGetDevices, discoveryGetDevice, discoveryMulticastError,
  clientInfo, prepareDownload, downloadFile,
  createCancelToken, cancelTokenCancel,
  hashFileStream, hashFileStreamWithToken, cancelHash, hashBuffer,
  failFileDownload, failFileUpload,
  uploadFromBuffer,
  discoveryDeviceLogs,
  enableDebugLogging,
  registerEventListener as nativeRegisterEventListener,
  TransferRequest, ServerHandle, ServerStatus, SendResult, ShareLinkInfo, RecvDiag, KeyPair, SecurityContext, FileMetadataResult,
  createCancellationToken,
  RsCancellationToken,
  RsHttpServer, RsDiscovery, RsHttpClient,
  startServerInstance, startDiscoveryInstance, createClientInstance,
  getLocalDevice as getLocalDeviceJson, getFingerprint, getLocalAddresses, computeFingerprint, verifyFingerprint,
  init, deinit } from 'localsend_ohrs';

import { NativeServerConfig, NativeServerHandle, NativeServerStatus, NativeTargetDevice, NativeTransferRequest, NativeTransferFileInfo, NativeFileToSend, NativeSendResult, NativeHttpError, NativeShareLinkInfo, NativeRecvDiag, NativeCancelTarget, NativeKeyPair, NativeSecurityContext, NativeFileMetadata,
  NativeDiscoveryConfig, NativeDiscoveredDevice, NativeDeviceChannel, NativeCancellationToken, NativeDeviceLog, NativeRegisterResult,
  NativeLocalDeviceInfo, NativePrepareUploadResult
} from '../model/NativeTypes';

import { DeviceChannel, DiscoveredDevice } from '../model/Types';

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

export function nativeDeclineWebDownload(sessionId: string): void {
  declineWebDownload(sessionId);
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

export function nativeEnableDebugLogging(): void {
  enableDebugLogging();
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

export async function nativeHashFileStream(path: string, cancelId?: string): Promise<string> {
  return await hashFileStream(path, cancelId);
}

/**
 * Hash file stream with RsCancellationToken object (object-oriented API).
 * The cancel token object is passed directly instead of using a string ID.
 */
export async function nativeHashFileStreamWithToken(path: string, cancelToken?: RsCancellationToken): Promise<string> {
  return await hashFileStreamWithToken(path, cancelToken);
}

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
export async function nativeDiscoveryAnnounce(): Promise<void> {
  await discoveryAnnounce();
}

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
export function nativeDiscoveryGetDevices(): Array<DiscoveredDevice> {
  let jsonStr: string = discoveryGetDevices();
  let nativeDevices: Array<NativeDiscoveredDevice> = JSON.parse(jsonStr) as Array<NativeDiscoveredDevice>;
  let result: Array<DiscoveredDevice> = [];
  for (let i = 0; i < nativeDevices.length; i++) {
    let d: NativeDiscoveredDevice = nativeDevices[i];
    let channels: Array<DeviceChannel> = [];
    if (d.channels !== undefined) {
      for (let j = 0; j < d.channels.length; j++) {
        let ch: NativeDeviceChannel = d.channels[j];
        channels.push({ host: ch.host, port: ch.port, protocol: ch.protocol });
      }
    }
    result.push({
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
    });
  }
  return result;
}

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
export function nativeDiscoveryDeviceLogs(fingerprint: string): Array<NativeDeviceLog> {
  let jsonStr: string = discoveryDeviceLogs(fingerprint);
  let logs: Array<NativeDeviceLog> = JSON.parse(jsonStr) as Array<NativeDeviceLog>;
  return logs;
}

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

export function nativeCancelTokenCancel(id: string): void {
  cancelTokenCancel(id);
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
export function nativeGetLocalDevice(): NativeLocalDeviceInfo {
  let jsonStr: string = getLocalDeviceJson();
  let data = JSON.parse(jsonStr) as Record<string, Object>;
  return {
    alias: data['alias'] !== undefined ? data['alias'] as string : '',
    fingerprint: data['fingerprint'] !== undefined ? data['fingerprint'] as string : '',
    port: data['port'] !== undefined ? data['port'] as number : 0,
    deviceType: data['deviceType'] !== undefined ? data['deviceType'] as string : 'mobile',
    certPem: data['certPem'] !== undefined ? data['certPem'] as string : ''
  };
}

/**
 * Get the certificate fingerprint.
 */
export function nativeGetFingerprint(): string {
  return getFingerprint();
}

/**
 * Get local IP addresses.
 */
export function nativeGetLocalAddresses(): Array<string> {
  return getLocalAddresses();
}

/**
 * Compute fingerprint from a PEM certificate.
 */
export function nativeComputeFingerprint(certPem: string): string {
  return computeFingerprint(certPem);
}

/**
 * Verify that a certificate fingerprint matches an expected value.
 */
export function nativeVerifyFingerprint(certPem: string, expected: string): boolean {
  return verifyFingerprint(certPem, expected);
}

/**
 * Initialize the native bridge with alias and device type.
 */
export function nativeInit(alias: string, deviceType: string): void {
  init(alias, deviceType);
}

/**
 * Deinitialize the native bridge and release all resources.
 */
export function nativeDeinit(): void {
  deinit();
}

// ── RsCancellationToken (object-oriented API) ──

/**
 * Create a new RsCancellationToken object.
 * The returned object has a `.cancel()` method that can be called to
 * cancel operations that received this token.
 */
export function nativeCreateCancellationToken(): RsCancellationToken {
  return createCancellationToken();
}

// ── RsHttpServer (object-oriented API) ──

/**
 * Start an RsHttpServer instance (object-oriented API).
 * Returns an RsHttpServer object with methods for responding to requests.
 */
export async function nativeStartServerInstance(
  port: number,
  useHttps: boolean,
  verifyChecksums: boolean,
  pin: string | undefined,
  alias: string,
  version: string | undefined,
  deviceModel: string | undefined,
  deviceType: string | undefined,
  fingerprint: string,
  showToken: string | undefined,
  saveDir: string | undefined,
  webSendFiles: string | undefined,
  webPin: string | undefined
): Promise<RsHttpServer> {
  return await startServerInstance(port, useHttps, verifyChecksums,
    pin !== undefined && pin.length > 0 ? pin : undefined,
    alias,
    version !== undefined && version.length > 0 ? version : undefined,
    deviceModel !== undefined && deviceModel.length > 0 ? deviceModel : undefined,
    deviceType !== undefined && deviceType.length > 0 ? deviceType : undefined,
    fingerprint,
    showToken !== undefined && showToken.length > 0 ? showToken : undefined,
    saveDir !== undefined && saveDir.length > 0 ? saveDir : undefined,
    webSendFiles !== undefined && webSendFiles.length > 0 ? webSendFiles : undefined,
    webPin !== undefined && webPin.length > 0 ? webPin : undefined
  );
}

// ── RsDiscovery (object-oriented API) ──

/**
 * Start an RsDiscovery instance (object-oriented API).
 * Returns an RsDiscovery object with methods for discovery operations.
 */
export async function nativeStartDiscoveryInstance(config: NativeDiscoveryConfig): Promise<RsDiscovery> {
  return await startDiscoveryInstance(JSON.stringify(config));
}

// ── RsHttpClient (object-oriented API) ──

/**
 * Create an RsHttpClient instance (object-oriented API).
 * Returns an RsHttpClient object with methods for upload/register/cancel operations.
 */
export function nativeCreateClientInstance(
  privateKey: string,
  cert: string,
  expectedFingerprint: string | undefined,
  timeoutMs: number | undefined,
  alias: string | undefined,
  deviceType: string | undefined,
  deviceModel: string | undefined
): RsHttpClient {
  return createClientInstance(
    privateKey,
    cert,
    expectedFingerprint !== undefined && expectedFingerprint.length > 0 ? expectedFingerprint : undefined,
    timeoutMs,
    alias !== undefined && alias.length > 0 ? alias : undefined,
    deviceType !== undefined && deviceType.length > 0 ? deviceType : undefined,
    deviceModel !== undefined && deviceModel.length > 0 ? deviceModel : undefined
  );
}
