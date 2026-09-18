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
  NativeSecurityContext
} from '../model/NativeTypes';
import { ReceiveHistoryEntry } from '../model/Types';
import { getHistory } from './repository/ReceiveHistoryService';
import { getLogger, initLogger, registerAddLog } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

// ── 仓库导入（门面编排） ──
import { setAppContext, addLog } from './repository/AppCore';
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
import { handlePrepareDownloadTyped, handleFileDownloadTyped } from './repository/WebShareRepository';

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
  subscribe,
  unsubscribe,
  triggerRefresh,
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
  setEnableAnimations,
  isEnableAnimations,
  setHideTabBarOnScroll,
  isHideTabBarOnScroll,
  setCreateChecksums,
  isCreateChecksums,
  setVerifyChecksums,
  isVerifyChecksums,
  setSendMode,
  getSendMode,
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

// WebShareRepository
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
  getActiveProgress,
  clearActiveProgress,
  clearSendProgress,
  removeProgressForSession,
  sendToDevice,
  sendToDeviceMulti,
  prepareSendFiles,
  markSendCompleted,
  cleanupSendDirWithContext,
  isSendCompletedAndReset,
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
  consumePrePreparedItems,
  invalidatePrePreparedItems } from './repository/SendRepository';

export type { SendResult } from './repository/SendRepository';

// ReceiveRepository
export { getPendingRequests,
  respondToRequest,
  shouldAutoAccept,
  removePendingRequest,
  peekRecvCompleted,
  consumeRecvCompleted,
  peekRecvCancelled,
  consumeRecvCancelled,
  peekRecvFailed,
  consumeRecvFailed,
  peekRecvText,
  consumeRecvText,
  consumeRecvMediaFiles,
  cleanupMediaSandboxFiles,
  isRecvSessionCancelled,
  isRecvSessionFailed } from './repository/ReceiveRepository';

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
  applyMtaReceiveEnabled,
  stopMtaReceive,
  isMtaSendActive,
  suspendMtaReceiveForSend,
  resumeMtaReceiveAfterSend,
  acceptMtaReceiveRequest,
  copyMtaReceiveText,
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
    logger.debug('Native bridge events subscribed');
  } catch (e) {
    logger.error('Failed to subscribe native bridge events: ' + JSON.stringify(e));
  }

  setAppContext(context);
  loadFromPreferences();
  initDeviceIdentity();

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
  if (hasActiveTransfers()) {
    throw new Error(RESET_BUSY_ERROR);
  }
  let ctx: NativeSecurityContext = nativeResetSecurityContext();
  if (isServerRunning()) {
    await restartServer();
  }
  return ctx;
}
