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
import { wifiManager } from '@kit.ConnectivityKit';
import { DiscoveredDevice, MediaFileInfo } from '../../model/Types';
import { MtaBleClient } from '../mta/MtaBleClient';
import { isBluetoothEnabled } from '../mta/MtaBleCommon';
import { MtaBleClientEventHandlers, MtaDiscoveredDevice, mtaDeviceIdentityKey } from '../../model/mta/MtaSendModels';
import { MtaReceiveService } from '../mta/MtaReceiveService';
import {
  MtaReceiveEventHandlers,
  ReceiverStage,
  ReceiverState,
  isMtaReceivingStage
} from '../../model/mta/MtaProtocolModels';
import { mtaDeviceToDiscoveredDevice } from '../../model/mta/MtaMainModels';
import { notifyChange } from './AppCore';
import { getMtaReceiveEnabled } from './SettingsRepository';
import { getDeviceAlias } from './DeviceRepository';
import { handleMtaReceiveState, setMtaReceiveInvokers } from '../transfer/adapters/MtaReceiveAdapter';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaRepository', '互传');

/** 扫描期间陈旧条目剔除检查间隔（毫秒）：定时剔除超时未再广播的设备 */
const MTA_STALE_PRUNE_INTERVAL_MS: number = 15000;

/** 设备存活时长（毫秒）：超过该时长未再收到广播即视为离线并从列表剔除 */
const MTA_DEVICE_TTL_MS: number = 30000;

/** 扫描失败后的最小重试冷却（毫秒）：冷却期内被动触发的刷新一律不起扫，切断失败自激紧循环 */
const MTA_SCAN_RETRY_COOLDOWN_MS: number = 10000;

// ── 发现扫描状态 ──

let scanClient: MtaBleClient | undefined = undefined;
let scannedDevices: Array<MtaDiscoveredDevice> = [];
let scanning: boolean = false;
// 是否需要扫描（由发送页可见性驱动）：蓝牙临时关闭时保留意图，蓝牙恢复后立即重新起扫
let scanDesired: boolean = false;
// 扫描失败的冷却截止时间戳：当前时间早于该值时，被动触发的刷新不起扫
let scanRetryBlockedUntil: number = 0;
// 陈旧条目剔除定时器 id（扫描期间运行，停止扫描时清理）
let stalePruneTimer: number = -1;
// 上一次已知的蓝牙开关状态：过滤「开启中/关闭中」等中间态的重复事件，仅在状态跃迁时处理
let bluetoothOn: boolean = false;

// ── 接收服务状态 ──

let receiveService: MtaReceiveService | undefined = undefined;
let receiveState: ReceiverState = new ReceiverState();
let receiveRunning: boolean = false;
// 是否希望接收服务运行（前台且开关开启）：蓝牙临时不可用时保留意图，蓝牙恢复后自动重启
let receiveDesired: boolean = false;
let lastReceiveStage: ReceiverStage = ReceiverStage.IDLE;
let receiveRequestCallbacks: Array<() => void> = [];
let appContext: common.Context | undefined = undefined;

// ── 收发互斥状态 ──

// 并发发送逐次 suspend/resume 配对计数：单布尔标志在并发发送时
// 互相覆盖，先结束的发送会把后结束发送的恢复需求清掉，接收服务停摆
let sendActiveCount: number = 0;
// 任一次发送暂停时接收服务在运行，则最后一次 resume 后需要恢复
let resumeReceiveAfterSend: boolean = false;
// 最近一次点击 MTA 设备发起发送的时刻（0 表示未记录）；用于建链耗时端到端计时
let mtaSendClickedMs: number = 0;

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
    logger.debug(detail);
    notifyChange();
  };
  handlers.onBluetoothStateChange = (_stateText: string): void => {
    handleBluetoothStateChange();
  };
  handlers.onError = (source: string, message: string): void => {
    logger.error('发现错误 [' + source + ']: ' + message);
  };
  client.registerEvents(handlers);
  // 记录初始蓝牙状态，供状态跃迁判定使用
  bluetoothOn = isBluetoothEnabled();
  scanClient = client;
  return client;
}

/** 本机接收广播的发送者 ID 十六进制（小写；接收服务未运行时为空串，不参与自身过滤） */
function getLocalReceiveSenderIdHex(): string {
  let service = receiveService;
  if (service === undefined || !receiveRunning) {
    return '';
  }
  return service.getLocalSenderIdHex().trim().toLowerCase();
}

/**
 * 按「设备身份键」去重合并扫描到的 MTA 设备（更新 lastSeen），并通知 UI。
 * 合并前丢弃与本机接收广播身份相同的条目，避免本机出现在自身列表中。
 */
function mergeScannedDevice(device: MtaDiscoveredDevice): void {
  let localSenderId = getLocalReceiveSenderIdHex();
  if (localSenderId.length > 0 && device.senderIdHex.trim().toLowerCase() === localSenderId) {
    logger.debug('发现过滤本机广播: ' + device.bleAddress);
    return;
  }
  device.lastSeen = Date.now();
  let key = mtaDeviceIdentityKey(device);
  let updated: Array<MtaDiscoveredDevice> = [];
  let found = false;
  for (let i = 0; i < scannedDevices.length; i++) {
    if (mtaDeviceIdentityKey(scannedDevices[i]) === key) {
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

/** 剔除超时未再收到广播的陈旧 MTA 条目；返回被剔除的条目数 */
function pruneStaleDevices(): number {
  if (scannedDevices.length === 0) {
    return 0;
  }
  let deadline = Date.now() - MTA_DEVICE_TTL_MS;
  let kept: Array<MtaDiscoveredDevice> = [];
  let removed = 0;
  for (let i = 0; i < scannedDevices.length; i++) {
    if (scannedDevices[i].lastSeen >= deadline) {
      kept.push(scannedDevices[i]);
    } else {
      removed++;
    }
  }
  if (removed > 0) {
    scannedDevices = kept;
  }
  return removed;
}

/** 启动发现扫描（幂等：扫描中或处于失败冷却期时为空操作） */
export function startMtaDiscoveryScan(): void {
  scanDesired = true;
  if (scanning || Date.now() < scanRetryBlockedUntil) {
    return;
  }
  beginScan();
}

/** 用户主动刷新：重置失败冷却并重新收集（已在扫描时清空结果，允许立即重试） */
export function rescanMtaDiscovery(): void {
  scanDesired = true;
  scanRetryBlockedUntil = 0;
  if (scanning) {
    // 已在扫描：清空结果重新收集
    scannedDevices = [];
    notifyChange();
    return;
  }
  beginScan();
}

/** 真正起扫：蓝牙预检 → 剔除陈旧条目 → 启动 BLE 扫描 → 启动周期性陈旧剔除 */
function beginScan(): void {
  let client = ensureScanClient();
  // 蓝牙未开启时不发起原生扫描，仅进入失败冷却并记录一次可读日志
  if (!isBluetoothEnabled()) {
    scanRetryBlockedUntil = Date.now() + MTA_SCAN_RETRY_COOLDOWN_MS;
    scanning = false;
    logger.debug('发现扫描跳过：蓝牙未开启（' + (MTA_SCAN_RETRY_COOLDOWN_MS / 1000) + 's 内不再重试）');
    notifyChange();
    return;
  }
  // 起扫前先剔除已超时的陈旧条目（页面离开期间下线的设备不再出现在列表中）
  pruneStaleDevices();
  scanning = true;
  notifyChange();
  client.startScan().then((): void => {
    // 扫描成功：清除失败冷却，恢复正常即时行为
    scanRetryBlockedUntil = 0;
    logger.debug('发现扫描已启动');
  }).catch((e: Object): void => {
    scanning = false;
    clearStalePruneTimer();
    // 失败后进入冷却，通知引发的刷新不会立即再次起扫
    scanRetryBlockedUntil = Date.now() + MTA_SCAN_RETRY_COOLDOWN_MS;
    logger.error('发现扫描启动失败: ' + String(e));
    notifyChange();
  });
  scheduleStalePrune();
}

/** 安排扫描期间的周期性陈旧条目剔除 */
function scheduleStalePrune(): void {
  clearStalePruneTimer();
  stalePruneTimer = setInterval((): void => {
    let removed = pruneStaleDevices();
    if (removed > 0) {
      logger.debug('发现列表剔除超时设备 ' + removed + ' 台');
      notifyChange();
    }
  }, MTA_STALE_PRUNE_INTERVAL_MS);
}

/** 清除陈旧条目剔除定时器 */
function clearStalePruneTimer(): void {
  if (stalePruneTimer >= 0) {
    clearInterval(stalePruneTimer);
    stalePruneTimer = -1;
  }
}

/** 停止发现扫描（幂等） */
function stopMtaDiscoveryScanInternal(): void {
  clearStalePruneTimer();
  // 先清状态再停扫描：stopScan 的同步回调链（状态通知 → UI 刷新）会读取 scanning，
  // 若后置将观察到停止前的旧状态，扫描可能被重新拉起
  scanning = false;
  let client = scanClient;
  if (client !== undefined) {
    client.stopScan().catch((e: Object): void => {
      logger.error('停止扫描失败: ' + String(e));
    });
  }
  // 停止收尾：剔除已超时的陈旧条目
  pruneStaleDevices();
  notifyChange();
}

/** 停止发现扫描（供发送前让出 BLE 资源）；同时清除扫描意图，避免蓝牙状态变化时被重新拉起 */
export function stopMtaDiscoveryScan(): void {
  scanDesired = false;
  stopMtaDiscoveryScanInternal();
}

/**
 * 蓝牙开关状态变化处理：仅在状态真正跃迁时动作，忽略「开启中/关闭中」等中间态重复事件。
 */
function handleBluetoothStateChange(): void {
  let nowOn = isBluetoothEnabled();
  if (nowOn === bluetoothOn) {
    return;
  }
  bluetoothOn = nowOn;
  if (nowOn) {
    handleBluetoothEnabled();
  } else {
    handleBluetoothDisabled();
  }
}

/** 蓝牙关闭：停止扫描并清空设备列表、复位接收服务，避免残留离线设备与不可重启的死状态 */
function handleBluetoothDisabled(): void {
  // 清空列表与停止扫描置于同一同步块，避免中间被广播事件重新填充
  scannedDevices = [];
  if (scanning) {
    // 停止扫描内部会通知 UI（此时列表已清空）
    stopMtaDiscoveryScanInternal();
  } else {
    notifyChange();
  }
  if (receiveRunning) {
    stopReceiveServiceInternal().catch((e: Object): void => {
      logger.error('蓝牙关闭后停止 MTA 接收服务异常: ' + String(e));
    });
  }
  logger.debug('蓝牙已关闭：停止互传发现扫描并清空设备列表，接收服务复位');
}

/** 蓝牙开启：清除失败冷却后按需恢复发现扫描与接收服务 */
function handleBluetoothEnabled(): void {
  let scanStarted = false;
  if (scanDesired && !scanning) {
    scanRetryBlockedUntil = 0;
    logger.debug('蓝牙已开启：恢复互传发现扫描');
    // beginScan 内部已通知 UI
    beginScan();
    scanStarted = true;
  }
  if (receiveDesired && !receiveRunning) {
    logger.debug('蓝牙已开启：重启 MTA 接收服务');
    startReceiveServiceInternal();
  }
  if (!scanStarted) {
    // 未起扫时补一次通知，确保蓝牙警告横幅即时收起
    notifyChange();
  }
}

/** 本机蓝牙是否已开启（供发送页蓝牙关闭提示） */
export function isMtaBluetoothOn(): boolean {
  // 惰性创建扫描客户端并注册蓝牙开关监听，保证后续开关变化能推送刷新
  ensureScanClient();
  return isBluetoothEnabled();
}

/**
 * 本机 WLAN 开关是否已开启。
 * 互传 P2P 传输依赖 WLAN（有线局域网不算），未开启时设备可被蓝牙发现但无法传输。
 */
export function isMtaWifiOn(): boolean {
  try {
    return wifiManager.isWifiActive();
  } catch (e) {
    // 查询失败时不误报：按已开启处理
    logger.warn('查询 WLAN 开关状态失败: ' + String(e));
    return true;
  }
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
    // 统一会话事实源：把接收阶段翻译为统一会话操作
    handleMtaReceiveState(state);
    notifyChange();
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
      logger.error('接收请求通知异常: ' + String(e));
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
    receiveDesired = false;
    logger.debug('接收开关已关闭，不启动接收服务');
    return;
  }
  receiveDesired = true;
  startReceiveServiceInternal();
}

/** 开关变化后重新按设置启停接收服务（使用已保存的应用上下文） */
export function applyMtaReceiveEnabled(): void {
  if (getMtaReceiveEnabled()) {
    receiveDesired = true;
    startReceiveServiceInternal();
  } else {
    receiveDesired = false;
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
    logger.error('缺少应用上下文，无法启动 MTA 接收服务');
    return;
  }
  let alias = getDeviceAlias();
  if (alias.length === 0) {
    logger.debug('设备昵称尚未就绪，暂不启动 MTA 接收服务');
    return;
  }
  let service = ensureReceiveService();
  service.init(context);
  service.startService(alias).then((): void => {
    receiveRunning = service.getState().serviceRunning;
    notifyChange();
  }).catch((e: Object): void => {
    logger.error('启动 MTA 接收服务异常: ' + String(e));
  });
}

/**
 * 重启流程中刷新 MTA 接收对外身份：以当前昵称重广播并重建 GATT，使昵称变更经「重启」生效。
 * 接收服务未运行时为空操作；失败仅记日志，不影响重启结果。
 */
export function refreshMtaReceiveIdentity(): void {
  let service = receiveService;
  if (service === undefined || !receiveRunning) {
    return;
  }
  service.refreshIdentity(getDeviceAlias()).catch((e: Object): void => {
    logger.error('刷新 MTA 接收对外身份异常: ' + String(e));
  });
}

/**
 * 模拟品牌变更后刷新接收广播身份：复用身份刷新通道触发重广播。
 * 接收服务未运行时为空操作，不影响下一次启动广播。
 */
export function applyMtaSimulatedBrand(): void {
  refreshMtaReceiveIdentity();
}

/** 停止接收服务并释放会话资源（幂等） */
async function stopReceiveServiceInternal(): Promise<void> {
  let service = receiveService;
  if (service === undefined || !receiveRunning) {
    return;
  }
  try {
    await service.stopService();
  } catch (e) {
    // 停止失败也复位运行标志：服务可能已部分停止，
    // 保持「运行中」会使后续启动被幂等守卫拒绝而永远无法再启动
    logger.error('停止 MTA 接收服务异常: ' + String(e));
  }
  receiveRunning = false;
  notifyChange();
}

/** 停止接收服务（应用进入后台或开关关闭时调用）；同时清除接收意图，避免蓝牙状态变化时被重新拉起 */
export function stopMtaReceive(): void {
  receiveDesired = false;
  stopReceiveServiceInternal().catch((e: Object): void => {
    logger.error('停止 MTA 接收服务异常: ' + String(e));
  });
}

// ── 收发互斥 ──

/** 是否存在进行中的 MTA 发送 */
export function isMtaSendActive(): boolean {
  return sendActiveCount > 0;
}

/** 记录点击 MTA 设备发起发送的时刻（发送页点击入口调用） */
export function markMtaSendClicked(): void {
  mtaSendClickedMs = Date.now();
}

/** 取点击 MTA 设备的时刻（未记录时为 0） */
export function getMtaSendClickedMs(): number {
  return mtaSendClickedMs;
}

/** 发起 MTA 发送前暂停接收服务（记录是否需要恢复） */
export async function suspendMtaReceiveForSend(): Promise<void> {
  sendActiveCount++;
  let wasRunning = receiveRunning;
  let suspendStartMs = Date.now();
  if (receiveRunning) {
    resumeReceiveAfterSend = true;
    await stopReceiveServiceInternal();
  }
  // 点击设备后的第一段隐藏耗时：暂停接收服务（停广播/GATT/WS/P2P）本身也占时
  logger.debug(`发送前暂停接收服务耗时=${Date.now() - suspendStartMs}ms 接收服务原状态=${wasRunning}`);
  notifyChange();
}

/** MTA 发送结束（完成/失败/取消）后按开关恢复接收服务 */
export async function resumeMtaReceiveAfterSend(): Promise<void> {
  sendActiveCount = Math.max(0, sendActiveCount - 1);
  // 全部发送结束后才恢复，避免先结束的发送提前拉起接收
  if (sendActiveCount === 0) {
    let shouldResume = resumeReceiveAfterSend;
    resumeReceiveAfterSend = false;
    if (shouldResume && getMtaReceiveEnabled()) {
      startReceiveServiceInternal();
    }
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
    logger.error('接受 MTA 接收请求异常: ' + String(e));
  });
}

/** 以复制方式接受当前文本接收请求（回接受 ack 与成功 status，不进入下载流程） */
export function copyMtaReceiveText(): void {
  let service = receiveService;
  if (service === undefined) {
    return;
  }
  service.acceptTextRequest().catch((e: Object): void => {
    logger.error('复制 MTA 文本接收请求异常: ' + String(e));
  });
}

/** 拒绝当前接收请求 */
export function rejectMtaReceiveRequest(): void {
  let service = receiveService;
  if (service === undefined) {
    return;
  }
  service.rejectRequest().catch((e: Object): void => {
    logger.error('拒绝 MTA 接收请求异常: ' + String(e));
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

/** MTA 接收任务是否进行中（建链/下载/落盘；不含等待用户确认阶段） */
export function isMtaReceivingActive(): boolean {
  return isMtaReceivingStage(receiveState.stage);
}

// 注册 MTA 接收确认/拒绝/取消/复制文本入口与媒体提供器：
// 统一会话命令经适配器回调本仓库门面（含文本消息的复制收尾与相册保存媒体来源）
setMtaReceiveInvokers(
  (): void => {
    acceptMtaReceiveRequest();
  },
  (): void => {
    rejectMtaReceiveRequest();
  },
  (): void => {
    cancelMtaReceive();
  },
  (): void => {
    copyMtaReceiveText();
  },
  (): Array<MediaFileInfo> => {
    return receiveState.pendingMediaFiles.slice();
  }
);
