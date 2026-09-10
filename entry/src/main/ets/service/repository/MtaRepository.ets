/**
 * MtaRepository.ets — 应用级 MTA 运行时仓储
 *
 * 汇聚主流程所需的 MTA 关注点：
 * - 发现扫描：持有一个仅用于扫描的 MtaBleClient 实例（每轮一次性、非常驻），
 *   把发现的 MTA 设备按 BLE 标识去重合并，供发送页并入统一设备列表；
 * - 接收服务单例：持有 MtaReceiveService，按「互传联盟接收」设置与应用前后台
 *   生命周期启停（前台自动运行，后台停止）；
 * - 事件总线：把接收请求到达与状态快照转成订阅通知，供页面导航与渲染；
 * - 命令门面：accept/reject/cancel 转发给接收服务；
 * - 收发互斥：维护全局「发送进行中」标志，发送期间暂停接收服务，发送结束后恢复。
 *
 * UI 侧变化统一经 AppCore.notifyChange() 通知（与其它仓储一致）。
 */

import { common } from '@kit.AbilityKit';
import { DiscoveredDevice } from '../../model/Types';
import { MtaBleClient } from '../mta/MtaBleClient';
import { MtaBleClientEventHandlers, MtaDiscoveredDevice } from '../../model/mta/MtaSendModels';
import { MtaReceiveService } from '../mta/MtaReceiveService';
import { MtaReceiveEventHandlers, ReceiverLogEntry, ReceiverStage, ReceiverState } from '../../model/mta/MtaReceiveModels';
import { mtaDeviceToDiscoveredDevice } from '../../model/mta/MtaMainModels';
import { notifyChange } from './AppCore';
import { getMtaReceiveEnabled } from './SettingsRepository';
import { getDeviceAlias } from './DeviceRepository';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.NETWORK, 'HandySend:MtaRepository');

/** 单轮 MTA 发现扫描时长（毫秒；一轮结束后自动停止，非常驻） */
const MTA_SCAN_DURATION_MS: number = 15000;

/** 扫描失败后的最小重试冷却（毫秒）：冷却期内被动触发的刷新一律不起扫，切断失败自激紧循环 */
const MTA_SCAN_RETRY_COOLDOWN_MS: number = 10000;

// ── 发现扫描状态 ──

let scanClient: MtaBleClient | undefined = undefined;
let scannedDevices: Array<MtaDiscoveredDevice> = [];
let scanning: boolean = false;
// 一轮扫描自动结束后置位：周期性的 UI 刷新不再重新起扫，仅用户主动刷新重置
let scanSuppressed: boolean = false;
// 扫描失败的冷却截止时间戳：当前时间早于该值时，被动触发的刷新不起扫
let scanRetryBlockedUntil: number = 0;
let scanStopTimer: number = -1;

// ── 接收服务状态 ──

let receiveService: MtaReceiveService | undefined = undefined;
let receiveState: ReceiverState = new ReceiverState();
let receiveRunning: boolean = false;
let lastReceiveStage: ReceiverStage = ReceiverStage.IDLE;
let receiveRequestCallbacks: Array<() => void> = [];
let appContext: common.Context | undefined = undefined;

// ── 收发互斥状态 ──

let sendActive: boolean = false;
let resumeReceiveAfterSend: boolean = false;

// ── 发现扫描 ──

/** 惰性创建发现扫描客户端并绑定事件 */
function ensureScanClient(): MtaBleClient {
  if (scanClient !== undefined) {
    return scanClient;
  }
  let client = new MtaBleClient();
  let handlers = new MtaBleClientEventHandlers();
  handlers.onDeviceFound = (device: MtaDiscoveredDevice): void => {
    mergeScannedDevice(device);
  };
  handlers.onScanStateChange = (value: boolean, detail: string): void => {
    scanning = value;
    logger.debug('MTA 扫描状态: ' + detail);
    notifyChange();
  };
  handlers.onError = (source: string, message: string): void => {
    logger.warn('MTA 发现错误 [' + source + ']: ' + message);
  };
  client.registerEvents(handlers);
  scanClient = client;
  return client;
}

/** 按 BLE 地址去重合并扫描到的 MTA 设备，并通知 UI */
function mergeScannedDevice(device: MtaDiscoveredDevice): void {
  let updated: Array<MtaDiscoveredDevice> = [];
  let found = false;
  for (let i = 0; i < scannedDevices.length; i++) {
    if (scannedDevices[i].bleAddress === device.bleAddress) {
      updated.push(device);
      found = true;
    } else {
      updated.push(scannedDevices[i]);
    }
  }
  if (!found) {
    updated.push(device);
  }
  scannedDevices = updated;
  notifyChange();
}

/** 启动一轮发现扫描（幂等：扫描中、已被抑制或处于失败冷却期时为空操作） */
export function startMtaDiscoveryScan(): void {
  if (scanning || scanSuppressed || Date.now() < scanRetryBlockedUntil) {
    return;
  }
  beginScan();
}

/** 用户主动刷新：重置抑制与失败冷却标记并启动一轮新的发现扫描（允许立即重试） */
export function rescanMtaDiscovery(): void {
  scanSuppressed = false;
  scanRetryBlockedUntil = 0;
  if (scanning) {
    // 已在扫描：清空结果并重置本轮计时
    scannedDevices = [];
    scheduleScanStop();
    notifyChange();
    return;
  }
  beginScan();
}

/** 真正起扫：蓝牙预检 → 清空结果 → 启动 BLE 扫描 → 安排本轮自动停止 */
function beginScan(): void {
  let client = ensureScanClient();
  // 蓝牙未开启时不发起原生扫描，仅进入失败冷却并记录一次可读日志
  if (!client.isBluetoothOn()) {
    scanRetryBlockedUntil = Date.now() + MTA_SCAN_RETRY_COOLDOWN_MS;
    scanning = false;
    logger.warn('MTA 发现扫描跳过：蓝牙未开启（' + (MTA_SCAN_RETRY_COOLDOWN_MS / 1000) + 's 内不再重试）');
    notifyChange();
    return;
  }
  scannedDevices = [];
  scanning = true;
  notifyChange();
  client.startScan().then((): void => {
    // 扫描成功：清除失败冷却，恢复正常即时行为
    scanRetryBlockedUntil = 0;
    logger.debug('MTA 发现扫描已启动');
  }).catch((e: Object): void => {
    scanning = false;
    // 失败后进入冷却，通知引发的刷新不会立即再次起扫
    scanRetryBlockedUntil = Date.now() + MTA_SCAN_RETRY_COOLDOWN_MS;
    logger.warn('MTA 发现扫描启动失败: ' + String(e));
    notifyChange();
  });
  scheduleScanStop();
}

/** 安排本轮扫描在时长上限后自动停止 */
function scheduleScanStop(): void {
  clearScanStopTimer();
  scanStopTimer = setTimeout((): void => {
    scanStopTimer = -1;
    stopMtaDiscoveryScanInternal(true);
  }, MTA_SCAN_DURATION_MS);
}

/** 清除扫描自动停止定时器 */
function clearScanStopTimer(): void {
  if (scanStopTimer >= 0) {
    clearTimeout(scanStopTimer);
    scanStopTimer = -1;
  }
}

/** 停止发现扫描（幂等）；suppress 为 true 时抑制后续周期性自动起扫 */
function stopMtaDiscoveryScanInternal(suppress: boolean): void {
  clearScanStopTimer();
  let client = scanClient;
  if (client !== undefined && scanning) {
    client.stopScan().catch((e: Object): void => {
      logger.warn('MTA 停止扫描失败: ' + String(e));
    });
  }
  scanning = false;
  if (suppress) {
    scanSuppressed = true;
  }
  notifyChange();
}

/** 停止发现扫描（供发送前让出 BLE 资源） */
export function stopMtaDiscoveryScan(): void {
  stopMtaDiscoveryScanInternal(false);
}

/** 当前发现的 MTA 设备（映射为统一设备形状） */
export function getMtaDiscoveredDevices(): Array<DiscoveredDevice> {
  let now = Date.now();
  let result: Array<DiscoveredDevice> = [];
  for (let i = 0; i < scannedDevices.length; i++) {
    result.push(mtaDeviceToDiscoveredDevice(scannedDevices[i], now));
  }
  return result;
}

/** 是否正在扫描 */
export function isMtaScanning(): boolean {
  return scanning;
}

// ── 接收服务 ──

/** 惰性创建接收服务并绑定事件 */
function ensureReceiveService(): MtaReceiveService {
  if (receiveService !== undefined) {
    return receiveService;
  }
  let service = new MtaReceiveService();
  let handlers = new MtaReceiveEventHandlers();
  handlers.onStateChange = (state: ReceiverState): void => {
    receiveState = state;
    receiveRunning = state.serviceRunning;
    if (state.stage === ReceiverStage.REQUEST_RECEIVED && lastReceiveStage !== ReceiverStage.REQUEST_RECEIVED) {
      notifyReceiveRequest();
    }
    lastReceiveStage = state.stage;
    notifyChange();
  };
  handlers.onLog = (entry: ReceiverLogEntry): void => {
    logger.debug('MTA 接收 [' + entry.source + '] ' + entry.content);
  };
  service.setEventHandlers(handlers);
  receiveService = service;
  return service;
}

/** 通知订阅者：收到新的接收请求 */
function notifyReceiveRequest(): void {
  let callbacks = receiveRequestCallbacks.slice();
  for (let i = 0; i < callbacks.length; i++) {
    try {
      callbacks[i]();
    } catch (e) {
      logger.warn('MTA 接收请求通知异常: ' + String(e));
    }
  }
}

/**
 * 应用进入前台时按开关启动接收服务。
 * 开关关闭时不启动；已运行时幂等返回。
 */
export function startMtaReceiveIfEnabled(context: common.Context): void {
  appContext = context;
  if (!getMtaReceiveEnabled()) {
    logger.debug('MTA 接收开关已关闭，不启动接收服务');
    return;
  }
  startReceiveServiceInternal();
}

/** 开关变化后重新按设置启停接收服务（使用已保存的应用上下文） */
export function applyMtaReceiveEnabled(): void {
  if (getMtaReceiveEnabled()) {
    startReceiveServiceInternal();
  } else {
    stopReceiveServiceInternal();
  }
}

/** 启动接收服务（幂等） */
function startReceiveServiceInternal(): void {
  if (receiveRunning) {
    return;
  }
  let context = appContext;
  if (context === undefined) {
    logger.warn('缺少应用上下文，无法启动 MTA 接收服务');
    return;
  }
  let service = ensureReceiveService();
  service.init(context);
  let name = getDeviceAlias();
  service.startService(name.length > 0 ? name : 'HandySend').then((): void => {
    receiveRunning = service.getState().serviceRunning;
    notifyChange();
  }).catch((e: Object): void => {
    logger.warn('启动 MTA 接收服务异常: ' + String(e));
  });
}

/** 停止接收服务并释放会话资源（幂等） */
async function stopReceiveServiceInternal(): Promise<void> {
  let service = receiveService;
  if (service === undefined || !receiveRunning) {
    return;
  }
  await service.stopService();
  receiveRunning = false;
  notifyChange();
}

/** 停止接收服务（应用进入后台或开关关闭时调用） */
export function stopMtaReceive(): void {
  stopReceiveServiceInternal().catch((e: Object): void => {
    logger.warn('停止 MTA 接收服务异常: ' + String(e));
  });
}

/** 接收服务是否运行中 */
export function isMtaReceiveRunning(): boolean {
  return receiveRunning;
}

// ── 收发互斥 ──

/** 是否存在进行中的 MTA 发送 */
export function isMtaSendActive(): boolean {
  return sendActive;
}

/** 设置全局 MTA 发送占用标志 */
export function setMtaSendActive(active: boolean): void {
  sendActive = active;
  notifyChange();
}

/** 发起 MTA 发送前暂停接收服务（记录是否需要恢复） */
export async function suspendMtaReceiveForSend(): Promise<void> {
  sendActive = true;
  resumeReceiveAfterSend = receiveRunning;
  if (receiveRunning) {
    await stopReceiveServiceInternal();
  }
  notifyChange();
}

/** MTA 发送结束（完成/失败/取消）后按开关恢复接收服务 */
export async function resumeMtaReceiveAfterSend(): Promise<void> {
  sendActive = false;
  let shouldResume = resumeReceiveAfterSend;
  resumeReceiveAfterSend = false;
  if (shouldResume && getMtaReceiveEnabled()) {
    startReceiveServiceInternal();
  }
  notifyChange();
}

// ── 接收命令门面 ──

/** 接受当前接收请求 */
export function acceptMtaReceiveRequest(): void {
  let service = receiveService;
  if (service === undefined) {
    return;
  }
  service.acceptRequest().catch((e: Object): void => {
    logger.warn('接受 MTA 接收请求异常: ' + String(e));
  });
}

/** 拒绝当前接收请求 */
export function rejectMtaReceiveRequest(): void {
  let service = receiveService;
  if (service === undefined) {
    return;
  }
  service.rejectRequest().catch((e: Object): void => {
    logger.warn('拒绝 MTA 接收请求异常: ' + String(e));
  });
}

/** 取消当前 MTA 接收下载 */
export function cancelMtaReceive(): void {
  let service = receiveService;
  if (service === undefined) {
    return;
  }
  service.cancelDownload();
}

// ── 接收事件订阅与快照 ──

/** 订阅「收到新的接收请求」通知（用于导航到 MTA 传输页） */
export function subscribeMtaReceiveRequest(callback: () => void): void {
  if (receiveRequestCallbacks.indexOf(callback) < 0) {
    receiveRequestCallbacks.push(callback);
  }
}

/** 取消订阅「收到新的接收请求」通知 */
export function unsubscribeMtaReceiveRequest(callback: () => void): void {
  let updated: Array<() => void> = [];
  for (let i = 0; i < receiveRequestCallbacks.length; i++) {
    if (receiveRequestCallbacks[i] !== callback) {
      updated.push(receiveRequestCallbacks[i]);
    }
  }
  receiveRequestCallbacks = updated;
}

/** 当前接收状态快照 */
export function getMtaReceiveSnapshot(): ReceiverState {
  return receiveState;
}
