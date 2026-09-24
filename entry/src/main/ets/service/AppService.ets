import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import {
  verifyNativeVersion,
  getNativeLibraryVersion,
  onBridgeEvent,
  nativeGetSecurityContext,
  nativeResetSecurityContext,
  nativeInitWithPersistedIdentity
} from './NativeBridge';
import {
  NativeEvent,
  NativeDeviceFoundEvent,
  NativeRegisterEvent,
  NativePrepareUploadEvent,
  NativeSessionEndEvent,
  NativeCancelReceivedEvent,
  NativePrepareUploadAbortedEvent,
  NativeProgressEvent,
  NativeWebSendPrepareDownloadEvent,
  NativeWebSendFileDownloadEvent,
  NativeWebSendProgressEvent,
  NativeErrorEvent,
  NativeSecurityContext
} from '../model/NativeTypes';
import { ReceiveHistoryEntry, SendSessionState } from '../model/Types';
import { getHistory } from './repository/ReceiveHistoryService';
import { getSendSessions, isTerminalSendStatus } from './repository/SendRepository';
import { getLogger, initLogger, registerAddLog } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { initPendingRequestNotifier } from './PendingRequestNotifier';

// ── 仓库导入（门面编排） ──
import { setAppContext, addLog, triggerRefresh } from './repository/AppCore';
import {
  loadFromPreferences,
  getTheme,
  getLocale,
  applyThemeToApp,
  applyLocaleToApp
} from './repository/SettingsRepository';
import { initDeviceIdentity, getDeviceAlias, getDeviceType } from './repository/DeviceRepository';
import {
  startLocalServer as serverStartLocal,
  stopLocalServer as serverStopLocal,
  refreshWifiWarning,
  isServerRunning,
  restartServer,
  restartDiscovery,
  getReceiveSaveDir
} from './repository/ServerRepository';
import {
  startRequestPolling,
  stopRequestPolling,
  hasActiveTransfers,
  handlePrepareUploadEventTyped,
  handleSessionEndEventTyped,
  handleCancelReceivedEventTyped,
  handlePrepareUploadAbortedEventTyped,
  handleProgressUpdateTyped
} from './repository/ReceiveRepository';
import { handleDeviceFound, handleRegisterEventTyped } from './repository/DiscoveryRepository';
import {
  handlePrepareDownloadTyped,
  handleFileDownloadTyped,
  handleWebSendProgressTyped,
  hasActiveWebDownloads
} from './repository/WebShareRepository';

// ── 协议适配器模块导入（触发模块级自注册；ArkTS 无副作用导入，故引用其键常量） ──
import { LOCAL_SEND_KEY } from './transfer/adapters/LocalSendSendAdapter';
import { LOCAL_RECEIVE_KEY } from './transfer/adapters/LocalSendReceiveAdapter';
import { MTA_SEND_KEY } from './transfer/adapters/MtaSendAdapter';
import { MTA_RECEIVE_KEY } from './transfer/adapters/MtaReceiveAdapter';
import { WEB_DOWNLOAD_KEY } from './transfer/adapters/WebDownloadAdapter';
import { initializeAdapters } from './transfer/adapters/SessionAdapter';
import { registerProtocolDefaults } from './transfer/DefaultRegistrations';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:AppService', '应用');

// 进程级初始化标志：initAppService 由页面 aboutToAppear 调用，进程存活
// 而 Ability 重建（windowStage 重新加载页面）时会再次执行，模块级状态
// 只能初始化一次（事件订阅为追加式、网络监听无法注销）
let appServiceInitialized: boolean = false;
// 网络变化监听实例：进程全程存活，仅作持有以便观测/排查，无注销时机
let netConnection: connection.NetConnection | null = null;

// ════════════════════════════════════════════════════════════
// 门面层再导出（业务逻辑位于 repository/*）
// ════════════════════════════════════════════════════════════

// AppCore —— 共享运行时
export { getLogs,
  clearLogs,
  addLog,
  subscribeLogs,
  unsubscribeLogs,
  subscribe,
  unsubscribe,
  notifyChange,
  triggerRefresh,
  getAppContext,
  getLocalInterfaces,
  updateLocalInterfaces,
  saveLogsToFile } from './repository/AppCore';

// SettingsRepository
export { setHttpsEnabled,
  getHttpsEnabled,
  getEncryptedTransfer,
  setAutoConfirmMode,
  getAutoConfirmMode,
  getReceivePin,
  setReceivePin,
  setAutoFinish,
  isAutoFinish,
  setSaveToHistory,
  isSaveToHistory,
  setSaveToGallery,
  isSaveToGallery,
  setDestination,
  getDestination,
  setCustomAlias,
  getCustomAlias,
  setCustomDeviceType,
  getCustomDeviceType,
  setTheme,
  getTheme,
  setLocale,
  getLocale,
  setHideTabBarOnScroll,
  isHideTabBarOnScroll,
  setCreateChecksums,
  isCreateChecksums,
  setVerifyChecksums,
  isVerifyChecksums,
  setAutoClearStagedAfterSend,
  isAutoClearStagedAfterSend,
  setAdvancedSettings,
  isAdvancedSettings,
  setPort,
  getPort,
  setMulticastGroup,
  getMulticastGroup,
  setDiscoveryTimeout,
  getDiscoveryTimeout,
  setNetworkWhitelist,
  getNetworkWhitelist,
  setNetworkBlacklist,
  getNetworkBlacklist,
  doesServerNeedRestart,
  clearServerNeedsRestart,
  setAutoAcceptWebDownload,
  getAutoAcceptWebDownload,
  getLocalSendEnabled,
  setLocalSendEnabled,
  getMtaEnabled,
  setMtaEnabled,
  getMtaReceiveEnabled,
  setMtaReceiveEnabled,
  getMtaSimulatedBrand,
  setMtaSimulatedBrand,
  isMtaConnectionWarnings,
  setMtaConnectionWarnings } from './repository/SettingsRepository';

// DeviceRepository
export { getDeviceAlias,
  getDeviceType,
  getDeviceModel,
  getLocalDeviceInfo,
  refreshDeviceInfo } from './repository/DeviceRepository';

// ServerRepository
export { isServerRunning,
  getServerError,
  getNoWifiWarning,
  getAllInterfacesDisabled,
  getServerFingerprint,
  startServer,
  stopServer,
  restartServer,
  restartDiscovery,
  cleanupReceiveCacheDirWithContext } from './repository/ServerRepository';

// DiscoveryRepository
export { getDiscoveredDevices,
  getMulticastError,
  rescanDevices,
  isScanningStatus,
  connectByIp } from './repository/DiscoveryRepository';

// WebShareRepository（下方 re-export 仅供外部消费，内部使用走文件顶部 import）
export { getShareLink,
  createShareLink,
  stopShareLink,
  startWebUpload,
  getPendingWebDownloads,
  acceptWebDownloadRequest,
  declineWebDownloadRequest,
  declineAllPendingWebDownloads,
  hasActiveWebDownloads } from './repository/WebShareRepository';

// ChecksumRepository
export { getChecksumProgress, getChecksumTotal, calculateChecksumsForFiles } from './repository/ChecksumRepository';

// SendRepository
export { sendResultErrorMessage,
  sendToDevice,
  sendToDeviceMulti,
  sendToDeviceWithNewSession,
  prepareSendFiles,
  cleanupSendDirWithContext,
  processSharedUris,
  getSendSessions,
  createSendSession,
  clearAllSendSessions,
  setPendingSharedUris,
  consumePendingSharedUris,
  setPendingSharedTexts,
  consumePendingSharedTexts,
  setPrePreparedItems,
  peekPrePreparedItems,
  invalidatePrePreparedItems,
  sendTextDir,
  clearSendTextFiles } from './repository/SendRepository';

export type { SendResult } from './repository/SendRepository';

// ReceiveRepository
export { getPendingRequests,
  respondToRequest,
  shouldAutoAccept,
  peekRecvCompleted,
  consumeRecvCompleted,
  consumeRecvMediaFiles,
  getPendingRecvMediaPaths } from './repository/ReceiveRepository';

// GallerySaveService
export { saveMediaToGallery } from './GallerySaveService';

// NativeBridge（传输取消/会话相关）
export { nativeCancelTransfer,
  nativeCancelTransferLocal,
  nativeCancelLocalSession,
  nativeGetCurrentSendSessionId } from './NativeBridge';

// ReceiveHistoryService
export { updateGallerySavedStatus } from './repository/ReceiveHistoryService';

// MtaRepository —— 应用级 MTA 运行时（发现扫描 / 接收服务 / 收发互斥 / 命令门面）
export { startMtaDiscoveryScan,
  rescanMtaDiscovery,
  stopMtaDiscoveryScan,
  markMtaSendClicked,
  getMtaSendClickedMs,
  getMtaDiscoveredDevices,
  isMtaBluetoothOn,
  isMtaWifiOn,
  startMtaReceiveIfEnabled,
  applyMtaEnabled,
  applyMtaReceiveEnabled,
  stopMtaReceive,
  isMtaSendActive,
  suspendMtaReceiveForSend,
  resumeMtaReceiveAfterSend,
  acceptMtaReceiveRequest,
  acceptMtaReceiveText,
  rejectMtaReceiveRequest,
  cancelMtaReceive,
  subscribeMtaReceiveRequest,
  unsubscribeMtaReceiveRequest,
  getMtaReceiveSnapshot,
  applyMtaSimulatedBrand } from './repository/MtaRepository';

// ── 历史记录 / 收藏（薄适配器） ──

export function getReceiveHistory(): Array<ReceiveHistoryEntry> {
  return getHistory();
}

// ── 统一会话引擎（会话注册表 / 任务历史 / 三类注册表 / 适配器） ──

// 会话注册表（唯一事实源）
export { createSession,
  appendFiles,
  updateFileProgress,
  setStage,
  confirmSession,
  declineSession,
  finish,
  cancel,
  retry,
  getSession,
  findByProtocol,
  querySessions,
  getAllSessions,
  getActiveCount,
  getPendingCount,
  getOverallSnapshot,
  subscribeSessions,
  unsubscribeSessions,
  getHistory,
  clearHistory,
  getSessionCapabilities,
  resetRegistry } from './transfer/TransferSessionRegistry';

// 任务历史存储（抽象接口 + Preferences 实现）
export { getSessionHistory,
  clearSessionHistory,
  resetSessionHistoryCache,
  buildHistoryEntry } from './transfer/SessionHistoryStore';

// 设备来源 / 传输方式 / 设置分组注册表
export { registerSource, getSource, listSources, filterSeenSources } from './transfer/DeviceSourceRegistry';

export { registerMethod, getMethod, listMethods, listMethodsByGroup } from './transfer/TransferMethodRegistry';

export { registerSettingsGroup, listSettingsGroups } from './transfer/SettingsGroupRegistry';

// 协议适配器契约与注册表
export { registerAdapter, getAdapter } from './transfer/adapters/SessionAdapter';

export type { SessionAdapter } from './transfer/adapters/SessionAdapter';

/**
 * 初始化统一会话引擎：建立协议适配器的事件订阅。
 * 幂等性由各适配器自行保证。
 */
function initSessionEngine(): void {
  // 引用各适配器键，确保适配器模块已被加载并完成自注册
  logger.debug('Protocol adapters registered: ' + LOCAL_SEND_KEY + ', ' + LOCAL_RECEIVE_KEY + ', ' +
    MTA_SEND_KEY + ', ' + MTA_RECEIVE_KEY + ', ' + WEB_DOWNLOAD_KEY);
  // 注册协议默认描述符（设备来源 / 传输方式 / 设置分组）
  registerProtocolDefaults();
  initializeAdapters();
}

// ════════════════════════════════════════════════════════════
// 生命周期编排（整合各仓库的关注点）
// ════════════════════════════════════════════════════════════

export function initAppService(context: common.UIAbilityContext): void {
  if (appServiceInitialized) {
    // Ability 重建时 context 实例会变化，仍需刷新以免后续操作使用失效上下文；
    // 其余模块级状态（日志/事件订阅/原生身份/网络监听）进程内只初始化一次
    setAppContext(context);
    logger.debug('initAppService skipped: already initialized');
    return;
  }
  appServiceInitialized = true;

  // 先注册 addLog 回调（打破 Logger → AppCore 的循环依赖）
  registerAddLog(addLog);

  // 初始化日志系统（调试构建 = DEBUG 级别，发布构建 = INFO 级别）
  initLogger();

  // 启动时校验原生库版本
  try {
    verifyNativeVersion();
    logger.debug('Native library version: ' + getNativeLibraryVersion());
  } catch (e) {
    logger.error('Native version check failed: ' + e);
    // 继续执行——版本不匹配只是警告，不是致命错误
  }

  // 注册桥接层类型化事件订阅（发现、服务器、Web 分享事件按类型分发）
  try {
    onBridgeEvent('deviceFound', (e: NativeEvent) => {
      handleDeviceFound(e as NativeDeviceFoundEvent);
    });
    onBridgeEvent('register', (e: NativeEvent) => {
      handleRegisterEventTyped(e as NativeRegisterEvent);
    });
    onBridgeEvent('prepareUpload', (e: NativeEvent) => {
      handlePrepareUploadEventTyped(e as NativePrepareUploadEvent);
    });
    onBridgeEvent('sessionEnd', (e: NativeEvent) => {
      handleSessionEndEventTyped(e as NativeSessionEndEvent);
    });
    onBridgeEvent('cancelReceived', (e: NativeEvent) => {
      handleCancelReceivedEventTyped(e as NativeCancelReceivedEvent);
    });
    onBridgeEvent('uploadProgress', (e: NativeEvent) => {
      handleProgressUpdateTyped(e as NativeProgressEvent);
    });
    onBridgeEvent('prepareUploadAborted', (e: NativeEvent) => {
      // 发送方在我们确认前丢弃了 prepare-upload 请求——
      // 将其作为取消事件呈现，使传输页作出反应。
      handlePrepareUploadAbortedEventTyped(e as NativePrepareUploadAbortedEvent);
    });
    onBridgeEvent('webSendPrepareDownload', (e: NativeEvent) => {
      handlePrepareDownloadTyped(e as NativeWebSendPrepareDownloadEvent);
    });
    onBridgeEvent('webSendFileDownload', (e: NativeEvent) => {
      handleFileDownloadTyped(e as NativeWebSendFileDownloadEvent);
    });
    onBridgeEvent('webSendProgress', (e: NativeEvent) => {
      handleWebSendProgressTyped(e as NativeWebSendProgressEvent);
    });
    onBridgeEvent('error', (e: NativeEvent) => {
      // 原生错误事件此前已解析但未订阅：订阅后纳入发送失败诊断，不再仅依赖调用返回值
      handleNativeErrorEventTyped(e as NativeErrorEvent);
    });
    logger.debug('Native bridge events subscribed');
  } catch (e) {
    logger.error('Failed to subscribe native bridge events: ' + JSON.stringify(e));
  }

  setAppContext(context);
  loadFromPreferences();
  initDeviceIdentity();

  // 初始化统一会话引擎（协议适配器事件订阅；适配器在文件头部导入以完成注册）
  try {
    initSessionEngine();
    // 后台待确认提示通知改为按注册表待确认会话发布/撤回
    initPendingRequestNotifier();
    logger.debug('Session engine initialized');
  } catch (e) {
    logger.error('Failed to initialize session engine: ' + JSON.stringify(e));
  }

  // 初始化桥接层：生成/加载 TLS 身份并建立事件通道（幂等）。
  // 必须显式传入持久化目录（save_dir）：此时 BridgeState.save_dir 尚未设置
  // （createServer 才会写入），且 initialized 置位后 createServer 内的兜底
  // 初始化不会重新加载——若此处不传，identity.pem 永远不会被加载/保存，
  // 指纹将随每次冷启动变化（对方设备的配对/信任识别随之失效）。
  // 显式调用同时保证身份在首次进入 UI 前就已就绪，且事件通道在事件订阅后立即可用。
  try {
    nativeInitWithPersistedIdentity(getDeviceAlias(), getDeviceType(), getReceiveSaveDir());
    logger.debug('Native bridge initialized: alias=' + getDeviceAlias() +
      ' type=' + getDeviceType());
  } catch (e) {
    logger.error('Native bridge init failed: ' + JSON.stringify(e));
  }

  // 立即应用已保存的主题（浅色/深色/跟随系统）
  applyThemeToApp(getTheme());

  // 应用已保存的语言偏好
  applyLocaleToApp(getLocale());

  // 监听网络变化——刷新网卡并通知 UI
  try {
    netConnection = connection.createNetConnection();
    const netConn: connection.NetConnection = netConnection;

    // 网络变化自动扫描的防抖计时器
    let autoScanTimer: number = -1;

    // 辅助：刷新网卡 + 更新 WiFi 警告 + 通知 + 重启发现
    let onNetworkChange = (): void => {
      // 每次网络事件重置 1s 防抖计时器
      if (autoScanTimer >= 0) {
        clearTimeout(autoScanTimer);
      }
      autoScanTimer = setTimeout(() => {
        refreshWifiWarning();
        // 服务器运行中则重启发现（让组播 socket 适配新接口）
        if (isServerRunning()) {
          restartDiscovery();
        }
        autoScanTimer = -1;
      }, 1000);
    };

    netConn.on('netAvailable', () => {
      onNetworkChange();
    });
    netConn.on('netLost', () => {
      onNetworkChange();
    });
    netConn.on('netCapabilitiesChange', () => {
      onNetworkChange();
    });

    netConn.register(() => {
      // 注册时的初始检查
      onNetworkChange();
    });
  } catch (_e) {
    logger.warn('Failed to register network change listener');
  }
}

// ── 原生错误事件诊断 ──

/**
 * 原生错误事件 → 诊断文本（纯函数，无副作用）：结构化输出上下文与消息；
 * 该事件本身不携带会话标识，由调用方在可归属时传入目标会话标识。
 */
export function formatNativeErrorDiagnostic(event: NativeErrorEvent, sessionId: string): string {
  let attribution: string = sessionId.length > 0 ? sessionId : '不可归属';
  return '原生错误 上下文=' + event.context + ' 消息=' + event.message + ' 会话=' + attribution;
}

/** 可归属的发送会话统一标识：恰有一个非终态发送会话时可归属，否则返回空串。 */
function attributableSendSessionId(): string {
  let candidate: string = '';
  let count: number = 0;
  let sessions: Array<SendSessionState> = getSendSessions();
  for (let i = 0; i < sessions.length; i++) {
    if (!isTerminalSendStatus(sessions[i].status)) {
      count++;
      candidate = sessions[i].unifiedSessionId;
    }
  }
  return count === 1 ? candidate : '';
}

/** 原生错误事件处理：纳入发送失败诊断；可归属时关联到当前进行中的发送会话。 */
function handleNativeErrorEventTyped(event: NativeErrorEvent): void {
  logger.error(formatNativeErrorDiagnostic(event, attributableSendSessionId()));
}

// ── 服务器生命周期（整合服务器 + 传输关注点） ──

export async function startLocalServer(): Promise<string> {
  let fingerprint: string = await serverStartLocal();
  startRequestPolling();
  return fingerprint;
}

export async function stopLocalServer(): Promise<void> {
  stopRequestPolling();
  await serverStopLocal();
}

// ── 安全上下文（TLS 证书） ──

// 传输进行中时重置的守卫错误标识（供 ViewModel 区分「忙」与「一般失败」）
const RESET_BUSY_ERROR: string = 'ACTIVE_TRANSFERS';

/**
 * 获取当前生效的安全上下文（证书/公钥/私钥/指纹）。
 */
export function getSecurityContext(): NativeSecurityContext {
  return nativeGetSecurityContext();
}

/**
 * 重置 TLS 证书并持久化。
 * - 存在进行中传输时抛错（不中断文件传输）
 * - 重置成功后若服务器运行中则自动重启，使新证书立即生效
 * - 返回重置后的安全上下文
 */
export async function resetTlsCertificate(): Promise<NativeSecurityContext> {
  // Web 下载不占用统一传输任务，需单独检查：重启服务器会中断其长连接
  if (hasActiveTransfers() || hasActiveWebDownloads()) {
    throw new Error(RESET_BUSY_ERROR);
  }
  let ctx: NativeSecurityContext = nativeResetSecurityContext();
  if (isServerRunning()) {
    await restartServer();
  }
  return ctx;
}

// ── 通知深链信号（进程内一次性） ──

// 待消费的导航目标：通知点击意图由 EntryAbility 解析 want 后置位，主页面消费即清空。
let pendingNavigation: string = '';

/** 置位深链导航信号并触发变更总线（幂等：重复设置同值安全）。 */
export function setPendingNavigation(target: string): void {
  pendingNavigation = target;
  triggerRefresh();
}

/** 只读当前深链信号（不清空）。 */
export function peekPendingNavigation(): string {
  return pendingNavigation;
}

/** 读取并清空深链信号（一次性消费）。 */
export function consumePendingNavigation(): string {
  let target: string = pendingNavigation;
  pendingNavigation = '';
  return target;
}
