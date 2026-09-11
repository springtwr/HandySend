import {
  init,
  initWithPersistedIdentity,
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
  cancelTransfer,
  cancelLocalSession,
  getCurrentSendSessionId,
  registerRecvFileFd,
  discardRecvFileFds,
  pollDebugLog,
  pollDebugLogWithLevels,
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
  hashFileStreamFd,
  cancelHash,
  hashBuffer,
  failFileDownload,
  failFileUpload,
  uploadFromBuffer,
  registerEventListener as nativeRegisterEventListener,
  nativeMtaStartServer as nativeMtaStartServerFn,
  nativeMtaStopServer as nativeMtaStopServerFn,
  TransferRequest,
  ServerHandle,
  ServerStatus,
  SendResult,
  ShareLinkInfo,
  SecurityContext,
  getSecurityContext,
  resetSecurityContext,
  getNetworkInterfaces,
  NetworkInterfaceInfo
} from 'localsend_ohrs';

import {
  NativeMtaServerConfig,
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
  NativeRegisterResult,
  NativeSecurityContext,
  NativeEvent,
  parseNativeEvent
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

// ════════════════════════════════════════════════════════════
// 类型化事件订阅（Promise 操作 + on/off 类型化订阅）
// ════════════════════════════════════════════════════════════

// 事件处理器表：事件 type → 处理器列表
const nativeEventHandlers: Map<string, Array<(event: NativeEvent) => void>> = new Map();

// NAPI 事件回调是否已注册
let nativeEventListenerRegistered = false;

/**
 * 订阅桥接层事件。
 * @param eventType 事件类型（如 'prepareUpload' / 'sessionEnd' / 'deviceFound'）
 * @param handler 事件处理器，接收类型化事件对象
 */
export function onBridgeEvent(eventType: string, handler: (event: NativeEvent) => void): void {
  let list = nativeEventHandlers.get(eventType);
  if (list === undefined) {
    list = [];
    nativeEventHandlers.set(eventType, list);
  }
  list.push(handler);
  ensureNativeEventListener();
}

/**
 * 取消订阅桥接层事件。
 * @param eventType 事件类型
 * @param handler 之前注册的处理器
 */
export function offBridgeEvent(eventType: string, handler: (event: NativeEvent) => void): void {
  let list = nativeEventHandlers.get(eventType);
  if (list !== undefined) {
    let idx = list.indexOf(handler);
    if (idx >= 0) {
      list.splice(idx, 1);
    }
  }
}

/**
 * 惰性注册 NAPI 事件回调（首次订阅时）。
 * 收到 Rust 事件 JSON（{"type":"...","payload":{...}}）后解析并按类型分发。
 */
function ensureNativeEventListener(): void {
  if (nativeEventListenerRegistered) {
    return;
  }
  nativeEventListenerRegistered = true;
  nativeRegisterEventListener((err: Error | null, eventJson: string) => {
    if (err !== null) {
      console.error('Native event callback error: ' + String(err));
      return;
    }
    dispatchNativeEvent(eventJson);
  });
}

/**
 * 解析并分发一个原生事件 JSON 到订阅者。
 */
function dispatchNativeEvent(eventJson: string): void {
  let event: NativeEvent | undefined = parseNativeEvent(eventJson);
  if (event === undefined) {
    return;
  }
  let list = nativeEventHandlers.get(event.type);
  if (list === undefined) {
    return;
  }
  // 拷贝列表，避免处理器内部订阅/退订影响遍历
  let snapshot: Array<(event: NativeEvent) => void> = [];
  for (let i = 0; i < list.length; i++) {
    snapshot.push(list[i]);
  }
  for (let j = 0; j < snapshot.length; j++) {
    try {
      snapshot[j](event);
    } catch (e) {
      console.error('Native event handler error: ' + String(e));
    }
  }
}

// ════════════════════════════════════════════════════════════
// 一次性操作（Promise）
// ════════════════════════════════════════════════════════════

/**
 * 初始化桥接层：生成/复用 TLS 身份并建立事件通道。
 * 应用启动时调用一次（幂等——重复调用安全，复用已有证书）。
 */
export function nativeInit(alias: string, deviceType: string): void {
  init(alias, deviceType, undefined);
}

/**
 * 使用持久化身份初始化桥接层。
 * 与 nativeInit 等价，但身份从持久化目录加载（跨启动稳定）。
 */
export function nativeInitWithPersistedIdentity(alias: string, deviceType: string,
  persistDir: string): void {
  initWithPersistedIdentity(alias, deviceType, persistDir);
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
  // 必须 await：底层 stopShareServer 返回 Promise（Rust 侧停止+正常模式重启），
  // 丢弃会导致调用方在服务器实际停止前就继续执行，与后续操作竞争端口
  await stopShareServer();
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
  // 底层 respondTransfer 为同步 void，无需 await
  respondTransfer(sessionId, accept, acceptedFileIds);
}

// 预注册接收文件的直写目标 fd（ArkTS 侧在 respondTransfer 前逐文件调用；
// 注册后 fd 所有权移交 Rust，写入完成或会话终态时由 Rust 关闭）
export function nativeRegisterRecvFileFd(sessionId: string, fileId: string, fd: number,
  path: string): void {
  registerRecvFileFd(sessionId, fileId, fd, path);
}

// 丢弃某会话已注册但未开始上传的直写 fd（respond 失败/回滚时调用，由 Rust 关闭）
export function nativeDiscardRecvFileFds(sessionId: string): void {
  discardRecvFileFds(sessionId);
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

// 触发本地 CancellationToken 取消，中断进行中的上传（不向远端发请求）。
export function nativeCancelTransferLocal(sessionId: string): void {
  cancelTransfer(sessionId);
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

/**
 * 带级别的 Rust 日志轮询：元素格式为 `level|message`（首个 `|` 为分隔符）。
 * 供 MTA 链路按原始级别还原展示，替代文本启发式降级。
 */
export function nativePollDebugLogWithLevels(): Array<string> {
  return pollDebugLogWithLevels();
}

// ── 加密 / 安全 NAPI 包装 ──

/**
 * 获取当前生效的安全上下文（私钥/公钥/证书/指纹）。
 */
export function nativeGetSecurityContext(): NativeSecurityContext {
  let ctx: SecurityContext = getSecurityContext();
  let result: NativeSecurityContext = {
    privateKey: ctx.privateKey,
    publicKey: ctx.publicKey,
    certificate: ctx.certificate,
    certificateHash: ctx.certificateHash
  };
  return result;
}

/**
 * 重置安全上下文：重新生成 TLS 证书与密钥并更新全局生效状态。
 */
export function nativeResetSecurityContext(): NativeSecurityContext {
  let ctx: SecurityContext = resetSecurityContext();
  let result: NativeSecurityContext = {
    privateKey: ctx.privateKey,
    publicKey: ctx.publicKey,
    certificate: ctx.certificate,
    certificateHash: ctx.certificateHash
  };
  return result;
}

// ── 文件哈希 NAPI 包装 ──

export async function nativeHashFileStream(path: string, cancelId?: string): Promise<string> {
  return await hashFileStream(path, cancelId);
}

// fd 版流式哈希：fd 由调用方 openSync 打开，计算完成/取消后由 Rust 关闭
export async function nativeHashFileStreamFd(fd: number, cancelId?: string): Promise<string> {
  return await hashFileStreamFd(fd, cancelId);
}

export async function nativeCancelHash(cancelId: string): Promise<void> {
  cancelHash(cancelId);
}

// ── 指纹哈希 NAPI 包装 ──

export function nativeComputeFingerprintHash(combined: string): string {
  return computeFingerprintHash(combined);
}

// ── 文件名工具 NAPI 包装 ──

export function nativeSanitizeFileName(name: string): string {
  return sanitizeFileName(name);
}

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
 * 以完整配置启动发现。
 */
export async function nativeStartDiscoveryV2(config: NativeDiscoveryConfig): Promise<void> {
  await startDiscoveryV2(JSON.stringify(config));
}

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

// ── 网络接口枚举 NAPI 包装 ──

/**
 * 枚举所有非回环 IPv4 网络接口，返回结构化信息。
 * 数据源为 Rust 侧 if_addrs crate，与组播绑定使用的枚举逻辑一致。
 */
export function nativeGetNetworkInterfaces(): Array<NetworkInterfaceInfo> {
  return getNetworkInterfaces();
}

// ── MTA 发送端服务器 NAPI 包装 ──

/**
 * 启动 MTA 发送端 TLS 服务器（含 ZIP 预打包），返回实际绑定端口。
 */
export async function nativeMtaStartServer(config: NativeMtaServerConfig): Promise<number> {
  let resultJson: string = await nativeMtaStartServerFn(JSON.stringify(config));
  let parsed = JSON.parse(resultJson) as Record<string, Object>;
  let portValue = parsed['port'];
  return typeof portValue === 'number' ? portValue : 0;
}

/**
 * 停止 MTA 发送端服务器（幂等；不删除 ZIP 文件，由 ArkTS 清理）。
 */
export async function nativeMtaStopServer(): Promise<void> {
  nativeMtaStopServerFn();
}
