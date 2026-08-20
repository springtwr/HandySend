import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { i18n } from '@kit.LocalizationKit';
import { verifyNativeVersion, getNativeLibraryVersion, registerEventListener } from './NativeBridge';
import { NativeEvent, parseNativeEvent, NativeDeviceFoundEvent, NativeDiscoveryUpdateEvent,
  NativeServerRegisterEvent, NativePrepareUploadEvent, NativeSessionEndEvent,
  NativeCancelReceivedEvent, NativePrepareUploadAbortedEvent, NativeProgressUpdateEvent,
  NativeWebSendPrepare, NativeWebSendFileDownload } from '../model/NativeTypes';
import { FavoriteDevice, ReceiveHistoryEntry } from '../model/Types';
import { getFavorites } from './FavoritesService';
import { getHistory } from './ReceiveHistoryService';
import { getLogger, LogContext, initLogger, registerAddLog } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

// ── 仓库导入（门面编排） ──
import { setAppContext, addLog } from './repository/AppCore';
import { loadFromPreferences, getTheme, getLocale } from './repository/SettingsRepository';
import { initDeviceIdentity } from './repository/DeviceRepository';
import {
  startLocalServer as serverStartLocal, stopLocalServer as serverStopLocal,
  reloadServerSettings as serverReload, refreshWifiWarning
} from './repository/ServerRepository';
import {
  startRequestPolling, stopRequestPolling, hasActiveTransfers,
  handlePrepareUploadEventTyped, handleSessionEndEventTyped,
  handleCancelReceivedEventTyped, handlePrepareUploadAbortedEventTyped,
  handleProgressUpdateTyped
} from './repository/ReceiveRepository';
import { handleDeviceFound, handleDiscoveryUpdate, handleRegisterEventTyped } from './repository/DiscoveryRepository';
import { handlePrepareDownloadTyped, handleFileDownloadTyped } from './repository/WebShareRepository';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:AppService');

// ════════════════════════════════════════════════════════════
// 门面层再导出（业务逻辑位于 repository/*）
// ════════════════════════════════════════════════════════════

// AppCore —— 共享运行时
export { getLogs, subscribe, unsubscribe, triggerRefresh, getLocalInterfaces } from './repository/AppCore';

// SettingsRepository
export { setHttpsEnabled, getHttpsEnabled, getEncryptedTransfer,
  setQuickSaveMode, getAutoSaveMode, getReceivePin, setReceivePin,
  setAutoFinish, isAutoFinish, setSaveToHistory, isSaveToHistory,
  setSaveToGallery, isSaveToGallery, setDestination, getDestination,
  setTheme, getTheme, setLocale, getLocale,
  setEnableAnimations, isEnableAnimations,
  setCreateChecksums, isCreateChecksums, setVerifyChecksums, isVerifyChecksums,
  setSendMode, getSendMode, setAdvancedSettings, isAdvancedSettings,
  setShareViaLinkAutoAccept, getShareViaLinkAutoAccept,
  setReceiveViaLinkAutoAccept, getReceiveViaLinkAutoAccept,
  setPort, getPort, setMulticastGroup, getMulticastGroup,
  setDiscoveryTimeout, getDiscoveryTimeout,
  setNetworkWhitelist, getNetworkWhitelist, setNetworkBlacklist, getNetworkBlacklist,
  doesServerNeedRestart, clearServerNeedsRestart,
  getHideShareByLink, getSilentReceive } from './repository/SettingsRepository';

// DeviceRepository
export { getDeviceAlias, getDeviceType, getDeviceModel, getLocalDeviceInfo, refreshDeviceInfo } from './repository/DeviceRepository';

// ServerRepository
export { isServerRunning, getServerError, getNoWifiWarning, getServerFingerprint,
  startServer, stopServer, restartServer, restartServerFromSettings } from './repository/ServerRepository';

// DiscoveryRepository
export { getDiscoveredDevices, getMulticastError, getDeviceByFingerprint,
  rescanDevices, connectByIp, registerToRemoteDevice } from './repository/DiscoveryRepository';

// WebShareRepository
export { getShareLink, getSharePort, createShareLink, stopShareLink, startWebUpload } from './repository/WebShareRepository';

// ChecksumRepository
export { getChecksumProgress, getChecksumTotal, calculateChecksumsForFiles,
  cancelChecksumCalculation, reportFileDownloadFailure, reportFileUploadFailure,
  prepareDownloadFromDevice, downloadFileFromDevice, uploadBufferToDevice, hashBufferSync } from './repository/ChecksumRepository';

// SendRepository
export { sendResultErrorMessage, getActiveProgress, clearActiveProgress, clearSendProgress,
  sendToDevice, sendToDeviceMulti, prepareSendFiles,
  markSendCompleted, isSendCompletedAndReset, processSharedUris,
  getSendSessions, createSendSession, clearAllSendSessions,
  setPendingSharedUris, consumePendingSharedUris } from './repository/SendRepository';
export type { SendResult } from './repository/SendRepository';

// ReceiveRepository
export { getPendingRequests, respondToRequest, shouldAutoAccept, removePendingRequest,
  peekRecvCompleted, consumeRecvCompleted, peekRecvCancelled, consumeRecvCancelled,
  peekRecvText, consumeRecvText, isAutoAcceptedSession, getAutoAcceptedSessionAlias } from './repository/ReceiveRepository';

// ── 历史记录 / 收藏（薄适配器） ──

export function getReceiveHistory(): Array<ReceiveHistoryEntry> {
  return getHistory();
}

export function getFavoriteDevices(): Array<FavoriteDevice> {
  return getFavorites();
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
    logger.info('Native library version: ' + getNativeLibraryVersion());
  } catch (e) {
    logger.error('Native version check failed: ' + e);
    // 继续执行——版本不匹配只是警告，不是致命错误
  }

  // 注册 Rust 回调事件监听器（发现、服务器等）
  try {
    registerEventListener(handleNativeEvent);
    logger.info('Native event listener registered');
  } catch (e) {
    logger.error('Failed to register event listener: ' + JSON.stringify(e));
  }

  setAppContext(context);
  loadFromPreferences();
  initDeviceIdentity();

  // 立即应用已保存的主题（浅色/深色/跟随系统）
  try {
    let theme = getTheme();
    if (context) {
      let appCtx = context.getApplicationContext();
      if (theme === 'light') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (theme === 'dark') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    }
  } catch (_e) {
    logger.warn('initAppService: applyColorMode failed');
  }

  // 应用已保存的语言偏好
  try {
    let locale = getLocale();
    if (locale === 'system' || locale === '') {
      let sysLang = i18n.System.getSystemLanguage();
      i18n.System.setAppPreferredLanguage(sysLang);
    } else if (locale === 'zh') {
      i18n.System.setAppPreferredLanguage('zh-Hans');
    } else if (locale === 'zh-TW') {
      i18n.System.setAppPreferredLanguage('zh-Hant');
    } else if (locale === 'en') {
      i18n.System.setAppPreferredLanguage('en-US');
    } else if (locale !== '') {
      i18n.System.setAppPreferredLanguage(locale);
    }
  } catch (_e) {
    logger.warn('setAppPreferredLanguage failed during init');
  }

  // 监听网络变化——刷新网卡并通知 UI
  try {
    let netConn = connection.createNetConnection();

    // 辅助：刷新网卡 + 更新 WiFi 警告 + 通知
    // 延迟 500ms，确保事件后系统网络状态已更新
    let onNetworkChange = (): void => {
      setTimeout(() => {
        refreshWifiWarning();
      }, 500);
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

// ── 原生事件回调处理器 ──
// 所有事件（发现 + 服务器 + Web 分享）都汇集到这里并分发
// 交给其所属仓库。

export function handleNativeEvent(err: Error | null, eventJson: string): void {
  if (err !== null) {
    logger.error('callback error: ' + String(err));
    return;
  }
  let event: NativeEvent | undefined = parseNativeEvent(eventJson);
  if (event === undefined) {
    logger.warn('unparseable event: ' + eventJson.substring(0, 200));
    return;
  }

  switch (event.type) {
    case 'device_found':
      handleDeviceFound(event as NativeDeviceFoundEvent);
      break;
    case 'discovery_update':
      // 旧的整表更新——Rust 不应再发送
      // 但保留作为向后兼容的回退
      handleDiscoveryUpdate(event as NativeDiscoveryUpdateEvent);
      break;
    case 'register':
      handleRegisterEventTyped(event as NativeServerRegisterEvent);
      break;
    case 'prepare_upload':
      handlePrepareUploadEventTyped(event as NativePrepareUploadEvent);
      break;
    case 'file_upload':
      break;
    case 'session_end':
      handleSessionEndEventTyped(event as NativeSessionEndEvent);
      break;
    case 'cancel_received':
      handleCancelReceivedEventTyped(event as NativeCancelReceivedEvent);
      break;
    case 'progress_update':
      handleProgressUpdateTyped(event as NativeProgressUpdateEvent);
      break;
    case 'prepare_upload_aborted':
      // 发送方在我们确认前丢弃了 prepare-upload 请求——
      // 将其作为取消事件呈现，使传输页作出反应。
      handlePrepareUploadAbortedEventTyped(event as NativePrepareUploadAbortedEvent);
      break;
    case 'web_prepare_download':
      handlePrepareDownloadTyped(event as NativeWebSendPrepare);
      break;
    case 'web_file_download':
      handleFileDownloadTyped(event as NativeWebSendFileDownload);
      break;
    case 'upload_finished':
      logger.info('Event: upload_finished sessionId=' + (event.sessionId ?? '').substring(0, 8));
      break;
    case 'upload_failed':
      logger.warn('Event: upload_failed sessionId=' + (event.sessionId ?? '').substring(0, 8));
      break;
    case 'hash_progress':
      logger.debug('Event: hash_progress cancelId=' + (event.cancelId ?? '') + ' bytes=' + String(event.bytes));
      break;
    case 'hash_done':
      logger.info('Event: hash_done cancelId=' + (event.cancelId ?? ''));
      break;
    case 'hash_cancelled':
      logger.info('Event: hash_cancelled cancelId=' + (event.cancelId ?? ''));
      break;
    case 'hash_error':
      logger.error('Event: hash_error cancelId=' + (event.cancelId ?? '') + ' error=' + (event.error ?? ''));
      break;
    case 'show':
      logger.info('Event: show');
      break;
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
