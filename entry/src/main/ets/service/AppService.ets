import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { i18n } from '@kit.LocalizationKit';
import { verifyNativeVersion, getNativeLibraryVersion, registerEventListener } from './NativeBridge';
import { NativeEvent, parseNativeEvent, NativeDeviceFoundEvent, NativeDiscoveryUpdateEvent,
  NativeServerRegisterEvent, NativePrepareUploadEvent, NativeSessionEndEvent,
  NativeCancelReceivedEvent, NativeProgressUpdateEvent, NativeWebSendPrepare,
  NativeWebSendFileDownload } from '../model/NativeTypes';
import { FavoriteDevice, ReceiveHistoryEntry } from '../model/Types';
import { getFavorites } from './FavoritesService';
import { getHistory } from './ReceiveHistoryService';
import { getLogger, LogContext, initLogger, registerAddLog } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

// ── Repository imports (facade orchestration) ──
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
  handleCancelReceivedEventTyped, handleProgressUpdateTyped
} from './repository/ReceiveRepository';
import { handleDeviceFound, handleDiscoveryUpdate, handleRegisterEventTyped } from './repository/DiscoveryRepository';
import { handlePrepareDownloadTyped, handleFileDownloadTyped } from './repository/WebShareRepository';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:AppService');

// ════════════════════════════════════════════════════════════
// Facade re-exports (business logic lives in repository/*)
// ════════════════════════════════════════════════════════════

// AppCore — shared runtime
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
export { getPendingRequests, respondToRequest, shouldAutoAccept,
  peekRecvCompleted, consumeRecvCompleted, peekRecvCancelled, consumeRecvCancelled,
  peekRecvText, consumeRecvText } from './repository/ReceiveRepository';

// ── History / favorites (thin adapters) ──

export function getReceiveHistory(): Array<ReceiveHistoryEntry> {
  return getHistory();
}

export function getFavoriteDevices(): Array<FavoriteDevice> {
  return getFavorites();
}

// ════════════════════════════════════════════════════════════
// Lifecycle orchestration (combines repository concerns)
// ════════════════════════════════════════════════════════════

export function initAppService(context: common.UIAbilityContext): void {
  // Register addLog callback first (breaks Logger → AppCore circular dependency)
  registerAddLog(addLog);

  // Initialize Logger system (debug build = DEBUG level, release build = INFO level)
  initLogger();

  // Verify native library version on startup
  try {
    verifyNativeVersion();
    logger.info('Native library version: ' + getNativeLibraryVersion());
  } catch (e) {
    logger.error('Native version check failed: ' + e);
    // Continue anyway - version mismatch is a warning, not a fatal error
  }

  // Register event listener for Rust callback events (discovery, server, etc.)
  try {
    registerEventListener(handleNativeEvent);
    logger.info('Native event listener registered');
  } catch (e) {
    logger.error('Failed to register event listener: ' + JSON.stringify(e));
  }

  setAppContext(context);
  loadFromPreferences();
  initDeviceIdentity();

  // Apply saved theme (light/dark/system) immediately
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

  // Apply saved locale preference
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

  // Monitor network changes — refresh interfaces and notify UI
  try {
    let netConn = connection.createNetConnection();

    // Helper: refresh interfaces + update WiFi warning + notify
    // Delay 500ms to ensure system network state is up-to-date after event
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
      // Initial check on register
      onNetworkChange();
    });
  } catch (_e) {
    logger.warn('Failed to register network change listener');
  }
}

// ── Native event callback handler ──
// All events (discovery + server + web share) arrive here and are dispatched
// to the owning repository.

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
      // Legacy full-list update — should no longer be sent by Rust
      // but keep as fallback for backward compatibility
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

// ── Server lifecycle (combines server + transfer concerns) ──

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
