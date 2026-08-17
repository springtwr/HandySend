import { nativeCreateServer, nativeStopServer, nativeGetServerStatus,
  nativePollPendingRequests,
  nativeRespondTransfer, nativeSendFiles,
  nativeCreateShareLink, nativeStopShareServer,
  nativeAcceptWebDownload, nativeDeclineWebDownload, nativeStartWebUpload,
  nativePollDebugLog, verifyNativeVersion, getNativeLibraryVersion,
  nativeHashFile, nativeHashFileStream, nativeCancelHash,
  nativeSanitizeFileName, nativeIsValidFileName,
  nativeStartDiscoveryV2, nativeDiscoveryAnnounce, nativeDiscoveryDiscoverStaged,
  nativeDiscoveryScanSubnet, nativeDiscoveryAddDevice, nativeDiscoverySetAnswerAnnouncements,
  nativeDiscoveryStop, nativeDiscoveryGetDevices, nativeDiscoveryGetDevice,
  nativeDiscoveryMulticastError,
  nativeClientInfo, nativeRegisterDevice,
  nativeCreateCancelToken, nativeCancelTokenCancel,
  nativeFailFileDownload, nativeFailFileUpload,
  nativePrepareDownload, nativeDownloadFile,
  nativeUploadFromBuffer, nativeHashBuffer,
  registerEventListener
} from './NativeBridge';
import { DiscoveredDevice, PendingRequest, PendingRequestFile,
  TransferProgress, SendFileItem, LogEntry, LocalDeviceInfo, StagedFile,
  QuickSaveMode, SendSessionStatus, SendMode,
  FavoriteDevice, ReceiveHistoryEntry, SendSessionState,
  NetworkInterface, NetworkType, DeviceChannel
} from '../model/Types';
import { NativeTargetDevice, NativeFileToSend, NativeServerHandle,
  NativeDiscoveryConfig, NativeDeviceChannel, NativeDiscoveredDevice, NativeRegisterResult, NativeHttpError,
  NativeEvent, parseNativeEvent,
  NativeServerRegisterEvent, NativePrepareUploadEvent, NativeProgressUpdateEvent,
  NativeWebSendPrepare, NativeWebSendFileDownload,
  NativeDiscoveryUpdateEvent, NativeDeviceFoundEvent, NativeRegisterInfo, NativeTransferFileInfo,
  NativeSessionEndEvent, NativeCancelReceivedEvent } from '../model/NativeTypes';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { connection } from '@kit.NetworkKit';
import { i18n } from '@kit.LocalizationKit';
import { preferencesUtil, KEY_ENCRYPTED_TRANSFER, KEY_AUTO_SAVE_MODE, KEY_RECEIVE_PIN, KEY_AUTO_FINISH,
  KEY_SAVE_TO_HISTORY, KEY_SAVE_TO_GALLERY, KEY_DESTINATION,   KEY_THEME,
  KEY_LOCALE, KEY_ENABLE_ANIMATIONS,
  KEY_CREATE_CHECKSUMS, KEY_VERIFY_CHECKSUMS, KEY_SEND_MODE,
  KEY_ADVANCED_SETTINGS, KEY_SHARE_VIA_LINK_AUTO_ACCEPT,
  KEY_RECEIVE_VIA_LINK_AUTO_ACCEPT, KEY_PORT, KEY_MULTICAST_GROUP,
  KEY_DISCOVERY_TIMEOUT, KEY_NETWORK_WHITELIST, KEY_NETWORK_BLACKLIST,
  KEY_FAVORITE_DEVICES, KEY_RECEIVE_HISTORY, KEY_HIDE_SHARE_BY_LINK, KEY_SILENT_RECEIVE,
  APP_KEY_SERVER_READY, APP_KEY_SERVER_NEEDS_RESTART, APP_KEY_SERVER_ERROR,
  APP_KEY_CHECKSUM_PROGRESS, APP_KEY_CHECKSUM_TOTAL,
  APP_KEY_RECV_TRANSFER_COMPLETED, APP_KEY_RECV_TRANSFER_CANCELLED,
  APP_KEY_RECV_TEXT_MESSAGE, APP_KEY_WEB_DOWNLOAD_REQUEST,
  APP_KEY_ACTIVE_PROGRESS_COUNT, APP_KEY_NO_WIFI_WARNING,
  APP_PREFIX_RECV_SESSION_AUTO_ACCEPTED, APP_PREFIX_RECV_AUTO_FINISH,
  APP_PREFIX_RECV_OFFER_OPEN_FILE, APP_PREFIX_SEND_PIN_REQUIRED } from '../utils/PreferencesUtil';
import {
  getFavorites, syncAliasFromDiscovery
} from './FavoritesService';
import { getHistory, addEntry as addHistoryEntry } from './ReceiveHistoryService';
import {
  getMimeForExt as mimeGetMimeForExt, getMimeForFileName as mimeGetMimeForFileName } from '../utils/MimeUtils';
import { generateAlias } from '../utils/AliasGenerator';

const TAG = 'LocalSend:AppService';
const DOMAIN = 0x0001;

const DEFAULT_PORT = 53317;
const DEVICE_EXPIRY_MS = 120000;

// 发送结果接口
export interface SendResult {
  success: boolean;
  error?: NativeHttpError;
}

export function sendResultErrorMessage(err: NativeHttpError | undefined): string {
  if (err === undefined) {
    return '';
  }
  if (err.message !== undefined && err.message.length > 0) {
    return err.message;
  }
  if (err.status !== undefined) {
    return 'HTTP ' + err.status;
  }
  return err.kind;
}

let appContext: common.UIAbilityContext | undefined = undefined;
let serverRunning = false;
let serverFingerprint = '';
let httpsEnabled = true;
let shareLinkInfo: string = '';
let sharePort: number = 0;
let localInterfaces: Array<NetworkInterface> = [];  // 所有本地网卡
let discoveredDevices: Array<DiscoveredDevice> = [];
let pendingRequests: Array<PendingRequest> = [];
let activeProgress: Array<TransferProgress> = [];
let logs: Array<LogEntry> = [];
let requestPollTimer: number | undefined = undefined;
let alias = '';
let deviceModel = '';
let deviceType = 'mobile';
let changeCallbacks: Array<() => void> = [];
let requestDoNotDisturb: Array<string> = [];
let isReloading = false;
let pendingSendCompleted = false;

export interface ReceivedFileEntry {
  sessionId: string
  fileId: string
  filePath: string
  fileName: string
  fileType: string
}

let sessionTotalFiles: Record<string, number> = {};
let sessionCompletedCount: Record<string, number> = {};
let sessionExported: Record<string, boolean> = {};
let sessionFileMap: Record<string, Array<ReceivedFileEntry>> = {};
let completedFileIds: Record<string, boolean> = {};
let completedFileCount: number = 0;
let sessionCleanupCount: number = 0;

// ── New state variables for feature alignment ──
let quickSaveMode: QuickSaveMode = QuickSaveMode.paired;
let receivePin: string = '';
let autoFinish: boolean = false;
let saveToHistory: boolean = true;
let saveToGallery: boolean = true;
let destination: string = '';
let theme: string = 'system';
let locale: string = '';
let enableAnimations: boolean = true;
let createChecksums: boolean = true;
let verifyChecksums: boolean = true;
let sendMode: SendMode = SendMode.single;
let advancedSettings: boolean = false;
let shareViaLinkAutoAccept: boolean = false;
let receiveViaLinkAutoAccept: boolean = false;
let port: number = DEFAULT_PORT;
let multicastGroup: string = '224.0.0.167';
let discoveryTimeout: number = 3000;
let serverNeedsRestart: boolean = false;
let sendSessions: Map<string, SendSessionState> = new Map();
let checksumProgress: number = 0;
let checksumTotal: number = 0;
let appServiceInitialized: boolean = false;

export function initAppService(context: common.UIAbilityContext): void {
  if (appServiceInitialized) {
    hilog.warn(DOMAIN, TAG, 'initAppService called again — skipping duplicate init');
    return;
  }
  appServiceInitialized = true;
  // Verify native library version on startup
  try {
    verifyNativeVersion();
    hilog.info(0x0000, 'AppService', `Native library version: ${getNativeLibraryVersion()}`);
  } catch (e) {
    hilog.error(0x0000, 'AppService', `Native version check failed: ${e}`);
    // Continue anyway - version mismatch is a warning, not a fatal error
  }

  // Register event listener for Rust callback events (discovery, server, etc.)
  try {
    registerEventListener(handleNativeEvent);
    hilog.info(DOMAIN, TAG, 'Native event listener registered');
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'Failed to register event listener: %{public}s', JSON.stringify(e));
  }
  
  appContext = context;
  httpsEnabled = preferencesUtil.getBoolean(KEY_ENCRYPTED_TRANSFER, true);
  AppStorage.setOrCreate('encryptedTransfer', httpsEnabled);
  hilog.info(DOMAIN, TAG, '[DBG-HTTPS] initAppService: read encryptedTransfer=%{public}s (default=true)', httpsEnabled.toString());

  // Load all new settings from Preferences into module-level variables and AppStorage
  let savedQuickSave: string = preferencesUtil.getString(KEY_AUTO_SAVE_MODE, 'paired');
  quickSaveMode = (savedQuickSave === 'off' || savedQuickSave === 'paired' || savedQuickSave === 'on') ?
    savedQuickSave as QuickSaveMode : QuickSaveMode.paired;

  receivePin = preferencesUtil.getString(KEY_RECEIVE_PIN, '');
  autoFinish = preferencesUtil.getBoolean(KEY_AUTO_FINISH, false);
  saveToHistory = preferencesUtil.getBoolean(KEY_SAVE_TO_HISTORY, true);
  saveToGallery = preferencesUtil.getBoolean(KEY_SAVE_TO_GALLERY, true);
  destination = preferencesUtil.getString(KEY_DESTINATION, '');
  theme = preferencesUtil.getString(KEY_THEME, 'system');
  locale = preferencesUtil.getString(KEY_LOCALE, '');
  enableAnimations = preferencesUtil.getBoolean(KEY_ENABLE_ANIMATIONS, true);
  createChecksums = preferencesUtil.getBoolean(KEY_CREATE_CHECKSUMS, true);
  verifyChecksums = preferencesUtil.getBoolean(KEY_VERIFY_CHECKSUMS, true);
  let savedSendMode: string = preferencesUtil.getString(KEY_SEND_MODE, 'single');
  sendMode = (savedSendMode === 'single' || savedSendMode === 'multiple' || savedSendMode === 'link')
    ? savedSendMode as SendMode : SendMode.single;
  // If persisted mode is 'link' but link sharing is hidden, fall back to 'single'
  if (sendMode === SendMode.link && preferencesUtil.getBoolean(KEY_HIDE_SHARE_BY_LINK, false)) {
    sendMode = SendMode.single;
    preferencesUtil.setString(KEY_SEND_MODE, SendMode.single);
  }
  advancedSettings = preferencesUtil.getBoolean(KEY_ADVANCED_SETTINGS, false);
  shareViaLinkAutoAccept = preferencesUtil.getBoolean(KEY_SHARE_VIA_LINK_AUTO_ACCEPT, false);
  receiveViaLinkAutoAccept = preferencesUtil.getBoolean(KEY_RECEIVE_VIA_LINK_AUTO_ACCEPT, false);
  port = preferencesUtil.getNumber(KEY_PORT, DEFAULT_PORT);
  multicastGroup = preferencesUtil.getString(KEY_MULTICAST_GROUP, '224.0.0.167');
  discoveryTimeout = preferencesUtil.getNumber(KEY_DISCOVERY_TIMEOUT, 3000);

  // Initialize AppStorage with loaded values
  AppStorage.setOrCreate(KEY_AUTO_SAVE_MODE, quickSaveMode);
  AppStorage.setOrCreate(KEY_RECEIVE_PIN, receivePin);
  AppStorage.setOrCreate(KEY_AUTO_FINISH, autoFinish);
  AppStorage.setOrCreate(KEY_SAVE_TO_HISTORY, saveToHistory);
  AppStorage.setOrCreate(KEY_SAVE_TO_GALLERY, saveToGallery);
  AppStorage.setOrCreate(KEY_DESTINATION, destination);
  AppStorage.setOrCreate(KEY_THEME, theme);
  AppStorage.setOrCreate(KEY_LOCALE, locale);
  AppStorage.setOrCreate(KEY_ENABLE_ANIMATIONS, enableAnimations);
  AppStorage.setOrCreate(KEY_CREATE_CHECKSUMS, createChecksums);
  AppStorage.setOrCreate(KEY_VERIFY_CHECKSUMS, verifyChecksums);
  AppStorage.setOrCreate(KEY_SEND_MODE, String(sendMode));
  AppStorage.setOrCreate(KEY_ADVANCED_SETTINGS, advancedSettings);
  AppStorage.setOrCreate(KEY_SHARE_VIA_LINK_AUTO_ACCEPT, shareViaLinkAutoAccept);
  AppStorage.setOrCreate(KEY_RECEIVE_VIA_LINK_AUTO_ACCEPT, receiveViaLinkAutoAccept);
  AppStorage.setOrCreate(KEY_PORT, port);
  AppStorage.setOrCreate(KEY_MULTICAST_GROUP, multicastGroup);
  AppStorage.setOrCreate(KEY_DISCOVERY_TIMEOUT, discoveryTimeout);
  AppStorage.setOrCreate(APP_KEY_SERVER_READY, false);
  AppStorage.setOrCreate(APP_KEY_SERVER_NEEDS_RESTART, false);
  AppStorage.setOrCreate(APP_KEY_SERVER_ERROR, '');
  AppStorage.setOrCreate(APP_KEY_CHECKSUM_PROGRESS, 0);
  AppStorage.setOrCreate(APP_KEY_CHECKSUM_TOTAL, 0);
  AppStorage.setOrCreate(APP_KEY_NO_WIFI_WARNING, false);
  AppStorage.setOrCreate(KEY_FAVORITE_DEVICES, JSON.stringify(getFavorites()));
  AppStorage.setOrCreate(KEY_RECEIVE_HISTORY, JSON.stringify(getHistory()));
  AppStorage.setOrCreate(KEY_HIDE_SHARE_BY_LINK, preferencesUtil.getBoolean(KEY_HIDE_SHARE_BY_LINK, false));
  AppStorage.setOrCreate(KEY_SILENT_RECEIVE, preferencesUtil.getBoolean(KEY_SILENT_RECEIVE, true));

  // Apply saved theme (light/dark/system) immediately
  try {
    if (appContext) {
      let appCtx = appContext.getApplicationContext();
      if (theme === 'light') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (theme === 'dark') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    }
  } catch (_e) {
    hilog.warn(DOMAIN, TAG, 'initAppService: applyColorMode failed');
  }

  // Initialize device identity directly (not via refreshDeviceInfo which would
  // falsely detect "change" from the module-level default '' to the real value)
  let customAlias = preferencesUtil.getString('customAlias', '');
  let customDeviceType = preferencesUtil.getString('customDeviceType', '');
  let customDeviceModel = preferencesUtil.getString('customDeviceModel', '');

  // 首次启动时自动生成随机昵称
  if (!preferencesUtil.has('customAlias') || customAlias === '') {
    customAlias = generateAlias();
    preferencesUtil.setString('customAlias', customAlias);
  }

  alias = customAlias;
  deviceType = customDeviceType || getSystemDeviceType();
  deviceModel = customDeviceModel || deviceInfo.productModel;

  // Apply saved locale preference
  try {
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
    hilog.warn(DOMAIN, TAG, 'setAppPreferredLanguage failed during init');
  }

  // Monitor network changes — refresh interfaces and notify UI
  try {
    let netConn = connection.createNetConnection();

    // Helper: refresh interfaces + update WiFi warning + notify
    // Delay 500ms to ensure system network state is up-to-date after event
    let onNetworkChange = (): void => {
      setTimeout(() => {
        hilog.info(DOMAIN, TAG, '[DBG-NET] onNetworkChange — refreshing interfaces');
        updateLocalInterfaces();
        let hasWifi = localInterfaces.some((iface: NetworkInterface) => iface.type === NetworkType.wifi);
        hilog.info(DOMAIN, TAG, '[DBG-NET] hasWifi=%{public}s interfaces=%{public}s',
          hasWifi.toString(), localInterfaces.map((i: NetworkInterface) => `${i.ip}(${i.type})`).join(','));
        // Server binds 0.0.0.0 — no restart needed on network change, auto-listens on new interface
        // Warn if no WiFi — LAN peers cannot reach this device
        AppStorage.setOrCreate(APP_KEY_NO_WIFI_WARNING, !hasWifi);
        notifyChange();
      }, 500);
    };

    netConn.on('netAvailable', () => {
      hilog.info(DOMAIN, TAG, '[DBG-NET] netAvailable event');
      onNetworkChange();
    });
    netConn.on('netLost', () => {
      hilog.info(DOMAIN, TAG, '[DBG-NET] netLost event');
      onNetworkChange();
    });
    netConn.on('netCapabilitiesChange', () => {
      hilog.info(DOMAIN, TAG, '[DBG-NET] netCapabilitiesChange event');
      onNetworkChange();
    });

    netConn.register(() => {
      hilog.info(DOMAIN, TAG, '[DBG-NET] Network listener registered');
      // Initial check on register
      onNetworkChange();
    });
  } catch (_e) {
    hilog.warn(DOMAIN, TAG, 'Failed to register network change listener');
  }
}

export function getDeviceAlias(): string {
  return alias;
}

export function getDeviceType(): string {
  return deviceType;
}

export function getDeviceModel(): string {
  return deviceModel;
}

export function getServerFingerprint(): string {
  return serverFingerprint;
}

function getSystemDeviceType(): string {
  let sysType: string = deviceInfo.deviceType;
  if (sysType === 'tablet') {
    return 'tablet';
  } else if (sysType === '2in1' || sysType === 'tv') {
    return 'desktop';
  }
  // default, phone, wearable, etc.
  return 'mobile';
}

export function refreshDeviceInfo(): void {
  let customAlias = preferencesUtil.getString('customAlias', '');
  let customDeviceType = preferencesUtil.getString('customDeviceType', '');
  let customDeviceModel = preferencesUtil.getString('customDeviceModel', '');

  let newAlias = customAlias || (deviceInfo.manufacture + ' ' + deviceInfo.productModel);
  let newDeviceType = customDeviceType || getSystemDeviceType();
  let newDeviceModel = customDeviceModel || deviceInfo.productModel;

  // Only mark server restart if device identity actually changed
  if (newAlias !== alias || newDeviceType !== deviceType || newDeviceModel !== deviceModel) {
    alias = newAlias;
    deviceType = newDeviceType;
    deviceModel = newDeviceModel;
    markServerNeedsRestart();
  }
}

export async function reloadServerSettings(): Promise<void> {
  if (!serverRunning || isReloading) {
    return;
  }

  if (activeProgress.length > 0) {
    addLog('warn', 'Reload skipped: active transfers in progress');
    return;
  }

  isReloading = true;

  let savedAlias: string = alias;
  let savedDeviceType: string = deviceType;
  let savedDeviceModel: string = deviceModel;
  let savedHttps: boolean = httpsEnabled;
  let protocol: string = httpsEnabled ? 'https' : 'http';

  try {
    nativeDiscoverySetAnswerAnnouncements(false);
    nativeDiscoveryStop();
  } catch (_e) {}

  try {
    await nativeStopServer();
  } catch (_e) {}

  if (appContext === undefined) {
    isReloading = false;
    return;
  }
  let saveDir: string = appContext.filesDir + '/LocalSend/';

  try {
    let handle = await nativeCreateServer({
      alias: alias,
      deviceModel: deviceModel,
      deviceType: deviceType,
      port: port,
      saveDir: saveDir,
      useHttps: httpsEnabled,
      pin: receivePin.length > 0 ? receivePin : undefined
    });
    serverFingerprint = handle.fingerprint;
    serverRunning = true;
    AppStorage.setOrCreate(APP_KEY_SERVER_READY, true);

    let discoveryConfig: NativeDiscoveryConfig = {
      port: port,
      protocol: protocol,
      multicastGroup: multicastGroup,
      networkWhitelist: getNetworkListAsArray(KEY_NETWORK_WHITELIST),
      networkBlacklist: getNetworkListAsArray(KEY_NETWORK_BLACKLIST),
      discoveryTimeoutMs: discoveryTimeout,
      download: true
    };
    await nativeStartDiscoveryV2(discoveryConfig);
    nativeDiscoverySetAnswerAnnouncements(true);
    addLog('info', 'Server reloaded with new settings');
  } catch (e) {
    addLog('error', 'Reload failed: ' + e + ', rolling back');
    alias = savedAlias;
    deviceType = savedDeviceType;
    deviceModel = savedDeviceModel;
    httpsEnabled = savedHttps;
    protocol = savedHttps ? 'https' : 'http';

    try {
      let handle = await nativeCreateServer({
        alias: savedAlias,
        deviceModel: savedDeviceModel,
        deviceType: savedDeviceType,
        port: port,
        saveDir: saveDir,
        useHttps: savedHttps,
        pin: receivePin.length > 0 ? receivePin : undefined
      });
      serverFingerprint = handle.fingerprint;
      serverRunning = true;
      AppStorage.setOrCreate(APP_KEY_SERVER_READY, true);
      let discoveryConfig: NativeDiscoveryConfig = {
        port: port,
        protocol: protocol,
        multicastGroup: multicastGroup,
        networkWhitelist: getNetworkListAsArray(KEY_NETWORK_WHITELIST),
        networkBlacklist: getNetworkListAsArray(KEY_NETWORK_BLACKLIST),
        discoveryTimeoutMs: discoveryTimeout,
        download: true
      };
      await nativeStartDiscoveryV2(discoveryConfig);
      nativeDiscoverySetAnswerAnnouncements(true);
      addLog('warn', 'Rollback OK, server running with previous settings');
    } catch (rollbackError) {
      serverRunning = false;
      AppStorage.setOrCreate(APP_KEY_SERVER_READY, false);
      addLog('error', 'Rollback also failed, server offline: ' + rollbackError);
    }
  } finally {
    isReloading = false;
  }
}

export function getLocalDeviceInfo(): LocalDeviceInfo {
  let info: LocalDeviceInfo = {
    alias: alias,
    fingerprint: serverFingerprint,
    ip: getLocalIp(),
    interfaces: localInterfaces
  };
  return info;
}

export function getLocalInterfaces(): Array<NetworkInterface> {
  return localInterfaces;
}

export function isServerRunning(): boolean {
  return serverRunning;
}

export function setHttpsEnabled(enabled: boolean): void {
  hilog.info(DOMAIN, TAG, '[DBG-HTTPS] setHttpsEnabled: %{public}s → %{public}s', httpsEnabled.toString(), enabled.toString());
  httpsEnabled = enabled;
  // Sync AppStorage so @StorageLink('encryptedTransfer') UI stays in sync
  AppStorage.setOrCreate('encryptedTransfer', enabled);
  // Persist immediately to avoid losing the setting on app exit
  preferencesUtil.setBoolean(KEY_ENCRYPTED_TRANSFER, enabled);
  preferencesUtil.flushNow();
  hilog.info(DOMAIN, TAG, '[DBG-HTTPS]   persisted: key=%{public}s value=%{public}s flushed', KEY_ENCRYPTED_TRANSFER, enabled.toString());
  markServerNeedsRestart();
  notifyChange();
}

export function getHttpsEnabled(): boolean {
  return httpsEnabled;
}

export function getShareLink(): string {
  return shareLinkInfo;
}

export function getSharePort(): number {
  return sharePort;
}

export async function createShareLink(files: Array<SendFileItem>): Promise<void> {
  if (appContext === undefined) {
    addLog('error', 'Share: AppService not initialized');
    return;
  }
  let nativeFiles: Array<NativeFileToSend> = [];
  for (let i = 0; i < files.length; i++) {
    let f = files[i];
    nativeFiles.push({
      fileId: f.fileId,
      filePath: f.filePath,
      fileName: f.fileName,
      fileType: f.fileType,
      size: f.size,
      preview: f.preview,
      sha256: f.hash
    });
  }
  try {
    let result = await nativeCreateShareLink(nativeFiles, alias);
    sharePort = result.port;
    // Construct URL using local IP from ArkTS side (more reliable than Rust server_handle IP)
    let localIp = getLocalIp();
    let protocol = httpsEnabled ? 'https' : 'http';
    shareLinkInfo = protocol + '://' + localIp + ':' + sharePort;
    addLog('info', 'Share link created: ' + shareLinkInfo);
  } catch (e) {
    addLog('error', 'Share link failed: ' + e);
  }
  notifyChange();
}

export async function stopShareLink(): Promise<void> {
  hilog.info(DOMAIN, TAG, '[DBG-SHARE] stopShareLink called');
  try {
    await nativeStopShareServer();
  } catch (_e) {
  }
  shareLinkInfo = '';
  sharePort = 0;
  // Server has been restarted in normal mode by Rust stop_share_server
  addLog('info', 'Share server stopped, server restored to normal mode');
  notifyChange();
}

/**
 * Start web upload mode: restart server with upload enabled,
 * so browsers can upload files to this device via v2 protocol.
 */
export async function startWebUpload(): Promise<void> {
  hilog.info(DOMAIN, TAG, '[DBG-WEB-UP] startWebUpload: httpsEnabled=%{public}s', httpsEnabled.toString());
  try {
    let uploadPort: number = await nativeStartWebUpload();
    hilog.info(DOMAIN, TAG, '[DBG-WEB-UP]   nativeStartWebUpload returned port=%{public}d', uploadPort);
    if (uploadPort <= 0) {
      addLog('error', 'Web upload start failed: invalid port ' + uploadPort);
      notifyChange();
      return;
    }
    sharePort = uploadPort;
    let localIp = getLocalIp();
    shareLinkInfo = (httpsEnabled ? 'https' : 'http') + '://' + localIp + ':' + sharePort;
    hilog.info(DOMAIN, TAG, '[DBG-WEB-UP]   shareLink=%{public}s', shareLinkInfo);
    addLog('info', 'Web upload started: ' + shareLinkInfo);
  } catch (e) {
    hilog.error(DOMAIN, TAG, '[DBG-WEB-UP]   FAILED: %{public}s', String(e));
    addLog('error', 'Web upload start failed: ' + e);
  }
  notifyChange();
}

export function getDiscoveredDevices(): Array<DiscoveredDevice> {
  let now = Date.now();
  hilog.info(DOMAIN, TAG, '[DBG-DEVS] getDiscoveredDevices: local has %{public}d, now=%{public}d',
    discoveredDevices.length, now);
  // Filter out expired devices (lastSeen too old)
  // Devices are only added via handleDeviceFound (actual confirmations),
  // so lastSeen is only updated when a device actually responds.
  let valid: Array<DiscoveredDevice> = [];
  let expired: Array<string> = [];
  for (let i = 0; i < discoveredDevices.length; i++) {
    let age = now - discoveredDevices[i].lastSeen;
    if (age < DEVICE_EXPIRY_MS) {
      valid.push(discoveredDevices[i]);
    } else {
      expired.push(discoveredDevices[i].alias + '(' + discoveredDevices[i].fingerprint.substring(0, 8) + ' age=' + age + 'ms)');
    }
  }
  if (expired.length > 0) {
    hilog.info(DOMAIN, TAG, '[DBG-DEVS]   expired: %{public}s', expired.join(', '));
  }
  discoveredDevices = valid;
  hilog.info(DOMAIN, TAG, '[DBG-DEVS]   result: %{public}d valid, %{public}d expired', valid.length, expired.length);
  return discoveredDevices;
}

export function getPendingRequests(): Array<PendingRequest> {
  return pendingRequests;
}

export function getActiveProgress(): Array<TransferProgress> {
  return activeProgress;
}

export function clearActiveProgress(): void {
  activeProgress = [];
}

export function clearSendProgress(): void {
  // Only clear progress for send sessions (identified by session IDs that appear in sendSessions)
  let sendSessionIds: Array<string> = [];
  sendSessions.forEach((state: SendSessionState) => {
    sendSessionIds.push(state.sessionId);
  });
  let remaining: Array<TransferProgress> = [];
  for (let i = 0; i < activeProgress.length; i++) {
    let isSend = false;
    for (let j = 0; j < sendSessionIds.length; j++) {
      if (activeProgress[i].sessionId === sendSessionIds[j]) {
        isSend = true;
        break;
      }
    }
    if (!isSend) {
      remaining.push(activeProgress[i]);
    }
  }
  activeProgress = remaining;
}

export function getLogs(): Array<LogEntry> {
  return logs;
}

export function subscribe(callback: () => void): void {
  changeCallbacks.push(callback);
}

export function unsubscribe(callback: () => void): void {
  let idx = -1;
  for (let i = 0; i < changeCallbacks.length; i++) {
    if (changeCallbacks[i] === callback) {
      idx = i;
      break;
    }
  }
  if (idx >= 0) {
    let last = changeCallbacks.length - 1;
    changeCallbacks[idx] = changeCallbacks[last];
    changeCallbacks.pop();
  }
}

function notifyChange(): void {
  hilog.info(0x0001, TAG, '[diag] notifyChange callbacks=%{public}d', changeCallbacks.length);
  for (let i = 0; i < changeCallbacks.length; i++) {
    changeCallbacks[i]();
  }
}

export function triggerRefresh(): void {
  notifyChange();
}

// ── Multi-interface network detection ──

function getAllLocalIps(): Array<NetworkInterface> {
  let result: Array<NetworkInterface> = [];
  
  try {
    // 获取默认网络用于标记
    let defaultNetHandle = connection.getDefaultNetSync();
    let defaultNetId = defaultNetHandle.netId;
    
    // 获取所有激活的网络
    let allNets: Array<connection.NetHandle> = connection.getAllNetsSync();
    
    for (let i = 0; i < allNets.length; i++) {
      let netHandle = allNets[i];
      
      try {
        // 获取网络能力（判断类型）
        let netCap = connection.getNetCapabilitiesSync(netHandle);
        
        // 获取连接属性（IP地址等）
        let props = connection.getConnectionPropertiesSync(netHandle);
        
        // 判断网络类型
        let type = NetworkType.unknown;
        if (netCap.bearerTypes !== undefined) {
          if (netCap.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)) {
            type = NetworkType.wifi;
          } else if (netCap.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR)) {
            type = NetworkType.cellular;
          } else if (netCap.bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET)) {
            type = NetworkType.ethernet;
          }
        }
        
        // 提取IPv4地址
        if (props.linkAddresses !== undefined) {
          for (let j = 0; j < props.linkAddresses.length; j++) {
            let linkAddr = props.linkAddresses[j];
            if (linkAddr.address !== undefined && linkAddr.address.family === 1) {
              let isDefault = (netHandle.netId === defaultNetId);
              result.push({
                ip: linkAddr.address.address,
                prefixLength: linkAddr.prefixLength,
                type: type,
                isDefault: isDefault
              });
              
              hilog.info(DOMAIN, TAG, 'Network interface: %{public}s/%{public}d type=%{public}s default=%{public}s',
                linkAddr.address.address, linkAddr.prefixLength, type, isDefault.toString());
            }
          }
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'Failed to get network info for netId=%{public}d: %{public}s',
          netHandle.netId, JSON.stringify(e));
      }
    }
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'getAllLocalIps failed: %{public}s', JSON.stringify(e));
  }
  
  // 如果没有找到任何网卡，返回默认值
  if (result.length === 0) {
    result.push({
      ip: '0.0.0.0',
      prefixLength: 24,
      type: NetworkType.unknown,
      isDefault: true
    });
  }
  
  return result;
}

function updateLocalInterfaces(): void {
  localInterfaces = getAllLocalIps();
  hilog.info(DOMAIN, TAG, 'Updated local interfaces: %{public}d found', localInterfaces.length);
}

function getLocalIp(): string {
  // For file sharing, prefer WiFi over cellular — LAN peers can only reach WiFi IP
  for (let i = 0; i < localInterfaces.length; i++) {
    if (localInterfaces[i].type === 'wifi') {
      return localInterfaces[i].ip;
    }
  }
  // Fallback: default network
  for (let i = 0; i < localInterfaces.length; i++) {
    if (localInterfaces[i].isDefault) {
      return localInterfaces[i].ip;
    }
  }
  // Last resort: first interface
  if (localInterfaces.length > 0) {
    return localInterfaces[0].ip;
  }
  return '0.0.0.0';
}

function addLog(level: string, message: string): void {
  logs.push({ timestamp: Date.now(), level: level, message: message });
  if (logs.length > 250) {
    // Trim to 200, keeping the most recent entries
    logs = logs.slice(-200);
  }
  if (level === 'error') {
    hilog.error(DOMAIN, TAG, '[%{public}s] %{public}s', level, message);
  } else if (level === 'warn') {
    hilog.warn(DOMAIN, TAG, '[%{public}s] %{public}s', level, message);
  } else {
    hilog.info(DOMAIN, TAG, '[%{public}s] %{public}s', level, message);
  }
}

function shortSid(s: string): string {
  return s.length > 8 ? s.substring(0, 8) : s;
}

export async function startLocalServer(): Promise<string> {
  if (appContext === undefined) {
    addLog('error', 'AppService not initialized');
    return '';
  }
  
  // 更新本地网卡列表
  updateLocalInterfaces();
  addLog('info', `Local interfaces: ${localInterfaces.map(i => `${i.ip}(${i.type})`).join(', ')}`);

  // Check WiFi availability — warn if only cellular
  let hasWifi = localInterfaces.some((iface: NetworkInterface) => iface.type === NetworkType.wifi);
  AppStorage.setOrCreate(APP_KEY_NO_WIFI_WARNING, !hasWifi);
  
  let saveDir = appContext.filesDir + '/LocalSend/';
  try {
    fs.mkdirSync(saveDir);
  } catch (_e) {
  }
  let protocol = httpsEnabled ? 'https' : 'http';
  hilog.info(DOMAIN, TAG, '[DBG-SERVER] startLocalServer: httpsEnabled=%{public}s protocol=%{public}s port=%{public}d saveDir=%{public}s',
    httpsEnabled.toString(), protocol, port, saveDir);
  let handle: NativeServerHandle;
  try {
    handle = await nativeCreateServer({
      alias: alias,
      deviceModel: deviceModel,
      deviceType: deviceType,
      port: port,
      saveDir: saveDir,
      useHttps: httpsEnabled,
      pin: receivePin.length > 0 ? receivePin : undefined
    });
  } catch (e) {
    serverRunning = false;
    AppStorage.setOrCreate(APP_KEY_SERVER_READY, false);
    let errorMsg = String(e);
    hilog.error(DOMAIN, TAG, '[DBG-SERVER]   nativeCreateServer FAILED: %{public}s', errorMsg);
    // Detect port-in-use errors and provide user-friendly message
    if (errorMsg.indexOf('in use') >= 0 || errorMsg.indexOf('EADDRINUSE') >= 0 ||
        errorMsg.indexOf('Address already') >= 0) {
      let portMsg = appContext !== undefined
        ? appContext.resourceManager.getStringSync($r('app.string.port_in_use_error').id).replace('%d', String(port))
        : 'Port ' + port + ' is already in use';
      AppStorage.setOrCreate(APP_KEY_SERVER_ERROR, portMsg);
      addLog('error', portMsg);
    } else {
      AppStorage.setOrCreate(APP_KEY_SERVER_ERROR, errorMsg);
      addLog('error', 'Server start failed: ' + errorMsg);
    }
    return '';
  }
  // Clear any previous error
  AppStorage.setOrCreate(APP_KEY_SERVER_ERROR, '');
  serverFingerprint = handle.fingerprint;
  serverRunning = true;
  AppStorage.setOrCreate(APP_KEY_SERVER_READY, true);
  // Server is running with current settings — no restart needed
  clearServerNeedsRestart();
  hilog.info(DOMAIN, TAG, '[DBG-SERVER]   server started: fp=%{public}s port=%{public}d', serverFingerprint.substring(0, 8), handle.port);
  addLog('info', 'Server started, fingerprint=' + handle.fingerprint.substring(0, 10) + '...');
  
  // 启动 Rust 核心发现
  try {
    let discoveryConfig: NativeDiscoveryConfig = {
      port: port,
      protocol: protocol,
      multicastGroup: multicastGroup,
      networkWhitelist: getNetworkListAsArray(KEY_NETWORK_WHITELIST),
      networkBlacklist: getNetworkListAsArray(KEY_NETWORK_BLACKLIST),
      discoveryTimeoutMs: discoveryTimeout,
      download: true
    };
    hilog.info(DOMAIN, TAG, '[DBG-SERVER]   starting discovery: proto=%{public}s port=%{public}d', protocol, port);
    await nativeStartDiscoveryV2(discoveryConfig);
    nativeDiscoverySetAnswerAnnouncements(true);
    addLog('info', 'Rust discovery started');
  } catch (e) {
    hilog.error(DOMAIN, TAG, '[DBG-SERVER]   discovery FAILED: %{public}s', JSON.stringify(e));
    addLog('error', 'Discovery start failed: ' + e);
  }
  // Startup scan: discover_staged is the single entry point
  // (internally: announce + favorites probe + conditional subnet scan after grace period)
  // Matches LocalSend Flutter's StartSmartScan behavior
  hilog.info(DOMAIN, TAG, '[DBG-SCAN] startup: triggerStagedDiscover (includes announce + conditional subnet scan)');
  triggerStagedDiscover();

  startRequestPolling();
  // No periodic keepalive — discovery only on startup and manual refresh,
  // matching LocalSend Flutter behavior (StartSmartScan on user action only).
  notifyChange();
  return handle.fingerprint;
}

export async function stopLocalServer(): Promise<void> {
  stopRequestPolling();
  try {
    nativeDiscoverySetAnswerAnnouncements(false);
    nativeDiscoveryStop();
  } catch (_e) {
  }
  try {
    await nativeStopServer();
  } catch (_e) {
  }
  if (shareLinkInfo.length > 0) {
    await stopShareLink();
  }
  serverRunning = false;
  AppStorage.setOrCreate(APP_KEY_SERVER_READY, false);
  serverFingerprint = '';
  discoveredDevices = [];
  pendingRequests = [];
  activeProgress = [];
  receiveSessionStates = {};
  receiveSessionAutoAccepted = {};
  receiveSessionSenderAlias = {};
  addLog('info', 'Server stopped');
  notifyChange();
}

// ── Native event callback handler ──

/**
 * Handle events pushed from Rust via register_event_listener callback.
 * All events (discovery + server + web share) arrive here.
 * Called from the NativeBridge event listener setup in initAppService.
 */
export function handleNativeEvent(err: Error | null, eventJson: string): void {
  if (err !== null) {
    hilog.error(DOMAIN, TAG, '[DBG-EVENT] callback error: %{public}s', String(err));
    return;
  }
  let event: NativeEvent | undefined = parseNativeEvent(eventJson);
  if (event === undefined) {
    hilog.warn(DOMAIN, TAG, '[DBG-EVENT] unparseable event: %{public}s', eventJson.substring(0, 200));
    return;
  }
  hilog.info(DOMAIN, TAG, '[DBG-EVENT] type=%{public}s', event.type);

  switch (event.type) {
    case 'device_found':
      handleDeviceFound(event as NativeDeviceFoundEvent);
      break;
    case 'discovery_update':
      // Legacy full-list update — should no longer be sent by Rust
      // but keep as fallback for backward compatibility
      handleDiscoveryUpdate(event);
      break;
    case 'register':
      handleRegisterEventTyped(event);
      break;
    case 'prepare_upload':
      handlePrepareUploadEventTyped(event);
      break;
    case 'file_upload':
      break;
    case 'session_end':
      handleSessionEndEventTyped(event);
      break;
    case 'cancel_received':
      handleCancelReceivedEventTyped(event);
      break;
    case 'progress_update':
      handleProgressUpdateTyped(event);
      break;
    case 'prepare_upload_aborted':
      break;
    case 'web_prepare_download':
      handlePrepareDownloadTyped(event);
      break;
    case 'web_file_download':
      handleFileDownloadTyped(event);
      break;
    case 'upload_finished':
      hilog.info(DOMAIN, TAG, 'Event: upload_finished sessionId=%{public}s', event.sessionId);
      break;
    case 'upload_failed':
      hilog.warn(DOMAIN, TAG, 'Event: upload_failed sessionId=%{public}s', event.sessionId);
      break;
    case 'hash_progress':
      hilog.debug(DOMAIN, TAG, 'Event: hash_progress cancelId=%{public}s bytes=%{public}s', event.cancelId, String(event.bytes));
      break;
    case 'hash_done':
      hilog.info(DOMAIN, TAG, 'Event: hash_done cancelId=%{public}s', event.cancelId);
      break;
    case 'hash_cancelled':
      hilog.info(DOMAIN, TAG, 'Event: hash_cancelled cancelId=%{public}s', event.cancelId);
      break;
    case 'hash_error':
      hilog.error(DOMAIN, TAG, 'Event: hash_error cancelId=%{public}s error=%{public}s', event.cancelId, event.error);
      break;
    case 'show':
      hilog.info(DOMAIN, TAG, 'Event: show');
      break;
  }
}

// Handle a single device found event (like LocalSend's RegisterDeviceAction).
// Rust sends only the newly discovered/updated device, not the full store.
function handleDeviceFound(event: NativeDeviceFoundEvent): void {
  let deviceObj: Record<string, Object> = event.device;
  let now = Date.now();

  // Parse device fields
  let alias: string = (deviceObj['alias'] as string) || '';
  let fingerprint: string = (deviceObj['fingerprint'] as string) || '';
  let version: string = (deviceObj['version'] as string) || '';
  let deviceModel: string = (deviceObj['deviceModel'] as string) || '';
  let deviceType: string = (deviceObj['deviceType'] as string) || '';
  let download: boolean = (deviceObj['download'] as boolean) || false;
  let host: string = (deviceObj['host'] as string) || '';
  let devPort: number = (deviceObj['port'] as number) || 53317;
  let devProtocol: string = (deviceObj['protocol'] as string) || 'http';

  hilog.info(DOMAIN, TAG, '[DBG-DISC] device_found: alias=%{public}s fp=%{public}s proto=%{public}s ip=%{public}s:%{public}d',
    alias, fingerprint.substring(0, 8), devProtocol, host, devPort);

  // Parse channels
  let channels: Array<DeviceChannel> = [];
  let channelsRaw: Object[] | undefined = deviceObj['channels'] as Object[] | undefined;
  if (channelsRaw !== undefined) {
    for (let j = 0; j < channelsRaw.length; j++) {
      let ch: Record<string, Object> = channelsRaw[j] as Record<string, Object>;
      channels.push({
        host: (ch['host'] as string) || '',
        port: (ch['port'] as number) || 53317,
        protocol: (ch['protocol'] as string) || 'http'
      });
    }
  }

  // Find existing device
  let existingDevice: DiscoveredDevice | undefined = undefined;
  for (let k = 0; k < discoveredDevices.length; k++) {
    if (discoveredDevices[k].fingerprint === fingerprint) {
      existingDevice = discoveredDevices[k];
      break;
    }
  }

  // Keep HTTPS if existing device had it
  if (existingDevice !== undefined && existingDevice.protocol === 'https' && devProtocol !== 'https') {
    devProtocol = 'https';
  }

  hilog.info(DOMAIN, TAG, '[DBG-DISC]   existing=%{public}s old_lastSeen=%{public}d new_lastSeen=%{public}d',
    existingDevice !== undefined ? 'YES' : 'NO',
    existingDevice !== undefined ? existingDevice.lastSeen : 0,
    now);

  let updatedDevice: DiscoveredDevice = {
    alias: alias,
    ip: host,
    port: devPort,
    fingerprint: fingerprint,
    version: version,
    deviceModel: deviceModel,
    deviceType: deviceType,
    protocol: devProtocol,
    lastSeen: now,
    channels: channels,
    publicKey: existingDevice !== undefined ? existingDevice.publicKey : undefined
  };

  // Replace existing entry or append new
  if (existingDevice !== undefined) {
    for (let k = 0; k < discoveredDevices.length; k++) {
      if (discoveredDevices[k].fingerprint === fingerprint) {
        discoveredDevices[k] = updatedDevice;
        break;
      }
    }
  } else {
    discoveredDevices.push(updatedDevice);
  }

  if (fingerprint.length > 0) {
    syncAliasFromDiscovery(fingerprint, alias);
  }

  hilog.info(DOMAIN, TAG, '[DBG-DISC] after device_found: local list has %{public}d devices', discoveredDevices.length);
  notifyChange();
}

function handleDiscoveryUpdate(event: NativeDiscoveryUpdateEvent): void {
  let devicesArray: Array<NativeDiscoveredDevice> = event.devices;
  let now = Date.now();
  hilog.info(DOMAIN, TAG, '[DBG-DISC] discovery_update: %{public}d devices, local list has %{public}d',
    devicesArray.length, discoveredDevices.length);
  // Track which fingerprints appear in this event
  let seenFingerprints: Array<string> = [];
  // Update/add devices from the event
  for (let i = 0; i < devicesArray.length; i++) {
    let d: NativeDiscoveredDevice = devicesArray[i];
    hilog.info(DOMAIN, TAG, '[DBG-DISC]   device[%{public}d]: alias=%{public}s fp=%{public}s proto=%{public}s ip=%{public}s:%{public}d',
      i, d.alias, d.fingerprint.substring(0, 8), d.protocol, d.host, d.port);
    let channels: Array<DeviceChannel> = [];
    if (d.channels !== undefined) {
      for (let j = 0; j < d.channels.length; j++) {
        let ch: NativeDeviceChannel = d.channels[j];
        channels.push({
          host: ch.host,
          port: ch.port,
          protocol: ch.protocol
        });
      }
    }
    let host: string = d.host;
    let devPort: number = d.port;
    let devProtocol: string = d.protocol;
    let fingerprint: string = d.fingerprint;
    let alias: string = d.alias;
    let version: string = d.version;
    let deviceModel: string = d.deviceModel;
    let deviceType: string = d.deviceType;
    let download: boolean = d.download;

    seenFingerprints.push(fingerprint);

    let existingDevice: DiscoveredDevice | undefined = undefined;
    for (let k = 0; k < discoveredDevices.length; k++) {
      if (discoveredDevices[k].fingerprint === fingerprint) {
        existingDevice = discoveredDevices[k];
        break;
      }
    }

    // Device is confirmed present — update lastSeen to now
    let lastSeen: number = now;
    hilog.info(DOMAIN, TAG, '[DBG-DISC]   existing=%{public}s old_lastSeen=%{public}d new_lastSeen=%{public}d old_proto=%{public}s',
      existingDevice !== undefined ? 'YES' : 'NO',
      existingDevice !== undefined ? existingDevice.lastSeen : 0,
      lastSeen,
      existingDevice !== undefined ? existingDevice.protocol : '-');

    if (existingDevice !== undefined && existingDevice.protocol === 'https' && devProtocol !== 'https') {
      devProtocol = 'https';
    }

    let updatedDevice: DiscoveredDevice = {
      alias: alias,
      ip: host,
      port: devPort,
      fingerprint: fingerprint,
      version: version,
      deviceModel: deviceModel,
      deviceType: deviceType,
      protocol: devProtocol,
      lastSeen: lastSeen,
      channels: channels,
      publicKey: existingDevice !== undefined ? existingDevice.publicKey : undefined
    };

    // Replace existing entry or append new
    if (existingDevice !== undefined) {
      for (let k = 0; k < discoveredDevices.length; k++) {
        if (discoveredDevices[k].fingerprint === fingerprint) {
          discoveredDevices[k] = updatedDevice;
          break;
        }
      }
    } else {
      discoveredDevices.push(updatedDevice);
    }

    if (fingerprint.length > 0) {
      syncAliasFromDiscovery(fingerprint, alias);
    }
  }
  hilog.info(DOMAIN, TAG, '[DBG-DISC] after merge: local list has %{public}d devices', discoveredDevices.length);
  // Devices NOT in this event keep their existing state (including lastSeen);
  // they will expire naturally via getDiscoveredDevices() when lastSeen is too old.
  notifyChange();
}

function handleRegisterEventTyped(event: NativeServerRegisterEvent): void {
  let ip: string = event.ip;
  let info: NativeRegisterInfo = event.info;
  let deviceType: string = info.deviceType !== undefined ? info.deviceType : 'mobile';
  let fingerprint: string = info.fingerprint;
  let port: number = info.port;
  hilog.info(DOMAIN, TAG, '[DBG-REG] register event: ip=%{public}s alias=%{public}s fp=%{public}s port=%{public}d deviceType=%{public}s',
    ip, info.alias, fingerprint.substring(0, 8), port, deviceType);

  let nativeDevice: NativeDiscoveredDevice = {
    alias: info.alias,
    fingerprint: fingerprint,
    version: info.version,
    deviceModel: info.deviceModel !== undefined ? info.deviceModel : '',
    deviceType: deviceType,
    download: info.download,
    host: ip,
    port: port,
    // Use the remote device's actual protocol (from its register payload),
    // not the local server's setting.
    protocol: (info.protocol !== undefined && info.protocol !== null && info.protocol.length > 0)
      ? info.protocol : (httpsEnabled ? 'https' : 'http'),
    channels: []
  };
  hilog.info(DOMAIN, TAG, '[DBG-REG]   remote protocol=%{public}s (local httpsEnabled=%{public}s)',
    nativeDevice.protocol, httpsEnabled.toString());
  nativeDiscoveryAddDevice(nativeDevice).catch((e: Error) => {
    addLog('warn', 'Failed to add register device to discovery: ' + e.message);
  });
}

function handlePrepareUploadEventTyped(event: NativePrepareUploadEvent): void {
  let sessionId: string = event.sessionId;
  // certFingerprint can be null (from JSON null) or undefined when server has no TLS
  let certFp: string = (event.certFingerprint !== undefined && event.certFingerprint !== null)
    ? event.certFingerprint : '';
  let infoFp: string = (event.info.fingerprint !== undefined && event.info.fingerprint !== null)
    ? event.info.fingerprint : '';
  hilog.info(DOMAIN, TAG, '[DBG-RECV] prepare_upload: sessionId=%{public}s ip=%{public}s files=%{public}d certFp=%{public}s info.alias=%{public}s info.fp=%{public}s info.port=%{public}d info.download=%{public}s',
    shortSid(sessionId), event.ip, event.files.length,
    certFp.length > 0 ? certFp.substring(0, 8) : '-',
    event.info.alias, infoFp.length > 0 ? infoFp.substring(0, 8) : '-', event.info.port, event.info.download.toString());
  if (sessionId.length === 0) {
    addLog('warn', 'PrepareUpload event with empty sessionId, ignoring');
    return;
  }
  let senderAlias: string = event.info.alias;
  let senderFingerprint: string = '';
  if (certFp.length > 0) {
    senderFingerprint = certFp;
  } else {
    senderFingerprint = infoFp;
  }
  let senderProtocol: string = 'http';
  if (certFp.length > 0) {
    senderProtocol = 'https';
  } else if (event.info.protocol !== undefined && event.info.protocol !== null && event.info.protocol.length > 0) {
    senderProtocol = event.info.protocol;
  }
  hilog.info(DOMAIN, TAG, '[DBG-RECV]   senderFp=%{public}s senderProto=%{public}s hasCertFp=%{public}s',
    senderFingerprint.length > 0 ? senderFingerprint.substring(0, 8) : '-', senderProtocol, (certFp.length > 0).toString());

  let alreadyKnown = false;
  for (let j = 0; j < pendingRequests.length; j++) {
    if (pendingRequests[j].sessionId === sessionId) {
      alreadyKnown = true;
      break;
    }
  }
  let dnd = false;
  for (let k = 0; k < requestDoNotDisturb.length; k++) {
    if (requestDoNotDisturb[k] === sessionId) {
      dnd = true;
      break;
    }
  }
  if (alreadyKnown || dnd) {
    hilog.info(DOMAIN, TAG, '[DBG-RECV]   skipping: alreadyKnown=%{public}s dnd=%{public}s', alreadyKnown.toString(), dnd.toString());
    return;
  }

  let files: Array<PendingRequestFile> = [];
  let fileEntries: Array<ReceivedFileEntry> = [];
  let hasMessage: boolean = false;
  let allFileIds: Array<string> = [];
  for (let fi = 0; fi < event.files.length; fi++) {
    let f: NativeTransferFileInfo = event.files[fi];
    hilog.info(DOMAIN, TAG, '[DBG-RECV]   file[%{public}d]: id=%{public}s name=%{public}s size=%{public}d type=%{public}s',
      fi, f.fileId, f.fileName, f.size, f.fileType);
    files.push({
      fileId: f.fileId,
      fileName: f.fileName,
      size: f.size,
      fileType: f.fileType,
      preview: f.preview,
      sha256: f.sha256
    });
    fileEntries.push({
      sessionId: sessionId,
      fileId: f.fileId,
      filePath: '',
      fileName: f.fileName,
      fileType: f.fileType
    });
    allFileIds.push(f.fileId);
    if (f.fileType === 'text/plain' || f.fileName.endsWith('.txt')) {
      hasMessage = true;
    }
  }

  let autoAccept = shouldAutoAccept(senderFingerprint, hasMessage);
  hilog.info(DOMAIN, TAG, '[DBG-RECV]   autoAccept=%{public}s (quickSaveMode=%{public}s hasMessage=%{public}s senderFp=%{public}s)',
    autoAccept.toString(), quickSaveMode, hasMessage.toString(), senderFingerprint.substring(0, 8));
  if (autoAccept) {
    requestDoNotDisturb.push(sessionId);
    sessionTotalFiles[sessionId] = files.length;
    sessionCompletedCount[sessionId] = 0;
    sessionFileMap[sessionId] = fileEntries;
    receiveSessionStates[sessionId] = 'sending';
    receiveSessionAutoAccepted[sessionId] = true;
    receiveSessionSenderAlias[sessionId] = senderAlias;
    AppStorage.setOrCreate(APP_PREFIX_RECV_SESSION_AUTO_ACCEPTED + sessionId, true);
    addLog('info', 'QuickSave: auto-accepting from ' + senderAlias + ': ' +
      files.length + ' file(s)');
    hilog.info(DOMAIN, TAG, '[DBG-RECV]   auto-accept: calling nativeRespondTransfer(sessionId=%{public}s, accept=true, fileIds=%{public}d)',
      shortSid(sessionId), allFileIds.length);
    nativeRespondTransfer(sessionId, true, allFileIds).then(() => {
      hilog.info(DOMAIN, TAG, '[DBG-RECV]   auto-accept: nativeRespondTransfer resolved OK');
    }).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, '[DBG-RECV]   auto-accept: nativeRespondTransfer FAILED: %{public}s', e.message);
      addLog('error', 'QuickSave auto-accept failed: ' + e.message);
    });
  } else {
    pendingRequests.push({
      sessionId: sessionId,
      senderAlias: senderAlias,
      senderFingerprint: senderFingerprint,
      senderProtocol: senderProtocol,
      files: files
    });
    sessionTotalFiles[sessionId] = files.length;
    sessionCompletedCount[sessionId] = 0;
    sessionFileMap[sessionId] = fileEntries;
    receiveSessionStates[sessionId] = 'waiting';
    receiveSessionAutoAccepted[sessionId] = false;
    receiveSessionSenderAlias[sessionId] = senderAlias;
    addLog('info', 'Incoming transfer from ' + senderAlias + ': ' +
      files.length + ' file(s)');
  }
  notifyChange();
}

function handleSessionEndEventTyped(event: NativeSessionEndEvent): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length > 0) {
    addLog('info', 'Session ended: ' + sessionId.substring(0, 8));
  }
}

function handleCancelReceivedEventTyped(event: NativeCancelReceivedEvent): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length > 0) {
    AppStorage.setOrCreate(APP_KEY_RECV_TRANSFER_CANCELLED, sessionId);
    receiveSessionStates[sessionId] = 'canceledBySender';
    let cleaned: Array<TransferProgress> = [];
    for (let j = 0; j < activeProgress.length; j++) {
      if (activeProgress[j].sessionId !== sessionId) {
        cleaned.push(activeProgress[j]);
      }
    }
    activeProgress = cleaned;
    addLog('info', 'Transfer cancelled by sender: ' + sessionId.substring(0, 8));
    notifyChange();
  }
}

function handlePrepareDownloadTyped(event: NativeWebSendPrepare): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length === 0) {
    addLog('warn', 'WebPrepareDownload event with empty sessionId, ignoring');
    return;
  }
  let ip: string = event.ip;
  let userAgent: string = event.userAgent !== undefined ? event.userAgent : '';

  hilog.info(DOMAIN, TAG, '[DBG-WEB-DL] web_prepare_download: sessionId=%{public}s ip=%{public}s userAgent=%{public}s',
    shortSid(sessionId), ip, userAgent);
  addLog('info', 'Web download request from ' + ip + ' (session=' + sessionId.substring(0, 8) + ')');

  // Web download auto-accept follows silentReceive setting (not quickSaveMode)
  let silentReceive: boolean = AppStorage.get<boolean>(KEY_SILENT_RECEIVE) ?? false;
  hilog.info(DOMAIN, TAG, '[DBG-WEB-DL]   silentReceive=%{public}s', silentReceive.toString());
  if (silentReceive) {
    addLog('info', 'Web download auto-accepted (silentReceive=true)');
    hilog.info(DOMAIN, TAG, '[DBG-WEB-DL]   calling nativeAcceptWebDownload(sessionId=%{public}s)', shortSid(sessionId));
    nativeAcceptWebDownload(sessionId);
  } else {
    addLog('info', 'Web download requires confirmation (silentReceive=false)');
    AppStorage.setOrCreate(APP_KEY_WEB_DOWNLOAD_REQUEST, JSON.stringify({
      sessionId: sessionId,
      ip: ip,
      userAgent: userAgent
    }));
  }
}

function handleFileDownloadTyped(event: NativeWebSendFileDownload): void {
  if (event.sessionId.length > 0) {
    hilog.info(DOMAIN, TAG, '[DBG-WEB-DL] web_file_download: sessionId=%{public}s fileId=%{public}s name=%{public}s size=%{public}d',
      shortSid(event.sessionId), event.fileId, event.fileName, event.size);
    addLog('info', 'Web file download: ' + event.fileName + ' (' + event.size + ' bytes) session=' + event.sessionId.substring(0, 8));
  }
}

function handleProgressUpdateTyped(event: NativeProgressUpdateEvent): void {
  let direction: string = event.direction;
  let sessionId: string = event.sessionId;
  let fileId: string = event.fileId;

  if (sessionId.length === 0 || fileId.length === 0) {
    return;
  }

  let progress: TransferProgress = {
    sessionId: sessionId,
    fileId: fileId,
    bytesSent: event.bytesSent,
    totalBytes: event.totalBytes,
    filePath: event.filePath
  };

  let found: boolean = false;
  for (let j = 0; j < activeProgress.length; j++) {
    if (activeProgress[j].sessionId === sessionId &&
      activeProgress[j].fileId === fileId) {
      activeProgress[j] = progress;
      found = true;
      break;
    }
  }
  if (!found) {
    activeProgress.push(progress);
  }

  AppStorage.setOrCreate(APP_KEY_ACTIVE_PROGRESS_COUNT, activeProgress.length);

  if (direction === 'recv') {
    handleRecvProgress(progress);
  } else if (direction === 'send') {
    handleSendProgress(progress);
  } else if (direction === 'share') {
    hilog.info(DOMAIN, TAG, 'Share progress update: session=%{public}s file=%{public}s', sessionId.substring(0, 8), fileId);
  }

  notifyChange();
}

/**
 * Handle a single recv progress update event.
 * Extracted from the old doPollProgress loop logic for single-event processing.
 * Handles: file completion detection, session completion, file export, history, auto-finish, cleanup.
 */
function handleRecvProgress(progress: TransferProgress): void {
  let sessionId: string = progress.sessionId;
  let fileId: string = progress.fileId;
  let bytesSent: number = progress.bytesSent;
  let totalBytes: number = progress.totalBytes;
  let filePath: string = progress.filePath;

  // Check if this file just completed
  let key = sessionId + ':' + fileId;
  if (bytesSent >= totalBytes && totalBytes > 0 &&
    completedFileIds[key] === undefined) {
    completedFileIds[key] = true;
    completedFileCount++;
    // Periodically reset completedFileIds to prevent unbounded growth
    if (completedFileCount > 500) {
      completedFileIds = {};
      completedFileCount = 0;
    }
    let prev = sessionCompletedCount[sessionId] || 0;
    sessionCompletedCount[sessionId] = prev + 1;

    // Update file path in session file map
    let entries = sessionFileMap[sessionId];
    if (entries !== undefined) {
      for (let j = 0; j < entries.length; j++) {
        if (entries[j].fileId === fileId) {
          entries[j].filePath = filePath;
          break;
        }
      }
    }

    // Check if session is complete (all files finished)
    let total = sessionTotalFiles[sessionId] || 0;
    if (sessionCompletedCount[sessionId] >= total && total > 0 &&
      sessionExported[sessionId] === undefined) {
      sessionExported[sessionId] = true;
      hilog.info(0x0001, TAG,
        '[callback] session complete session=%{public}s cnt=%{public}d/%{public}d',
        sessionId, sessionCompletedCount[sessionId], sessionTotalFiles[sessionId] || 0);
      finishReceiveSession(sessionId);
    }
  }
}

/**
 * Complete a receive session: export files, record history, auto-finish, cleanup.
 * Called when all files in a session have finished downloading.
 */
async function finishReceiveSession(sessionId: string): Promise<void> {
  // Remove progress entries for this session
  let cleaned: Array<TransferProgress> = [];
  for (let j = 0; j < activeProgress.length; j++) {
    if (activeProgress[j].sessionId !== sessionId) {
      cleaned.push(activeProgress[j]);
    }
  }
  activeProgress = cleaned;

  // ── Receive session state machine: mark as finished ──
  receiveSessionStates[sessionId] = 'finished';

  // ── Record receive history ──
  let senderAlias = receiveSessionSenderAlias[sessionId];
  let sessionEntries = sessionFileMap[sessionId];
  if (senderAlias === undefined) {
    senderAlias = '';
  }
  if (sessionEntries !== undefined && sessionEntries.length > 0) {
    recordReceiveHistory(sessionId, sessionEntries, senderAlias);
  }

  let entries = sessionFileMap[sessionId];
  if (entries !== undefined && entries.length === 1
    && entries[0].fileType === 'text/plain' && entries[0].filePath.length > 0) {
    try {
      let content = fs.readTextSync(entries[0].filePath);
      try {
        fs.unlinkSync(entries[0].filePath);
      } catch (_cleanupErr) {
      }
      AppStorage.setOrCreate(APP_KEY_RECV_TEXT_MESSAGE, JSON.stringify({
        sessionId: sessionId,
        content: content
      }));
    } catch (_e) {
      await exportSessionFiles(sessionId);
    }
  } else {
    await exportSessionFiles(sessionId);
  }
  AppStorage.setOrCreate(APP_KEY_RECV_TRANSFER_COMPLETED, sessionId);
  hilog.info(0x0001, TAG, '[callback] set recvTransferCompleted=%{public}s', sessionId);

  // ── Auto-finish logic ──
  let wasAutoAccepted = receiveSessionAutoAccepted[sessionId];
  if (shouldAutoFinishSession(sessionId, false)) {
    // Auto-finish: close the session automatically
    AppStorage.setOrCreate(APP_PREFIX_RECV_AUTO_FINISH + sessionId, true);
    addLog('info', 'Auto-finish: session ' + sessionId.substring(0, 8) + ' completed, auto-closing');
    // For single file + QuickSave + no errors: offer "open file" option
    if (wasAutoAccepted && entries !== undefined && entries.length === 1) {
      AppStorage.setOrCreate(APP_PREFIX_RECV_OFFER_OPEN_FILE + sessionId, true);
    }
  }

  // Clean up session state to prevent memory leak
  sessionTotalFiles[sessionId] = 0;
  sessionCompletedCount[sessionId] = 0;
  // Mark as cleaned up — checked via === undefined in completion logic,
  // so setting to false prevents re-triggering (false !== undefined).
  sessionExported[sessionId] = false;
  sessionFileMap[sessionId] = [];
  // Clean up receive session state to prevent memory leak
  receiveSessionStates[sessionId] = '';
  receiveSessionAutoAccepted[sessionId] = false;
  receiveSessionSenderAlias[sessionId] = '';
  // Periodically reset all session Records to prevent unbounded growth
  sessionCleanupCount++;
  if (sessionCleanupCount > 100) {
    sessionTotalFiles = {};
    sessionCompletedCount = {};
    sessionExported = {};
    sessionFileMap = {};
    receiveSessionStates = {};
    receiveSessionAutoAccepted = {};
    receiveSessionSenderAlias = {};
    completedFileIds = {};
    completedFileCount = 0;
    sessionCleanupCount = 0;
  }
  // Clean up DoNotDisturb entry for this session
  let dndIdx = -1;
  for (let d = 0; d < requestDoNotDisturb.length; d++) {
    if (requestDoNotDisturb[d] === sessionId) {
      dndIdx = d;
      break;
    }
  }
  if (dndIdx >= 0) {
    requestDoNotDisturb.splice(dndIdx, 1);
  }
}

/**
 * Handle a single send progress update event.
 * Updates activeProgress and handles send session completion.
 */
function handleSendProgress(progress: TransferProgress): void {
  let sessionId: string = progress.sessionId;
  let fileId: string = progress.fileId;
  let bytesSent: number = progress.bytesSent;
  let totalBytes: number = progress.totalBytes;

  hilog.info(0x0001, 'LocalSend:AppService', '[send-callback] sid=%{public}s fid=%{public}s %{public}d/%{public}d',
    shortSid(sessionId), fileId, bytesSent, totalBytes);

  // Check if this send file just completed
  if (bytesSent >= totalBytes && totalBytes > 0) {
    // Send session completion is handled by the sendToDevice/sendToDeviceMulti flow
    // (nativeSendFiles resolves after all uploads finish)
    hilog.info(0x0001, TAG, '[send-callback] file complete: session=%{public}s file=%{public}s',
      shortSid(sessionId), fileId);
  }
}

// Helper: trigger staged discover using current config + favorites
// Does NOT include subnet scan to avoid duplicate DISCOVER/REGISTER messages
// when called alongside announce(). Use scanSubnets() separately if needed.
function triggerStagedDiscover(): void {
  let favDevices = getFavorites();
  let channels: Array<NativeDeviceChannel> = [];
  let protocol = httpsEnabled ? 'https' : 'http';
  let altProtocol = httpsEnabled ? 'http' : 'https';
  for (let i = 0; i < favDevices.length; i++) {
    // Probe favorites with both protocols so we can find devices using a different encryption mode
    channels.push({
      host: favDevices[i].ip,
      port: favDevices[i].port,
      protocol: protocol
    });
    channels.push({
      host: favDevices[i].ip,
      port: favDevices[i].port,
      protocol: altProtocol
    });
  }
  let interfaceIps: Array<string> = [];
  for (let i = 0; i < localInterfaces.length; i++) {
    if (localInterfaces[i].ip !== '0.0.0.0') {
      interfaceIps.push(localInterfaces[i].ip);
    }
  }
  hilog.info(DOMAIN, TAG, '[DBG-SCAN] triggerStagedDiscover: %{public}d fav channels, %{public}d interfaces, proto=%{public}s, alt=%{public}s, port=%{public}d',
    channels.length, interfaceIps.length, protocol, altProtocol, port);
  nativeDiscoveryDiscoverStaged(channels, interfaceIps, port, protocol, 2000).then(() => {
    hilog.info(DOMAIN, TAG, '[DBG-SCAN]   discoverStaged resolved OK, starting alt-protocol subnet scan (%{public}s)', altProtocol);
    // Scan with alternate protocol to discover devices using a different encryption mode
    for (let i = 0; i < interfaceIps.length; i++) {
      nativeDiscoveryScanSubnet(interfaceIps[i], port, altProtocol).catch((e: Error) => {
        hilog.info(DOMAIN, TAG, '[DBG-SCAN]   alt-protocol scan (%{public}s) for %{public}s failed: %{public}s', altProtocol, interfaceIps[i], e.message);
      });
    }
  }).catch((e: Error) => {
    hilog.error(DOMAIN, TAG, '[DBG-SCAN]   discoverStaged FAILED: %{public}s', e.message);
    addLog('warn', 'Staged discover failed: ' + e.message);
    // Still try alt-protocol scan even if primary discover failed
    for (let i = 0; i < interfaceIps.length; i++) {
      nativeDiscoveryScanSubnet(interfaceIps[i], port, altProtocol).catch((_e: Error) => {
        // Ignore alt-protocol scan failures
      });
    }
  });
}

// Helper: scan subnets for new devices (not combined with announce to avoid duplicates)
function scanSubnets(): void {
  let interfaceIps: Array<string> = [];
  for (let i = 0; i < localInterfaces.length; i++) {
    if (localInterfaces[i].ip !== '0.0.0.0') {
      interfaceIps.push(localInterfaces[i].ip);
    }
  }
  let protocol = httpsEnabled ? 'https' : 'http';
  let altProtocol = httpsEnabled ? 'http' : 'https';
  hilog.info(DOMAIN, TAG, '[DBG-SCAN] scanSubnets: %{public}d interfaces, proto=%{public}s + alt=%{public}s', interfaceIps.length, protocol, altProtocol);
  for (let i = 0; i < interfaceIps.length; i++) {
    nativeDiscoveryScanSubnet(interfaceIps[i], port, protocol).catch((e: Error) => {
      addLog('warn', 'Subnet scan failed for ' + interfaceIps[i] + ': ' + e.message);
    });
    // Also scan with alternate protocol to discover cross-protocol devices
    nativeDiscoveryScanSubnet(interfaceIps[i], port, altProtocol).catch((_e: Error) => {
      // Ignore alt-protocol scan failures — the device may not support it
    });
  }
}

// Helper: parse network whitelist/blacklist from preferences (comma-separated string → Array<string>)
function getNetworkListAsArray(key: string): Array<string> | undefined {
  let raw: string = preferencesUtil.getString(key, '');
  if (raw.length === 0) {
    return undefined;
  }
  let parts: Array<string> = raw.split(',');
  let result: Array<string> = [];
  for (let i = 0; i < parts.length; i++) {
    let trimmed: string = parts[i].trim();
    if (trimmed.length > 0) {
      result.push(trimmed);
    }
  }
  return result.length > 0 ? result : undefined;
}

// onDeviceDiscovered removed — superseded by handleDiscoveryUpdate which processes
// NativeDiscoveryUpdateEvent from the Rust event callback, including multi-channel
// support and proper existing-device merge.

export function rescanDevices(announce: boolean = true): void {
  hilog.info(DOMAIN, TAG, '[DBG-SCAN] rescanDevices: announce=%{public}s serverFp=%{public}s',
    announce.toString(), serverFingerprint.length > 0 ? 'YES' : 'NO');
  if (serverFingerprint.length > 0) {
    // Match LocalSend Flutter's StartSmartScan:
    // 1. Clear device list first (so stale devices disappear)
    // 2. Call discover_staged (which internally includes announce + favorites probe + conditional subnet scan)
    discoveredDevices = [];
    if (announce) {
      // discover_staged already includes announce internally,
      // so just call triggerStagedDiscover — it's the equivalent of StartSmartScan
      addLog('info', 'Rescan: smart scan (discover_staged with announce)');
      hilog.info(DOMAIN, TAG, '[DBG-SCAN]   calling triggerStagedDiscover (includes announce)');
      triggerStagedDiscover();
    } else {
      // No announce (e.g. server restart), probe known addresses only
      addLog('info', 'Rescan: staged discover only (no announce)');
      hilog.info(DOMAIN, TAG, '[DBG-SCAN]   calling triggerStagedDiscover (no extra announce)');
      triggerStagedDiscover();
    }
    notifyChange();
  }
}

function startRequestPolling(): void {
  if (requestPollTimer !== undefined) {
    return;
  }
  requestPollTimer = setInterval(() => {
    doPollRequests();
  }, 30000);
}

function stopRequestPolling(): void {
  if (requestPollTimer !== undefined) {
    clearInterval(requestPollTimer);
    requestPollTimer = undefined;
  }
}

// ── Receive session state tracking ──
let receiveSessionStates: Record<string, string> = {}; // sessionId -> 'waiting'|'sending'|'finished'|'finishedWithErrors'|'canceledBySender'
let receiveSessionAutoAccepted: Record<string, boolean> = {}; // sessionId -> was auto-accepted
let receiveSessionSenderAlias: Record<string, string> = {}; // sessionId -> senderAlias for history recording


function doPollRequests(): void {
  // Poll is now a backup/diagnostic path — primary request handling is via callback (handleNativeEvent)
  // Keep this for cases where callback delivery was missed or for DebugPage
  if (!serverRunning) {
    return;
  }
  let raw = nativePollPendingRequests();
  for (let i = 0; i < raw.length; i++) {
    let r = raw[i];
    let alreadyKnown = false;
    for (let j = 0; j < pendingRequests.length; j++) {
      if (pendingRequests[j].sessionId === r.sessionId) {
        alreadyKnown = true;
        break;
      }
    }
    if (!alreadyKnown) {
      let dnd = false;
      for (let k = 0; k < requestDoNotDisturb.length; k++) {
        if (requestDoNotDisturb[k] === r.sessionId) {
          dnd = true;
          break;
        }
      }
      if (!dnd) {
        let files: Array<PendingRequestFile> = [];
        let fileEntries: Array<ReceivedFileEntry> = [];
        let hasMessage: boolean = false;
        let allFileIds: Array<string> = [];
        for (let fi = 0; fi < r.files.length; fi++) {
          let f = r.files[fi];
          files.push({
            fileId: f.fileId,
            fileName: f.fileName,
            size: f.size,
            fileType: f.fileType,
            preview: f.preview,
            sha256: f.sha256
          });
          fileEntries.push({
            sessionId: r.sessionId,
            fileId: f.fileId,
            filePath: '',
            fileName: f.fileName,
            fileType: f.fileType
          });
          allFileIds.push(f.fileId);
          // Check if this is a text message
          if (f.fileType === 'text/plain' || f.fileName.endsWith('.txt')) {
            hasMessage = true;
          }
        }
        // ── QuickSave auto-accept integration ──
        let autoAccept = shouldAutoAccept(r.senderFingerprint, hasMessage);
        if (autoAccept) {
          // Auto-accept: accept all files immediately
          requestDoNotDisturb.push(r.sessionId);
          sessionTotalFiles[r.sessionId] = r.files.length;
          sessionCompletedCount[r.sessionId] = 0;
          sessionFileMap[r.sessionId] = fileEntries;
          receiveSessionStates[r.sessionId] = 'sending';
          receiveSessionAutoAccepted[r.sessionId] = true;
          receiveSessionSenderAlias[r.sessionId] = r.senderAlias;
          AppStorage.setOrCreate(APP_PREFIX_RECV_SESSION_AUTO_ACCEPTED + r.sessionId, true);
          addLog('info', 'QuickSave: auto-accepting from ' + r.senderAlias + ': ' +
            files.length + ' file(s)');
          // Respond to the transfer immediately - accept all files
          nativeRespondTransfer(r.sessionId, true, allFileIds).catch((e: Error) => {
            addLog('error', 'QuickSave auto-accept failed: ' + e.message);
          });
          notifyChange();
        } else {
          // Manual confirmation required: add to pending requests list
          pendingRequests.push({
            sessionId: r.sessionId,
            senderAlias: r.senderAlias,
            senderFingerprint: r.senderFingerprint,
            senderProtocol: r.senderProtocol,
            files: files
          });
          sessionTotalFiles[r.sessionId] = r.files.length;
          sessionCompletedCount[r.sessionId] = 0;
          sessionFileMap[r.sessionId] = fileEntries;
          receiveSessionStates[r.sessionId] = 'waiting';
          receiveSessionAutoAccepted[r.sessionId] = false;
          receiveSessionSenderAlias[r.sessionId] = r.senderAlias;
          addLog('info', 'Incoming transfer from ' + r.senderAlias + ': ' +
            files.length + ' file(s)');
          notifyChange();
        }
      }
    }
  }
}

function drainNativeDebugLog(): void {
  let lines: Array<string> = nativePollDebugLog();
  for (let i = 0; i < lines.length; i++) {
    hilog.info(DOMAIN, TAG, '[native] %{public}s', lines[i]);
  }
}

async function exportSessionFiles(sessionId: string): Promise<void> {
  let entries: Array<ReceivedFileEntry> | undefined = sessionFileMap[sessionId];
  if (entries === undefined || appContext === undefined) {
    return;
  }
  let names: Array<string> = [];
  let validEntries: Array<ReceivedFileEntry> = [];
  for (let i = 0; i < entries.length; i++) {
    let entry = entries[i];
    if (entry.filePath.length > 0) {
      let lastSlash = entry.filePath.lastIndexOf('/');
      let diskName = lastSlash >= 0 ? entry.filePath.substring(lastSlash + 1) : entry.filePath;
      // Sanitize file name to ensure it's legal on the current platform
      diskName = nativeSanitizeFileName(diskName);
      names.push(diskName);
      validEntries.push(
        {          sessionId: entry.sessionId,fileId: entry.fileId, filePath: entry.filePath,
          fileName: diskName,
          fileType: entry.fileType });
    }
  }
  if (validEntries.length === 0) {
    return;
  }
  try {
    let saveOptions = new picker.DocumentSaveOptions();
    saveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    saveOptions.newFileNames = names;
    let documentPicker = new picker.DocumentViewPicker();
    let uris: Array<string> = await documentPicker.save(saveOptions);
    if (uris.length === 0) {
      addLog('info', 'Export cancelled by user');
      return;
    }
    let dirUri: string = uris[0];
    let dirPath: string = new fileUri.FileUri(dirUri).path;
    let successCount = 0;
    for (let i = 0; i < validEntries.length; i++) {
      let sandboxPath: string = validEntries[i].filePath;
      let destPath: string = dirPath + '/' + validEntries[i].fileName;
      try {
        fs.copyFileSync(sandboxPath, destPath);
        try {
          fs.unlinkSync(sandboxPath);
        } catch (_cleanupErr) {
        }
        successCount = successCount + 1;
        addLog('info', 'Exported: ' + validEntries[i].fileName);
      } catch (copyErr) {
        addLog('error', 'Export copy failed for ' + validEntries[i].fileName + ': ' + copyErr);
      }
    }
    if (successCount > 0) {
      addLog('info', 'Exported ' + successCount + '/' + names.length + ' files');
    }
  } catch (pickerErr) {
    addLog('error', 'Download picker failed: ' + pickerErr);
  }
}

export async function respondToRequest(sessionId: string, accept: boolean, acceptedFileIds: Array<string> = []): Promise<void> {
  requestDoNotDisturb.push(sessionId);
  let newPending: Array<PendingRequest> = [];
  for (let i = 0; i < pendingRequests.length; i++) {
    if (pendingRequests[i].sessionId !== sessionId) {
      newPending.push(pendingRequests[i]);
    }
  }
  pendingRequests = newPending;
  // Update receive session state
  if (accept) {
    receiveSessionStates[sessionId] = 'sending';
  } else {
    receiveSessionStates[sessionId] = 'canceledBySender';
  }
  try {
    await nativeRespondTransfer(sessionId, accept, acceptedFileIds);
    addLog('info', 'Request ' + sessionId.substring(0, 8) + ' response: ' +
      (accept ? 'accepted' : 'declined'));
  } catch (e) {
    addLog('error', 'Respond failed: ' + e);
  }
  notifyChange();
}

export async function sendToDevice(
  device: DiscoveredDevice,
  files: Array<SendFileItem>
): Promise<SendResult> {
  hilog.info(DOMAIN, TAG, '[DBG-SEND] sendToDevice: alias=%{public}s ip=%{public}s:%{public}d proto=%{public}s fp=%{public}s publicKey=%{public}s files=%{public}d',
    device.alias, device.ip, device.port, device.protocol, device.fingerprint.substring(0, 8),
    device.publicKey !== undefined ? 'YES' : 'NO', files.length);
  // Auto-restart server if pending config changes (e.g. HTTPS toggle)
  // This ensures the running server protocol matches current settings
  if (serverNeedsRestart) {
    addLog('info', 'Auto-restarting server before send...');
    hilog.info(DOMAIN, TAG, '[DBG-SEND]   serverNeedsRestart=true, restarting...');
    await restartServer();
  }

  // 协议协商逻辑（加密不可降级策略）：
  // 1. 发送端启用HTTPS + 接收端支持HTTPS → 使用HTTPS
  // 2. 发送端启用HTTPS + 接收端不支持HTTPS → 错误，拒绝降级
  // 3. 发送端禁用HTTPS + 接收端支持HTTPS → 使用HTTP（对方服务器同时接受HTTP）
  // 4. 发送端禁用HTTPS + 接收端不支持HTTPS → 使用HTTP
  let localHttps = getHttpsEnabled();
  let remoteHttps = device.protocol === 'https';
  hilog.info(DOMAIN, TAG, '[DBG-SEND]   localHttps=%{public}s remoteHttps=%{public}s',
    localHttps.toString(), remoteHttps.toString());
  
  // 如果发送端要求加密但接收端不支持，直接报错
  if (localHttps && !remoteHttps) {
    let errorMsg = '';
    if (appContext !== undefined) {
      errorMsg = appContext.resourceManager.getStringSync($r('app.string.protocol_mismatch_error').id).replace('%s', device.alias);
    } else {
      errorMsg = 'Protocol mismatch: receiver does not support HTTPS';
    }
    hilog.error(DOMAIN, TAG, '[DBG-SEND]   PROTOCOL MISMATCH: local HTTPS but remote HTTP only');
    addLog('error', errorMsg);
    
    return { success: false, error: { kind: 'other', message: errorMsg } };
  }
  
  // 确定实际使用的协议
  let actualProtocol = localHttps ? 'https' : 'http';
  
  hilog.info(DOMAIN, TAG, '[DBG-SEND]   negotiated protocol=%{public}s', actualProtocol);
  
  let target: NativeTargetDevice = {
    ip: device.ip,
    port: device.port,
    fingerprint: device.fingerprint,
    protocol: actualProtocol,
    publicKey: device.publicKey
  };
  let nativeFiles: Array<NativeFileToSend> = [];
  for (let i = 0; i < files.length; i++) {
    let f = files[i];
    nativeFiles.push({
      fileId: f.fileId,
      filePath: f.filePath,
      fileName: f.fileName,
      fileType: f.fileType,
      size: f.size,
      preview: f.preview,
      sha256: f.hash
    });
  }
  addLog('info', 'Target: ' + actualProtocol + '://' + device.ip + ':' + device.port);
  try {
    hilog.info(DOMAIN, TAG, '[DBG-SEND]   calling nativeSendFiles...');
    let result = await nativeSendFiles(target, getDeviceAlias(), nativeFiles);
    hilog.info(DOMAIN, TAG, '[DBG-SEND]   nativeSendFiles returned: success=%{public}s sessionId=%{public}s failedCount=%{public}d error=%{public}s',
      result.success.toString(), shortSid(result.sessionId), result.failedFiles.length,
      result.error !== undefined ? result.error.kind + '(' + (result.error.status !== undefined ? result.error.status : '') + ')' : 'none');
    if (result.success) {
      addLog('info', 'Send success, session=' + result.sessionId.substring(0, 8));
      notifyChange();
      return { success: true };
    } else {
      if (result.error !== undefined && result.error.kind === 'statusCode' && result.error.status === 204 && isTextOnlySend(files)) {
        addLog('info', 'Text message delivered (204 = preview-only delivery)');
        notifyChange();
        return { success: true };
      }
      let errorMsg = 'Send failed: ' + result.failedFiles.join(', ');
      if (result.error !== undefined && result.error.message !== undefined) {
        errorMsg = result.error.message;
      }
      addLog('error', errorMsg);
      for (let i = 0; i < result.failedFiles.length; i++) {
        hilog.error(DOMAIN, TAG, '  failed file: %{public}s', result.failedFiles[i]);
      }
      notifyChange();
      return { success: false, error: result.error };
    }
  } catch (e) {
    let errorMsg = 'Send error: ' + e;
    addLog('error', errorMsg);
    hilog.error(DOMAIN, TAG, 'Send exception details: %{public}s', JSON.stringify(e));
    notifyChange();
    return { success: false, error: { kind: 'other', message: String(e) } };
  } finally {
    drainNativeDebugLog();
  }
}

// Check if all files in this send are text-only (preview already contains the content)
function isTextOnlySend(files: Array<SendFileItem>): boolean {
  for (let i = 0; i < files.length; i++) {
    if (files[i].fileType !== 'text/plain') {
      return false;
    }
  }
  return files.length > 0;
}

function extractFileName(uri: string): string {
  let decoded = decodeURIComponent(uri);
  let idx = decoded.lastIndexOf('/');
  if (idx >= 0) {
    return decoded.substring(idx + 1);
  }
  return '';
}

function getMimeForExt(fileName: string): string {
  return mimeGetMimeForFileName(fileName);
}

function resolveDestPath(sendDir: string, name: string): string {
  let result = sendDir + name;
  if (!fs.accessSync(result)) {
    return result;
  }
  let dot = name.lastIndexOf('.');
  let base: string;
  let ext: string;
  if (dot >= 0) {
    base = name.substring(0, dot);
    ext = name.substring(dot);
  } else {
    base = name;
    ext = '';
  }
  for (let n = 1; n < 999; n++) {
    let candidate = sendDir + base + ' (' + n + ')' + ext;
    if (!fs.accessSync(candidate)) {
      return candidate;
    }
  }
  return sendDir + base + ' (' + Date.now() + ')' + ext;
}

export async function prepareSendFiles(
  uris: Array<string>
): Promise<Array<SendFileItem>> {
  if (appContext === undefined) {
    return [];
  }
  let sendDir = appContext.filesDir + '/send/';
  try {
    fs.mkdirSync(sendDir);
  } catch (_e) {
  }
  let items: Array<SendFileItem> = [];
  for (let i = 0; i < uris.length; i++) {
    try {
      let uri = uris[i];
      let rawName = extractFileName(uri);
      if (rawName === '' || rawName.length > 200) {
        rawName = 'file_' + Date.now();
      }
      // Sanitize file name to ensure it's legal on the current platform
      rawName = nativeSanitizeFileName(rawName);
      let destPath = resolveDestPath(sendDir, rawName);
      let srcFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        fs.copyFileSync(srcFile.fd, destPath);
        let stat = fs.statSync(destPath);
        let finalName = destPath.substring(destPath.lastIndexOf('/') + 1);
        let finalType = getMimeForExt(finalName);
        let preview: string | undefined = undefined;
        if (finalType === 'text/plain' && stat.size > 0 && stat.size < 1024 * 1024) {
          try {
            preview = fs.readTextSync(destPath);
          } catch (_e) {
          }
        }
        items.push({
          fileId: 'send_' + i + '_' + Date.now(),
          filePath: destPath,
          fileName: finalName,
          fileType: finalType,
          size: stat.size,
          preview: preview
        });
      } finally {
        fs.closeSync(srcFile);
      }
    } catch (e) {
      addLog('error', 'Failed to prepare file: ' + e);
    }
  }
  return items;
}

export function markSendCompleted(): void {
  pendingSendCompleted = true;
}

export function isSendCompletedAndReset(): boolean {
  if (pendingSendCompleted) {
    pendingSendCompleted = false;
    cleanupSendDir();
    return true;
  }
  return false;
}

function cleanupSendDir(): void {
  if (appContext === undefined) {
    return;
  }
  let sendDir = appContext.filesDir + '/send/';
  try {
    let entries = fs.listFileSync(sendDir);
    for (let i = 0; i < entries.length; i++) {
      try {
        fs.unlinkSync(sendDir + entries[i]);
      } catch (_e) {
      }
    }
  } catch (_e) {
  }
}

export function processSharedUris(urisJson: string): Array<StagedFile> {
  let uris: Array<string> = [];
  try {
    let parsed: Object = JSON.parse(urisJson);
    if (Array.isArray(parsed)) {
      uris = parsed as Array<string>;
    }
  } catch (_e) {
    return [];
  }

  const IMAGE_EXTS: Array<string> = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'svg'];
  let result: Array<StagedFile> = [];

  for (let i = 0; i < uris.length; i++) {
    let uri: string = uris[i];
    let decoded: string = decodeURIComponent(uri);
    let lastSlash: number = decoded.lastIndexOf('/');
    let fileName: string = lastSlash >= 0 ? decoded.substring(lastSlash + 1) : 'file_' + Date.now();
    let dot: number = fileName.lastIndexOf('.');
    let ext: string = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
    let isImg: boolean = IMAGE_EXTS.indexOf(ext) >= 0;
    let mime: string = getMimeFromFileName(ext);
    result.push({
      uri: uri,
      fileName: fileName,
      fileType: mime,
      isImage: isImg
    });
  }

  return result;
}

function getMimeFromFileName(ext: string): string {
  return mimeGetMimeForExt(ext);
}

// ════════════════════════════════════════════════════════════
// ── Settings setters for feature alignment ──
// ════════════════════════════════════════════════════════════


export function setQuickSaveMode(mode: QuickSaveMode): void {
  quickSaveMode = mode;
  preferencesUtil.setString(KEY_AUTO_SAVE_MODE, mode);
  AppStorage.setOrCreate(KEY_AUTO_SAVE_MODE, mode);
  notifyChange();
}

export function getReceivePin(): string {
  return receivePin;
}

export function setReceivePin(pin: string): void {
  receivePin = pin;
  preferencesUtil.setString(KEY_RECEIVE_PIN, pin);
  AppStorage.setOrCreate(KEY_RECEIVE_PIN, pin);
  // PIN change requires server restart
  markServerNeedsRestart();
  notifyChange();
}

export function setAutoFinish(enabled: boolean): void {
  autoFinish = enabled;
  preferencesUtil.setBoolean(KEY_AUTO_FINISH, enabled);
  AppStorage.setOrCreate(KEY_AUTO_FINISH, enabled);
  notifyChange();
}

export function isAutoFinish(): boolean {
  return autoFinish;
}

export function setSaveToHistory(enabled: boolean): void {
  saveToHistory = enabled;
  preferencesUtil.setBoolean(KEY_SAVE_TO_HISTORY, enabled);
  AppStorage.setOrCreate(KEY_SAVE_TO_HISTORY, enabled);
  notifyChange();
}

export function isSaveToHistory(): boolean {
  return saveToHistory;
}

export function setSaveToGallery(enabled: boolean): void {
  saveToGallery = enabled;
  preferencesUtil.setBoolean(KEY_SAVE_TO_GALLERY, enabled);
  AppStorage.setOrCreate(KEY_SAVE_TO_GALLERY, enabled);
  notifyChange();
}

export function isSaveToGallery(): boolean {
  return saveToGallery;
}

export function setDestination(path: string): void {
  destination = path;
  preferencesUtil.setString(KEY_DESTINATION, path);
  AppStorage.setOrCreate(KEY_DESTINATION, path);
  notifyChange();
}


export function setTheme(mode: string): void {
  theme = mode;
  preferencesUtil.setString(KEY_THEME, mode);
  AppStorage.setOrCreate(KEY_THEME, mode);
  // Apply system color mode based on theme setting
  try {
    if (appContext) {
      let appCtx = appContext.getApplicationContext();
      if (mode === 'light') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (mode === 'dark') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    }
  } catch (_e) {
    hilog.warn(DOMAIN, TAG, 'setTheme: applyColorMode failed');
  }
  notifyChange();
}

export function setLocale(lang: string): void {
  locale = lang;
  preferencesUtil.setString(KEY_LOCALE, lang);
  AppStorage.setOrCreate(KEY_LOCALE, lang);
  // Apply locale via i18n API
  try {
    if (lang === 'system' || lang === '') {
      // Explicitly set system language instead of 'default' for immediate effect
      let sysLang = i18n.System.getSystemLanguage();
      i18n.System.setAppPreferredLanguage(sysLang);
    } else if (lang === 'zh') {
      i18n.System.setAppPreferredLanguage('zh-Hans');
    } else if (lang === 'zh-TW') {
      i18n.System.setAppPreferredLanguage('zh-Hant');
    } else if (lang === 'en') {
      i18n.System.setAppPreferredLanguage('en-US');
    } else {
      i18n.System.setAppPreferredLanguage(lang);
    }
  } catch (_e) {
    hilog.warn(DOMAIN, TAG, 'setAppPreferredLanguage failed');
  }
  notifyChange();
}

export function setEnableAnimations(enabled: boolean): void {
  enableAnimations = enabled;
  preferencesUtil.setBoolean(KEY_ENABLE_ANIMATIONS, enabled);
  AppStorage.setOrCreate(KEY_ENABLE_ANIMATIONS, enabled);
  notifyChange();
}

export function isEnableAnimations(): boolean {
  return enableAnimations;
}

export function setCreateChecksums(enabled: boolean): void {
  createChecksums = enabled;
  preferencesUtil.setBoolean(KEY_CREATE_CHECKSUMS, enabled);
  AppStorage.setOrCreate(KEY_CREATE_CHECKSUMS, enabled);
  notifyChange();
}

export function isCreateChecksums(): boolean {
  return createChecksums;
}

export function setVerifyChecksums(enabled: boolean): void {
  verifyChecksums = enabled;
  preferencesUtil.setBoolean(KEY_VERIFY_CHECKSUMS, enabled);
  AppStorage.setOrCreate(KEY_VERIFY_CHECKSUMS, enabled);
  notifyChange();
}

export function isVerifyChecksums(): boolean {
  return verifyChecksums;
}

export function setSendMode(mode: SendMode): void {
  sendMode = mode;
  preferencesUtil.setString(KEY_SEND_MODE, mode);
  AppStorage.setOrCreate(KEY_SEND_MODE, mode);
  notifyChange();
}

export function getSendMode(): SendMode {
  // If current mode is 'link' but link sharing is hidden, fall back to 'single'
  if (sendMode === SendMode.link) {
    let hideShareByLink: boolean = preferencesUtil.getBoolean(KEY_HIDE_SHARE_BY_LINK, false);
    if (hideShareByLink) {
      sendMode = SendMode.single;
      preferencesUtil.setString(KEY_SEND_MODE, SendMode.single);
      AppStorage.setOrCreate(KEY_SEND_MODE, SendMode.single);
    }
  }
  return sendMode;
}

export function setAdvancedSettings(enabled: boolean): void {
  advancedSettings = enabled;
  preferencesUtil.setBoolean(KEY_ADVANCED_SETTINGS, enabled);
  AppStorage.setOrCreate(KEY_ADVANCED_SETTINGS, enabled);
  notifyChange();
}

export function isAdvancedSettings(): boolean {
  return advancedSettings;
}

export function setShareViaLinkAutoAccept(enabled: boolean): void {
  shareViaLinkAutoAccept = enabled;
  preferencesUtil.setBoolean(KEY_SHARE_VIA_LINK_AUTO_ACCEPT, enabled);
  AppStorage.setOrCreate(KEY_SHARE_VIA_LINK_AUTO_ACCEPT, enabled);
  notifyChange();
}

export function setReceiveViaLinkAutoAccept(enabled: boolean): void {
  receiveViaLinkAutoAccept = enabled;
  preferencesUtil.setBoolean(KEY_RECEIVE_VIA_LINK_AUTO_ACCEPT, enabled);
  AppStorage.setOrCreate(KEY_RECEIVE_VIA_LINK_AUTO_ACCEPT, enabled);
  notifyChange();
}

export function setPort(p: number): void {
  port = p;
  preferencesUtil.setNumber(KEY_PORT, p);
  AppStorage.setOrCreate(KEY_PORT, p);
  markServerNeedsRestart();
  notifyChange();
}

export function getPort(): number {
  return port;
}

export function setMulticastGroup(group: string): void {
  multicastGroup = group;
  preferencesUtil.setString(KEY_MULTICAST_GROUP, group);
  AppStorage.setOrCreate(KEY_MULTICAST_GROUP, group);
  markServerNeedsRestart();
  notifyChange();
}

export function getMulticastGroup(): string {
  return multicastGroup;
}

export function setDiscoveryTimeout(timeout: number): void {
  discoveryTimeout = timeout;
  preferencesUtil.setNumber(KEY_DISCOVERY_TIMEOUT, timeout);
  AppStorage.setOrCreate(KEY_DISCOVERY_TIMEOUT, timeout);
  markServerNeedsRestart();
  notifyChange();
}

export function setNetworkWhitelist(list: string): void {
  preferencesUtil.setString(KEY_NETWORK_WHITELIST, list);
  AppStorage.setOrCreate(KEY_NETWORK_WHITELIST, list);
  markServerNeedsRestart();
  notifyChange();
}

export function setNetworkBlacklist(list: string): void {
  preferencesUtil.setString(KEY_NETWORK_BLACKLIST, list);
  AppStorage.setOrCreate(KEY_NETWORK_BLACKLIST, list);
  markServerNeedsRestart();
  notifyChange();
}

export function doesServerNeedRestart(): boolean {
  return serverNeedsRestart;
}

function markServerNeedsRestart(): void {
  serverNeedsRestart = true;
  AppStorage.setOrCreate(APP_KEY_SERVER_NEEDS_RESTART, true);
}

export function clearServerNeedsRestart(): void {
  serverNeedsRestart = false;
  AppStorage.setOrCreate(APP_KEY_SERVER_NEEDS_RESTART, false);
}

export function getReceiveHistory(): Array<ReceiveHistoryEntry> {
  return getHistory();
}

export function getFavoriteDevices(): Array<FavoriteDevice> {
  return getFavorites();
}

// ── Server control methods ──

/** Query native layer for actual server state and sync to JS/AppStorage */
function syncServerState(): boolean {
  try {
    let status = nativeGetServerStatus();
    serverRunning = status.running;
    if (status.fingerprint !== undefined && status.fingerprint.length > 0) {
      serverFingerprint = status.fingerprint;
    }
  } catch (_e) {
    // Native query failed — keep current JS state
  }
  AppStorage.setOrCreate(APP_KEY_SERVER_READY, serverRunning);
  return serverRunning;
}

export async function startServer(): Promise<string> {
  // If native server reports running, do a clean stop first
  try {
    let status = nativeGetServerStatus();
    if (status.running) {
      await stopLocalServer();
    }
  } catch (_e) {}
  return await startLocalServer();
}

export async function stopServer(): Promise<void> {
  await stopLocalServer();
  syncServerState();
}

export async function restartServer(): Promise<void> {
  clearServerNeedsRestart();
  // Always do a full stop + start to ensure clean state
  await stopLocalServer();
  try {
    await startLocalServer();
  } catch (_e) {
    // Start failed — sync real state
    syncServerState();
  }
}

export async function restartServerFromSettings(): Promise<void> {
  clearServerNeedsRestart();
  await stopLocalServer();
  try {
    await startLocalServer();
  } catch (_e) {
    syncServerState();
  }
}

// ── QuickSave logic: determine if incoming request should be auto-accepted ──

export function shouldAutoAccept(senderFingerprint: string, hasMessage: boolean): boolean {
  // Text messages are never auto-accepted
  if (hasMessage) {
    return false;
  }
  if (quickSaveMode === QuickSaveMode.on) {
    return true;
  }
  if (quickSaveMode === QuickSaveMode.paired) {
    let favDevices: Array<FavoriteDevice> = getFavorites();
    for (let i = 0; i < favDevices.length; i++) {
      if (favDevices[i].fingerprint === senderFingerprint) {
        return true;
      }
    }
  }
  return false;
}

// ── Receive history recording ──

function recordReceiveHistory(sessionId: string, files: Array<ReceivedFileEntry>, senderAlias: string): void {
  if (!saveToHistory) {
    return;
  }
  for (let i = 0; i < files.length; i++) {
    let f = files[i];
    // Try to get actual file size from disk
    let fileSize: number = 0;
    if (f.filePath.length > 0) {
      try {
        let stat = fs.statSync(f.filePath);
        fileSize = stat.size;
      } catch (_e) {
        // Fallback: try to get size from pending request data
        let reqFiles = sessionFileMap[sessionId];
        if (reqFiles !== undefined) {
          for (let j = 0; j < reqFiles.length; j++) {
            if (reqFiles[j].fileId === f.fileId) {
              // Size was not stored in ReceivedFileEntry; use 0 as fallback
              break;
            }
          }
        }
      }
    }
    let entry: ReceiveHistoryEntry = {
      id: sessionId + '_' + i,
      fileName: f.fileName,
      fileType: f.fileType,
      path: f.filePath,
      savedToGallery: saveToGallery,
      isMessage: f.fileType === 'text/plain',
      fileSize: fileSize,
      senderAlias: senderAlias,
      timestamp: Date.now()
    };
    addHistoryEntry(entry);
  }
}

// ── Auto-finish logic ──

function shouldAutoFinishSession(sessionId: string, hasErrors: boolean): boolean {
  if (!autoFinish) {
    return false;
  }
  if (hasErrors) {
    return false;
  }
  return true;
}

// ── Send session management ──

export function getSendSessions(): Array<SendSessionState> {
  let result: Array<SendSessionState> = [];
  sendSessions.forEach((state: SendSessionState) => {
    result.push(state);
  });
  return result;
}

export function createSendSession(sessionId: string, targetIp: string, targetAlias: string, files: Array<SendFileItem>): void {
  let state: SendSessionState = {
    sessionId: sessionId,
    targetIp: targetIp,
    targetAlias: targetAlias,
    status: SendSessionStatus.waiting,
    files: files,
    hashedFileCount: 0,
    totalFiles: files.length
  };
  sendSessions.set(sessionId, state);
  notifyChange();
}

export function clearAllSendSessions(): void {
  sendSessions.clear();
  notifyChange();
}

function updateSendSessionStatus(sessionId: string, status: SendSessionStatus): void {
  let state = sendSessions.get(sessionId);
  if (state !== undefined) {
    state.status = status;
    // Auto-cleanup terminal sessions after a delay
    if (status === SendSessionStatus.finished || status === SendSessionStatus.finishedWithErrors ||
        status === SendSessionStatus.declined) {
      setTimeout(() => {
        sendSessions.delete(sessionId);
        notifyChange();
      }, 5000);
    }
    notifyChange();
  }
}


function updateSendSessionHashProgress(sessionId: string, hashedCount: number): void {
  let state = sendSessions.get(sessionId);
  if (state !== undefined) {
    state.hashedFileCount = hashedCount;
    if (hashedCount >= state.totalFiles) {
      state.status = SendSessionStatus.waiting;
    } else {
      state.status = SendSessionStatus.calculatingHash;
    }
    checksumProgress = hashedCount;
    checksumTotal = state.totalFiles;
    AppStorage.setOrCreate(APP_KEY_CHECKSUM_PROGRESS, hashedCount);
    AppStorage.setOrCreate(APP_KEY_CHECKSUM_TOTAL, state.totalFiles);
    notifyChange();
  }
}

export function getChecksumProgress(): number {
  return checksumProgress;
}

export function getChecksumTotal(): number {
  return checksumTotal;
}

// ── Multi-device send: send to multiple devices in parallel ──

export async function sendToDeviceMulti(
  devices: Array<DiscoveredDevice>,
  files: Array<SendFileItem>
): Promise<void> {
  // Create independent sessions for each device, using consistent sessionIds
  let sessionIds: Array<string> = [];
  for (let i = 0; i < devices.length; i++) {
    let sessionId = 'multi_' + Date.now() + '_' + i;
    sessionIds.push(sessionId);
    let device = devices[i];
    createSendSession(sessionId, device.ip, device.alias, files);
  }

  // Send to each device in parallel
  let promises: Array<Promise<SendResult>> = [];
  for (let i = 0; i < devices.length; i++) {
    let device = devices[i];
    promises.push(sendToDeviceWithSession(device, files, sessionIds[i]));
  }

  // Wait for all sends to complete (but don't block on errors)
  let results = await Promise.all(promises);

  // Update session statuses for successful sends only
  // Failed sends already have precise statuses set by sendToDeviceWithSession (declined, tooManyAttempts, etc.)
  for (let i = 0; i < devices.length; i++) {
    if (results[i].success) {
      updateSendSessionStatus(sessionIds[i], SendSessionStatus.finished);
    }
  }
  notifyChange();
}

async function sendToDeviceWithSession(
  device: DiscoveredDevice,
  files: Array<SendFileItem>,
  sessionId: string
): Promise<SendResult> {
  updateSendSessionStatus(sessionId, SendSessionStatus.sending);
  let result = await sendToDevice(device, files);
  if (result.success) {
    // Success status will be set by sendToDeviceMulti
  } else if (result.error !== undefined) {
    let err = result.error;
    if (err.kind === 'statusCode' && err.status !== undefined) {
      let status = err.status;
      if (status === 401) {
        updateSendSessionStatus(sessionId, SendSessionStatus.waiting);
        AppStorage.setOrCreate(APP_PREFIX_SEND_PIN_REQUIRED + sessionId, JSON.stringify({
          sessionId: sessionId,
          deviceAlias: device.alias,
          deviceIp: device.ip,
          httpStatus: 401
        }));
      } else if (status === 429) {
        updateSendSessionStatus(sessionId, SendSessionStatus.tooManyAttempts);
        AppStorage.setOrCreate(APP_PREFIX_SEND_PIN_REQUIRED + sessionId, JSON.stringify({
          sessionId: sessionId,
          deviceAlias: device.alias,
          deviceIp: device.ip,
          httpStatus: 429
        }));
      } else if (status === 403) {
        updateSendSessionStatus(sessionId, SendSessionStatus.declined);
      } else if (status === 204 && isTextOnlySend(files)) {
        updateSendSessionStatus(sessionId, SendSessionStatus.finished);
        return { success: true };
      } else {
        updateSendSessionStatus(sessionId, SendSessionStatus.finishedWithErrors);
      }
    } else {
      let msg = err.message !== undefined ? err.message : '';
      if (msg.indexOf('declined') >= 0 || msg.indexOf('rejected') >= 0) {
        updateSendSessionStatus(sessionId, SendSessionStatus.declined);
      } else {
        updateSendSessionStatus(sessionId, SendSessionStatus.finishedWithErrors);
      }
    }
  } else {
    // No error info — generic failure
    updateSendSessionStatus(sessionId, SendSessionStatus.finishedWithErrors);
  }
  return result;
}

// ── Checksum calculation ──
// NOTE: nativeCalculateFileHash is a placeholder - Rust lib may not support it yet

let activeHashCancelId: string = '';

export async function calculateChecksumsForFiles(
  sessionId: string,
  files: Array<SendFileItem>
): Promise<void> {
  if (!createChecksums) {
    return;
  }
  updateSendSessionStatus(sessionId, SendSessionStatus.calculatingHash);
  let hashedCount = 0;
  for (let i = 0; i < files.length; i++) {
    try {
      let token = nativeCreateCancelToken();
      activeHashCancelId = token.id;
      let hash = await nativeHashFileStream(files[i].filePath, token.id);
      activeHashCancelId = '';
      files[i].hash = hash;
      hashedCount = hashedCount + 1;
      updateSendSessionHashProgress(sessionId, hashedCount);
    } catch (_e) {
      activeHashCancelId = '';
      files[i].hash = '';
      hashedCount = hashedCount + 1;
      updateSendSessionHashProgress(sessionId, hashedCount);
    }
  }
  updateSendSessionStatus(sessionId, SendSessionStatus.waiting);
}

export function cancelChecksumCalculation(): void {
  if (activeHashCancelId.length > 0) {
    nativeCancelHash(activeHashCancelId);
    activeHashCancelId = '';
  }
}

export function reportFileDownloadFailure(sessionId: string, fileId: string): void {
  nativeFailFileDownload(sessionId, fileId);
}

export function reportFileUploadFailure(sessionId: string, fileId: string): void {
  nativeFailFileUpload(sessionId, fileId);
}

// ── Download API (reverse file transfer) ──

export interface DownloadSessionInfo {
  alias: string
  version: string
  deviceModel: string
  deviceType: string
  fingerprint: string
  download: boolean
  port: number
  protocol: string
  sessionId: string
  files: Record<string, Object>
}

export async function prepareDownloadFromDevice(
  device: DiscoveredDevice,
  sessionId?: string,
  pin?: string
): Promise<DownloadSessionInfo | undefined> {
  let protocol = device.protocol;
  try {
    let resultStr = await nativePrepareDownload(device.ip, device.port, protocol, sessionId, pin);
    let data: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
    let info: Record<string, Object> = {};
    if (data['info'] !== undefined && typeof data['info'] === 'object') {
      info = data['info'] as Record<string, Object>;
    }
    let filesObj: Record<string, Object> = {};
    if (data['files'] !== undefined && typeof data['files'] === 'object') {
      filesObj = data['files'] as Record<string, Object>;
    }
    return {
      alias: info['alias'] !== undefined ? info['alias'] as string : '',
      version: info['version'] !== undefined ? info['version'] as string : '',
      deviceModel: info['deviceModel'] !== undefined ? info['deviceModel'] as string : '',
      deviceType: info['deviceType'] !== undefined ? info['deviceType'] as string : 'desktop',
      fingerprint: info['fingerprint'] !== undefined ? info['fingerprint'] as string : '',
      download: info['download'] !== undefined ? info['download'] as boolean : false,
      port: info['port'] !== undefined ? info['port'] as number : device.port,
      protocol: info['protocol'] !== undefined ? info['protocol'] as string : protocol,
      sessionId: data['sessionId'] !== undefined ? data['sessionId'] as string : '',
      files: filesObj
    };
  } catch (e) {
    addLog('error', 'Prepare download failed: ' + e);
    return undefined;
  }
}

export async function downloadFileFromDevice(
  device: DiscoveredDevice,
  sessionId: string,
  fileId: string,
  savePath: string
): Promise<boolean> {
  let protocol = device.protocol;
  if (protocol === 'http') {
    addLog('warn', 'Downloading via unencrypted HTTP — data is not protected in transit');
  }
  try {
    await nativeDownloadFile(device.ip, device.port, protocol, sessionId, fileId, savePath, device.publicKey);
    addLog('info', 'Downloaded file: ' + fileId + ' -> ' + savePath);
    return true;
  } catch (e) {
    addLog('error', 'Download file failed: ' + e);
    return false;
  }
}

// ── Discovery diagnostics ──

export function getMulticastError(): string {
  return nativeDiscoveryMulticastError();
}

export function getDeviceByFingerprint(fingerprint: string): DiscoveredDevice | undefined {
  return nativeDiscoveryGetDevice(fingerprint);
}

// ── Manual IP connect ──

export async function connectByIp(targetIp: string, targetPort: number): Promise<DiscoveredDevice | undefined> {
  let protocol = httpsEnabled ? 'https' : 'http';
  try {
    let resultStr = await nativeClientInfo(protocol, targetIp, targetPort);
    let data: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
    let deviceTypeRaw: Object | undefined = data['deviceType'];
    let deviceType: string = 'mobile';
    if (deviceTypeRaw !== undefined && deviceTypeRaw !== null) {
      deviceType = deviceTypeRaw as string;
    }
    let fingerprint: string = data['fingerprint'] !== undefined ? data['fingerprint'] as string : '';
    let dev: DiscoveredDevice = {
      alias: data['alias'] !== undefined ? data['alias'] as string : '',
      ip: targetIp,
      port: targetPort,
      fingerprint: fingerprint,
      version: data['version'] !== undefined ? data['version'] as string : '',
      deviceModel: data['deviceModel'] !== undefined ? data['deviceModel'] as string : '',
      deviceType: deviceType,
      protocol: data['protocol'] !== undefined ? data['protocol'] as string : protocol,
      lastSeen: Date.now(),
      channels: [{ host: targetIp, port: targetPort, protocol: protocol }]
    };
    let nativeDev: NativeDiscoveredDevice = {
      alias: dev.alias,
      fingerprint: dev.fingerprint,
      version: dev.version,
      deviceModel: dev.deviceModel,
      deviceType: dev.deviceType,
      download: data['download'] !== undefined ? data['download'] as boolean : false,
      host: targetIp,
      port: targetPort,
      protocol: dev.protocol,
      channels: [{ host: targetIp, port: targetPort, protocol: protocol }]
    };
    nativeDiscoveryAddDevice(nativeDev).catch((_e: Error) => {});
    return dev;
  } catch (e) {
    addLog('warn', 'Connect by IP failed: ' + e);
    return undefined;
  }
}

export async function registerToRemoteDevice(targetIp: string, targetPort: number): Promise<NativeRegisterResult | undefined> {
  let protocol = httpsEnabled ? 'https' : 'http';
  try {
    let result = await nativeRegisterDevice(
      targetIp, targetPort,
      alias, serverFingerprint, protocol,
      deviceModel, deviceType, port,
      getLocalIp()
    );
    let nativeDev: NativeDiscoveredDevice = {
      alias: result.alias,
      fingerprint: result.fingerprint,
      version: result.version,
      deviceModel: result.deviceModel,
      deviceType: result.deviceType,
      download: false,
      host: targetIp,
      port: targetPort,
      protocol: result.protocol,
      channels: [{ host: targetIp, port: targetPort, protocol: protocol }]
    };
    nativeDiscoveryAddDevice(nativeDev).catch((_e: Error) => {});
    if (result.publicKey.length > 0 && result.fingerprint.length > 0) {
      for (let i = 0; i < discoveredDevices.length; i++) {
        if (discoveredDevices[i].fingerprint === result.fingerprint) {
          discoveredDevices[i].publicKey = result.publicKey;
          break;
        }
      }
    }
    return result;
  } catch (e) {
    addLog('warn', 'Register to remote failed: ' + e);
    return undefined;
  }
}

// ── Buffer Upload ──

export async function uploadBufferToDevice(
  targetIp: string,
  port: number,
  protocol: string,
  sessionId: string,
  fileId: string,
  token: string,
  buffer: ArrayBuffer,
  publicKey?: string,
  cancelId?: string
): Promise<boolean> {
  try {
    await nativeUploadFromBuffer(targetIp, port, protocol, sessionId, fileId, token, buffer, publicKey, cancelId);
    addLog('info', 'Buffer uploaded: ' + fileId);
    return true;
  } catch (e) {
    addLog('error', 'Buffer upload failed: ' + e);
    return false;
  }
}

// ── In-memory Hash ──

export function hashBufferSync(buffer: ArrayBuffer): string {
  return nativeHashBuffer(buffer);
}

// ── Web Share exit restore ──



