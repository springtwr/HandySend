import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import {
  verifyNativeVersion,
  getNativeLibraryVersion,
  onBridgeEvent,
  nativeGetSecurityContext,
  nativeResetSecurityContext,
  nativeInit
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
  reloadServerSettings as serverReload,
  refreshWifiWarning,
  isServerRunning,
  restartServer,
  restartDiscovery
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

const logger = getLogger(LogDomains.GENERAL, 'HandySend:AppService');

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
  getAutoAcceptWebDownload } from './repository/SettingsRepository';

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
  restartServerFromSettings,
  restartDiscovery } from './repository/ServerRepository';

// DiscoveryRepository
export { getDiscoveredDevices,
  getMulticastError,
  getDeviceByFingerprint,
  rescanDevices,
  isScanningStatus,
  connectByIp,
  registerToRemoteDevice } from './repository/DiscoveryRepository';

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
export { getChecksumProgress,
  getChecksumTotal,
  calculateChecksumsForFiles,
  cancelChecksumCalculation,
  reportFileDownloadFailure,
  reportFileUploadFailure,
  prepareDownloadFromDevice,
  downloadFileFromDevice,
  uploadBufferToDevice,
  hashBufferSync } from './repository/ChecksumRepository';

// SendRepository
export { sendResultErrorMessage,
  getActiveProgress,
  clearActiveProgress,
  clearSendProgress,
  sendToDevice,
  sendToDeviceMulti,
  prepareSendFiles,
  markSendCompleted,
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
  peekRecvMediaFiles,
  consumeRecvMediaFiles,
  cleanupMediaSandboxFiles,
  isAutoAcceptedSession,
  getAutoAcceptedSessionAlias,
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

// ── 历史记录 / 收藏（薄适配器） ──

export function getReceiveHistory(): Array<ReceiveHistoryEntry> {
  return getHistory();
}

// ════════════════════════════════════════════════════════════
// 生命周期编排（整合各仓库的关注点）
// ════════════════════════════════════════════════════════════

export function initAppService(context: common.UIAbilityContext): void {
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

  // 初始化桥接层：生成/复用 TLS 身份并建立事件通道（幂等）。
  // createServer 内部也会兜底初始化身份，但显式调用保证身份在
  // 首次进入 UI 前就已就绪，且事件通道在事件订阅后立即可用。
  try {
    nativeInit(getDeviceAlias(), getDeviceType());
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
    let netConn = connection.createNetConnection();

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

export async function reloadServerSettings(): Promise<void> {
  if (hasActiveTransfers()) {
    addLog('warn', 'Reload skipped: active transfers in progress');
    return;
  }
  await serverReload();
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
