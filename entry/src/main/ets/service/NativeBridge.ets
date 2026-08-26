import {
  createServer,
  stopServer,
  getServerStatus,
  pollPendingRequests,
  respondTransfer,
  sendFiles,
  createShareLink,
  stopShareServer,
  acceptWebDownload,
  declineWebDownload,
  startWebUpload,
  cancelTransferRemote,
  cancelLocalSession,
  getCurrentSendSessionId,
  pollDebugLog,
  getNativeVersion,
  getProtocolVersion,
  sanitizeFileName,
  computeFingerprintHash,
  registerDevice,
  startDiscoveryV2,
  discoveryDiscoverStaged,
  discoveryScanSubnet,
  discoveryAddDevice,
  discoverySetAnswerAnnouncements,
  discoveryStop,
  discoveryGetDevice,
  discoveryMulticastError,
  clientInfo,
  prepareDownload,
  downloadFile,
  createCancelToken,
  hashFileStream,
  cancelHash,
  hashBuffer,
  failFileDownload,
  failFileUpload,
  uploadFromBuffer,
  registerEventListener as nativeRegisterEventListener,
  TransferRequest,
  ServerHandle,
  ServerStatus,
  SendResult,
  ShareLinkInfo,
  RsCancellationToken,
  RsHttpServer,
  RsDiscovery,
  RsHttpClient,
  getNetworkInterfaces,
  NetworkInterfaceInfo
} from 'localsend_ohrs';

import {
  NativeServerConfig,
  NativeServerHandle,
  NativeServerStatus,
  NativeTargetDevice,
  NativeTransferRequest,
  NativeTransferFileInfo,
  NativeFileToSend,
  NativeSendResult,
  NativeHttpError,
  NativeShareLinkInfo,
  NativeCancelTarget,
  NativeDiscoveryConfig,
  NativeDiscoveredDevice,
  NativeDeviceChannel,
  NativeCancellationToken,
  NativeRegisterResult
} from '../model/NativeTypes';

import { DeviceChannel, DiscoveredDevice } from '../model/Types';

// 期望的原生库版本（必须与 Cargo.toml 和 oh-package.json5 一致）
const EXPECTED_NATIVE_VERSION = '1.18.1';

/**
 * 校验原生库版本与期望版本一致。
 * 在应用初始化期间调用。
 * @throws 版本不匹配时抛出 Error
 */
export function verifyNativeVersion(): void {
  const actualVersion = getNativeVersion();
  if (actualVersion !== EXPECTED_NATIVE_VERSION) {
    throw new Error(`Native library version mismatch: expected ${EXPECTED_NATIVE_VERSION}, got ${actualVersion}`);
  }
}

/**
 * 获取原生库版本（用于展示/日志）
 */
export function getNativeLibraryVersion(): string {
  return getNativeVersion();
}

/**
 * 获取 LocalSend 协议版本（例如 "2.2"）
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

export async function nativeCreateShareLink(files: Array<NativeFileToSend>,
  alias: string): Promise<NativeShareLinkInfo> {
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

export async function nativeRespondTransfer(sessionId: string, accept: boolean,
  acceptedFileIds: Array<string> = []): Promise<void> {
  await respondTransfer(sessionId, accept, acceptedFileIds);
}

export async function nativeSendFiles(target: NativeTargetDevice, senderAlias: string,
  files: Array<NativeFileToSend>): Promise<NativeSendResult> {
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
  cancelLocalSession(sessionId);
}

export function nativeGetCurrentSendSessionId(): string {
  return getCurrentSendSessionId();
}

export function nativePollDebugLog(): Array<string> {
  return pollDebugLog();
}


// ── 加密 / 安全 NAPI 包装 ──

/**
 * 用公钥验证证书。
 * 验证成功返回 true，失败返回 false。
 * 仅在意外内部错误时抛出（输入格式错误等）。
 */


// ── 文件哈希 NAPI 包装 ──


export async function nativeHashFileStream(path: string, cancelId?: string): Promise<string> {
  return await hashFileStream(path, cancelId);
}

/**
 * 使用 RsCancellationToken 对象对文件流进行哈希（面向对象 API）。
 * 直接传递取消令牌对象，而非使用字符串 ID。
 */

export async function nativeCancelHash(cancelId: string): Promise<void> {
  cancelHash(cancelId);
}

// ── 支持取消的上传 ──

// 注意：此处不直接暴露 nativeUploadFile，因为上传由
// 通过 nativeSendFiles。cancelId 参数在 Rust 侧可用
// 以便在需要时直接调用 upload_file。

// ── 指纹哈希 NAPI 包装 ──

export function nativeComputeFingerprintHash(combined: string): string {
  return computeFingerprintHash(combined);
}

// ── 文件名工具 NAPI 包装 ──

export function nativeSanitizeFileName(name: string): string {
  return sanitizeFileName(name);
}


// ── 文件元数据 NAPI 包装 ──


// ── 发现注册 NAPI 包装（支持 mTLS） ──

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

// ── 发现 v2 NAPI 包装 ──

/**
 * 以完整配置启动发现（取代旧的 DiscoveryService.startDiscovery）。
 */
export async function nativeStartDiscoveryV2(config: NativeDiscoveryConfig): Promise<void> {
  await startDiscoveryV2(JSON.stringify(config));
}

/**
 * 向网络发送一组广播报文。
 */

/**
 * 分阶段发现设备：广播 → 探测已知通道 → 等待宽限期 → 回退子网扫描。
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
 * 扫描指定网卡的 /24 子网。
 */
export async function nativeDiscoveryScanSubnet(
  interfaceIp: string,
  port: number,
  protocol: string
): Promise<void> {
  await discoveryScanSubnet(interfaceIp, port, protocol);
}

/**
 * 将发现流程之外确认的设备（例如来自服务器注册事件）加入存储。
 */
export async function nativeDiscoveryAddDevice(device: NativeDiscoveredDevice): Promise<void> {
  await discoveryAddDevice(JSON.stringify(device));
}

/**
 * 设置是否应答其他设备的广播。
 */
export function nativeDiscoverySetAnswerAnnouncements(answer: boolean): void {
  discoverySetAnswerAnnouncements(answer);
}

/**
 * 停止发现并释放所有套接字。
 */
export function nativeDiscoveryStop(): void {
  discoveryStop();
}

/**
 * 以 JSON 字符串获取所有已发现的设备，解析为 DiscoveredDevice 数组。
 */

/**
 * 按指纹获取单个设备。
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
 * 获取组播错误（若有）。
 */
export function nativeDiscoveryMulticastError(): string {
  return discoveryMulticastError();
}

/**
 * 按指纹获取设备确认日志。
 */

// ── 客户端信息 NAPI 包装 ──

export async function nativeClientInfo(protocol: string, ip: string, port: number): Promise<string> {
  return await clientInfo(protocol, ip, port);
}

// ── 取消令牌 NAPI 包装 ──

export function nativeCreateCancelToken(): NativeCancellationToken {
  let id: string = createCancelToken();
  let result: NativeCancellationToken = { id: id };
  return result;
}


// ── 失败文件下载/上传 NAPI 包装 ──

export function nativeFailFileDownload(sessionId: string, fileId: string): void {
  failFileDownload(sessionId, fileId);
}

export function nativeFailFileUpload(sessionId: string, fileId: string): void {
  failFileUpload(sessionId, fileId);
}

// ── 事件监听器注册 ──

/**
 * 注册一个回调，用于接收来自 Rust 原生层的事件。
 * 事件以 JSON 字符串形式传递，应按类型分发。
 */
export function registerEventListener(callback: (err: Error | null, eventJson: string) => void): void {
  nativeRegisterEventListener(callback);
}

// ── Download API NAPI 包装 ──

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

// ── 工具函数桥接（US5） ──

/**
 * 以结构化对象获取本地设备信息。
 */

/**
 * 获取证书指纹。
 */

/**
 * 获取本地 IP 地址。
 */

/**
 * 从 PEM 证书计算指纹。
 */

/**
 * 校验证书指纹与期望值匹配。
 */

/**
 * 使用别名和设备类型初始化原生桥接。
 */

/**
 * 反初始化原生桥接并释放所有资源。
 */

// ── RsCancellationToken（面向对象 API） ──

/**
 * 创建一个新的 RsCancellationToken 对象。
 * 返回的对象带有 `.cancel()` 方法，可调用以
 * 取消使用该令牌的操作。
 */

// ── RsHttpServer（面向对象 API） ──

/**
 * 启动一个 RsHttpServer 实例（面向对象 API）。
 * 返回一个 RsHttpServer 对象，包含响应请求的方法。
 */

// ── RsDiscovery（面向对象 API） ──

/**
 * 启动一个 RsDiscovery 实例（面向对象 API）。
 * 返回一个 RsDiscovery 对象，包含发现操作的方法。
 */

// ── RsHttpClient（面向对象 API） ──

/**
 * 创建一个 RsHttpClient 实例（面向对象 API）。
 * 返回一个 RsHttpClient 对象，包含上传/注册/取消操作的方法。
 */

// ── 网络接口枚举 NAPI 包装 ──

/**
 * 枚举所有非回环 IPv4 网络接口，返回结构化信息。
 * 数据源为 Rust 侧 if_addrs crate，与组播绑定使用的枚举逻辑一致。
 */
export function nativeGetNetworkInterfaces(): Array<NetworkInterfaceInfo> {
  return getNetworkInterfaces();
}
