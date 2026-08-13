import { nativeCreateServer, nativeStopServer, nativeGetServerStatus,
  nativePollPendingRequests, nativePollProgress, nativePollSendProgress,
  nativeRespondTransfer, nativeSendFiles,
  nativeCreateShareLink, nativeStopShareServer, nativePollShareProgress, nativeGetRecvDiag,
  nativePollDebugLog, verifyNativeVersion, getNativeLibraryVersion,
  nativeHashFile, nativeSanitizeFileName, nativeIsValidFileName } from './NativeBridge';
import { startDiscovery, stopDiscovery, sendAnnounceNow, scanSubnetHttp, scanFavoriteDevices } from './DiscoveryService';
import { DiscoveredDevice, PendingRequest, PendingRequestFile,
  TransferProgress, SendFileItem, LogEntry, LocalDeviceInfo, StagedFile,
  QuickSaveMode, SendSessionStatus, SendMode,
  FavoriteDevice, ReceiveHistoryEntry, SendSessionState,
  NetworkInterface, NetworkType
} from '../model/Types';
import { NativeTargetDevice, NativeFileToSend, CANCEL_EVENT_FILE_ID, NativeProgressInfo, NativeServerHandle } from '../model/NativeTypes';
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
  KEY_FAVORITE_DEVICES, KEY_RECEIVE_HISTORY, KEY_HIDE_SHARE_BY_LINK, KEY_SILENT_RECEIVE } from '../utils/PreferencesUtil';
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
const POLL_INTERVAL_MS = 500;
const DEVICE_EXPIRY_MS = 120000;
const KEEPALIVE_INTERVAL_MS = 60000;

// 发送结果接口
export interface SendResult {
  success: boolean;
  error?: string; // 详细错误信息
}

// Favorite device scan target
interface FavoriteScanTarget {
  ip: string;
  port: number;
  fingerprint: string;
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
let pollTimer: number | undefined = undefined;
let keepaliveTimer: number | undefined = undefined;
let alias = '';
let deviceModel = '';
let deviceType = 'mobile';
let changeCallbacks: Array<() => void> = [];
let requestDoNotDisturb: Array<string> = [];
let isReloading = false;
let pendingSendCompleted = false;
let pollInProgress = false;  // Guard against concurrent doPollProgress execution

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

export function initAppService(context: common.UIAbilityContext): void {
  // Verify native library version on startup
  try {
    verifyNativeVersion();
    hilog.info(0x0000, 'AppService', `Native library version: ${getNativeLibraryVersion()}`);
  } catch (e) {
    hilog.error(0x0000, 'AppService', `Native version check failed: ${e}`);
    // Continue anyway - version mismatch is a warning, not a fatal error
  }
  
  appContext = context;
  httpsEnabled = preferencesUtil.getBoolean(KEY_ENCRYPTED_TRANSFER, true);

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
  AppStorage.setOrCreate('autoSaveMode', quickSaveMode);
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
  AppStorage.setOrCreate('serverReady', false);
  AppStorage.setOrCreate('serverNeedsRestart', false);
  AppStorage.setOrCreate('serverError', '');
  AppStorage.setOrCreate('checksumProgress', 0);
  AppStorage.setOrCreate('checksumTotal', 0);
  AppStorage.setOrCreate(KEY_FAVORITE_DEVICES, JSON.stringify(getFavorites()));
  AppStorage.setOrCreate(KEY_RECEIVE_HISTORY, JSON.stringify(getHistory()));
  AppStorage.setOrCreate(KEY_HIDE_SHARE_BY_LINK, preferencesUtil.getBoolean(KEY_HIDE_SHARE_BY_LINK, false));
  AppStorage.setOrCreate(KEY_SILENT_RECEIVE, preferencesUtil.getBoolean(KEY_SILENT_RECEIVE, false));

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
    await stopDiscovery();
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
    AppStorage.setOrCreate('serverReady', true);

    await startDiscovery(alias, handle.fingerprint, onDeviceDiscovered, protocol, deviceModel, deviceType, port);
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
      AppStorage.setOrCreate('serverReady', true);
      await startDiscovery(savedAlias, handle.fingerprint, onDeviceDiscovered, protocol, savedDeviceModel, savedDeviceType, port);
      addLog('warn', 'Rollback OK, server running with previous settings');
    } catch (rollbackError) {
      serverRunning = false;
      AppStorage.setOrCreate('serverReady', false);
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
  httpsEnabled = enabled;
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
    let localIp = getLocalIp();
    shareLinkInfo = (httpsEnabled ? 'https' : 'http') + '://' + localIp + ':' + sharePort;
    addLog('info', 'Share link created: ' + shareLinkInfo);
  } catch (e) {
    addLog('error', 'Share link failed: ' + e);
  }
  notifyChange();
}

export async function stopShareLink(): Promise<void> {
  try {
    await nativeStopShareServer();
  } catch (_e) {
  }
  shareLinkInfo = '';
  sharePort = 0;
  addLog('info', 'Share server stopped');
  notifyChange();
}

export function getDiscoveredDevices(): Array<DiscoveredDevice> {
  let now = Date.now();
  let valid: Array<DiscoveredDevice> = [];
  for (let i = 0; i < discoveredDevices.length; i++) {
    if (now - discoveredDevices[i].lastSeen < DEVICE_EXPIRY_MS) {
      valid.push(discoveredDevices[i]);
    }
  }
  discoveredDevices = valid;
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
  // 返回默认网络的IP
  for (let i = 0; i < localInterfaces.length; i++) {
    if (localInterfaces[i].isDefault) {
      return localInterfaces[i].ip;
    }
  }
  // 如果没有默认网络，返回第一个
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

function fmtNativeProgress(items: Array<NativeProgressInfo>): string {
  if (items.length === 0) {
    return '';
  }
  let parts: Array<string> = [];
  for (let i = 0; i < items.length; i++) {
    let p = items[i];
    parts.push('sid=' + shortSid(p.sessionId) + ' fid=' + p.fileId +
      ' ' + p.bytesSent + '/' + p.totalBytes);
  }
  return parts.join(' | ');
}

export async function startLocalServer(): Promise<string> {
  if (appContext === undefined) {
    addLog('error', 'AppService not initialized');
    return '';
  }
  
  // 更新本地网卡列表
  updateLocalInterfaces();
  addLog('info', `Local interfaces: ${localInterfaces.map(i => `${i.ip}(${i.type})`).join(', ')}`);
  
  let saveDir = appContext.filesDir + '/LocalSend/';
  try {
    fs.mkdirSync(saveDir);
  } catch (_e) {
  }
  let protocol = httpsEnabled ? 'https' : 'http';
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
    AppStorage.setOrCreate('serverReady', false);
    let errorMsg = String(e);
    // Detect port-in-use errors and provide user-friendly message
    if (errorMsg.indexOf('in use') >= 0 || errorMsg.indexOf('EADDRINUSE') >= 0 ||
        errorMsg.indexOf('Address already') >= 0) {
      let portMsg = appContext !== undefined
        ? appContext.resourceManager.getStringSync($r('app.string.port_in_use_error').id).replace('%d', String(port))
        : 'Port ' + port + ' is already in use';
      AppStorage.setOrCreate('serverError', portMsg);
      addLog('error', portMsg);
    } else {
      AppStorage.setOrCreate('serverError', errorMsg);
      addLog('error', 'Server start failed: ' + errorMsg);
    }
    return '';
  }
  // Clear any previous error
  AppStorage.setOrCreate('serverError', '');
  serverFingerprint = handle.fingerprint;
  serverRunning = true;
  AppStorage.setOrCreate('serverReady', true);
  addLog('info', 'Server started, fingerprint=' + handle.fingerprint.substring(0, 10) + '...');
  
  // 启动多网卡发现
  try {
    await startDiscovery(alias, handle.fingerprint, onDeviceDiscovered, protocol, deviceModel, deviceType, port, localInterfaces);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'startDiscovery FAILED: %{public}s', JSON.stringify(e));
    addLog('error', 'Discovery start failed: ' + e);
  }
  // 1-second fallback: if UDP multicast found few/no devices, supplement with HTTP subnet scan
  // This handles cases where multicast is blocked or devices haven't responded yet.
  // We also scan when device count is very low (< 3) since multicast may be partial.
  setTimeout(() => {
    if (serverRunning && discoveredDevices.length < 3) {
      hilog.info(DOMAIN, TAG, 'Few devices after 1s (%{public}d), triggering HTTP subnet scan', discoveredDevices.length);
      addLog('info', 'Supplementing UDP discovery with HTTP scan...');
      scanSubnetHttp(onDeviceDiscovered, alias, handle.fingerprint, protocol, deviceModel, deviceType, port, localInterfaces);
    }
  }, 1000);

  // Scan favorite devices' known IP:Port simultaneously (T039)
  let favDevices = getFavorites();
  if (favDevices.length > 0) {
    let favScanTargets: Array<FavoriteScanTarget> = [];
    for (let i = 0; i < favDevices.length; i++) {
      let target: FavoriteScanTarget = {
        ip: favDevices[i].ip,
        port: favDevices[i].port,
        fingerprint: favDevices[i].fingerprint
      };
      favScanTargets.push(target);
    }
    scanFavoriteDevices(favScanTargets, onDeviceDiscovered, alias, handle.fingerprint, protocol, deviceModel, deviceType, port).then(() => {
      addLog('info', 'Favorite device scan completed');
    }).catch((e: Error) => {
      addLog('warn', 'Favorite device scan failed: ' + e.message);
    });
  }
  startPolling();
  startKeepalive();
  notifyChange();
  return handle.fingerprint;
}

export async function stopLocalServer(): Promise<void> {
  stopPolling();
  stopKeepalive();
  try {
    await stopDiscovery();
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
  AppStorage.setOrCreate('serverReady', false);
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

function onDeviceDiscovered(
  dtoAlias: string, ip: string, port: number, fingerprint: string,
  version: string, deviceModel: string, deviceType: string, protocol: string
): void {
  // 以fingerprint为主键去重：同一设备只能有一个条目
  let existingIdx = -1;
  for (let i = 0; i < discoveredDevices.length; i++) {
    if (discoveredDevices[i].fingerprint === fingerprint) {
      existingIdx = i;
      break;
    }
  }
  if (existingIdx >= 0) {
    // 更新现有条目（保留最新信息）
    discoveredDevices[existingIdx].alias = dtoAlias;
    // 只有新IP不是回环地址时才更新（避免127.0.0.1覆盖真实IP）
    if (ip !== '127.0.0.1' && ip !== '0.0.0.0') {
      discoveredDevices[existingIdx].ip = ip;
    }
    discoveredDevices[existingIdx].port = port;
    // protocol优先级：https > http（同一设备如果支持https，不应该降级为http）
    if (protocol === 'https' || discoveredDevices[existingIdx].protocol !== 'https') {
      discoveredDevices[existingIdx].protocol = protocol;
    }
    discoveredDevices[existingIdx].deviceModel = deviceModel;
    discoveredDevices[existingIdx].deviceType = deviceType;
    discoveredDevices[existingIdx].version = version;
    discoveredDevices[existingIdx].lastSeen = Date.now();
  } else {
    discoveredDevices.push({
      alias: dtoAlias,
      ip: ip,
      port: port,
      fingerprint: fingerprint,
      version: version,
      deviceModel: deviceModel,
      deviceType: deviceType,
      protocol: protocol,
      lastSeen: Date.now()
    });
    addLog('info', 'Discovered: ' + dtoAlias + ' (' + ip + ')');
  }
  // Auto-sync alias for favorite devices (T040)
  syncAliasFromDiscovery(fingerprint, dtoAlias);
  notifyChange();
}

export function rescanDevices(): void {
  if (serverFingerprint.length > 0) {
    let protocol = httpsEnabled ? 'https' : 'http';
    sendAnnounceNow(alias, serverFingerprint, protocol, deviceModel, deviceType);
    scanSubnetHttp(onDeviceDiscovered, alias, serverFingerprint, protocol, deviceModel, deviceType, port, localInterfaces);
    addLog('info', 'Rescan: UDP announce + HTTP scan');
    notifyChange();
  }
}

function startPolling(): void {
  if (pollTimer !== undefined) {
    return;
  }
  pollTimer = setInterval(() => {
    doPollRequests();
    void doPollProgress();
  }, POLL_INTERVAL_MS);
}

function stopPolling(): void {
  if (pollTimer !== undefined) {
    clearInterval(pollTimer);
    pollTimer = undefined;
  }
}

function startKeepalive(): void {
  if (keepaliveTimer !== undefined) {
    return;
  }
  keepaliveTimer = setInterval(() => {
    if (serverRunning && serverFingerprint.length > 0) {
      rescanDevices();
    }
  }, KEEPALIVE_INTERVAL_MS);
}

function stopKeepalive(): void {
  if (keepaliveTimer !== undefined) {
    clearInterval(keepaliveTimer);
    keepaliveTimer = undefined;
  }
}

// ── Receive session state tracking ──
let receiveSessionStates: Record<string, string> = {}; // sessionId -> 'waiting'|'sending'|'finished'|'finishedWithErrors'|'canceledBySender'
let receiveSessionAutoAccepted: Record<string, boolean> = {}; // sessionId -> was auto-accepted
let receiveSessionSenderAlias: Record<string, string> = {}; // sessionId -> senderAlias for history recording


function doPollRequests(): void {
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
          AppStorage.setOrCreate('receiveSessionAutoAccepted_' + r.sessionId, true);
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

async function doPollProgress(): Promise<void> {
  if (!serverRunning) {
    return;
  }
  if (pollInProgress) {
    return;  // Skip if previous poll is still running (e.g. awaiting exportSessionFiles)
  }
  pollInProgress = true;
  try {
    let merged: Array<TransferProgress> = [];
  let raw = nativePollProgress();
  let diag = nativeGetRecvDiag();
  if (raw.length > 0 || diag.queuedEvents > 0 || diag.drainCount < 10) {
    hilog.info(0x0001, 'LocalSend:AppService',
      '[diag] recv raw=%{public}d drains=%{public}d queued=%{public}d firstPct=%{public}d%%',
      raw.length, diag.drainCount, diag.queuedEvents,
      raw.length > 0 && raw[0].totalBytes > 0 ? Math.floor(raw[0].bytesSent * 100 / raw[0].totalBytes) : 0
    );
  }
  if (raw.length > 0) {
    hilog.info(0x0001, 'LocalSend:AppService', '[recv-raw] count=%{public}d %{public}s',
      raw.length, fmtNativeProgress(raw));
  }
  let completedSessions: Array<string> = [];
  for (let i = 0; i < raw.length; i++) {
    let p = raw[i];
    // Detect cancel notification from Rust side
    if (p.fileId === CANCEL_EVENT_FILE_ID) {
      hilog.info(DOMAIN, TAG, '[doPollProgress] CANCEL_EVENT detected, sessionId=%{public}s', p.sessionId);
      AppStorage.setOrCreate('recvTransferCancelled', p.sessionId);
      // Update receive session state to canceledBySender
      receiveSessionStates[p.sessionId] = 'canceledBySender';
      let cleaned: Array<TransferProgress> = [];
      for (let j = 0; j < activeProgress.length; j++) {
        if (activeProgress[j].sessionId !== p.sessionId) {
          cleaned.push(activeProgress[j]);
        }
      }
      activeProgress = cleaned;
      continue;
    }
    merged.push({
      sessionId: p.sessionId,
      fileId: p.fileId,
      bytesSent: p.bytesSent,
      totalBytes: p.totalBytes,
      filePath: p.filePath
    });
    let key = p.sessionId + ':' + p.fileId;
    if (p.bytesSent >= p.totalBytes && p.totalBytes > 0 &&
      completedFileIds[key] === undefined) {
      completedFileIds[key] = true;
      completedFileCount++;
      // Periodically reset completedFileIds to prevent unbounded growth
      // (ArkTS does not allow delete on Record keys)
      if (completedFileCount > 500) {
        completedFileIds = {};
        completedFileCount = 0;
      }
      let prev = sessionCompletedCount[p.sessionId] || 0;
      sessionCompletedCount[p.sessionId] = prev + 1;
      let total = sessionTotalFiles[p.sessionId] || 0;
      if (sessionCompletedCount[p.sessionId] >= total && total > 0 &&
        sessionExported[p.sessionId] === undefined) {
        sessionExported[p.sessionId] = true;
        completedSessions.push(p.sessionId);
        hilog.info(0x0001, TAG,
          '[diag] session complete session=%{public}s cnt=%{public}d/%{public}d',
          p.sessionId, sessionCompletedCount[p.sessionId], sessionTotalFiles[p.sessionId] || 0);
      }
      let entries = sessionFileMap[p.sessionId];
      if (entries !== undefined) {
        for (let j = 0; j < entries.length; j++) {
          if (entries[j].fileId === p.fileId) {
            entries[j].filePath = p.filePath;
            break;
          }
        }
      }
    }
  }
  let sendRaw = nativePollSendProgress();
  if (sendRaw.length > 0) {
    hilog.info(0x0001, 'LocalSend:AppService', '[send-raw] count=%{public}d %{public}s',
      sendRaw.length, fmtNativeProgress(sendRaw));
  }
  for (let i = 0; i < sendRaw.length; i++) {
    let p = sendRaw[i];
    merged.push({
      sessionId: p.sessionId,
      fileId: p.fileId,
      bytesSent: p.bytesSent,
      totalBytes: p.totalBytes,
      filePath: p.filePath
    });
  }
  let shareRaw = nativePollShareProgress();
  if (shareRaw.length > 0) {
    hilog.info(0x0001, 'LocalSend:AppService', '[share-raw] count=%{public}d %{public}s',
      shareRaw.length, fmtNativeProgress(shareRaw));
  }
  for (let i = 0; i < shareRaw.length; i++) {
    let p = shareRaw[i];
    merged.push({
      sessionId: 'share-' + p.fileId,
      fileId: p.fileId,
      bytesSent: p.bytesSent,
      totalBytes: p.totalBytes,
      filePath: p.filePath
    });
  }
  if (merged.length > 0) {
    for (let i = 0; i < merged.length; i++) {
      let m = merged[i];
      let found: boolean = false;
      for (let j = 0; j < activeProgress.length; j++) {
        if (activeProgress[j].sessionId === m.sessionId &&
          activeProgress[j].fileId === m.fileId) {
          activeProgress[j] = m;
          found = true;
          break;
        }
      }
      if (!found) {
        activeProgress.push(m);
      }
    }
  }
  hilog.info(0x0001, 'LocalSend:AppService',
    '[merged] merged=%{public}d activeCount=%{public}d',
    merged.length, activeProgress.length);
  notifyChange();
  for (let s = 0; s < completedSessions.length; s++) {
    let sessionId = completedSessions[s];
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
        AppStorage.setOrCreate('recvTextMessage', JSON.stringify({
          sessionId: sessionId,
          content: content
        }));
      } catch (_e) {
        await exportSessionFiles(sessionId);
      }
    } else {
      await exportSessionFiles(sessionId);
    }
    AppStorage.setOrCreate('recvTransferCompleted', sessionId);
    hilog.info(0x0001, TAG, '[diag] set recvTransferCompleted=%{public}s', sessionId);

    // ── Auto-finish logic ──
    let wasAutoAccepted = receiveSessionAutoAccepted[sessionId];
    if (shouldAutoFinishSession(sessionId, false)) {
      // Auto-finish: close the session automatically
      AppStorage.setOrCreate('recvAutoFinish_' + sessionId, true);
      addLog('info', 'Auto-finish: session ' + sessionId.substring(0, 8) + ' completed, auto-closing');
      // For single file + QuickSave + no errors: offer "open file" option
      if (wasAutoAccepted && entries !== undefined && entries.length === 1) {
        AppStorage.setOrCreate('recvOfferOpenFile_' + sessionId, true);
      }
    }

    // Clean up session state to prevent memory leak
    // Note: completedFileIds entries for this session are left as-is (true).
    // Since sessionIds are unique UUIDs, stale entries will never match new
    // progress entries. We skip the completedFileIds[key] = false loop because:
    // 1) ArkTS does not allow delete on Record keys
    // 2) Setting to false keeps the key alive (unbounded growth)
    // 3) The true value is harmless — dedup check is === undefined
    sessionTotalFiles[sessionId] = 0;
    sessionCompletedCount[sessionId] = 0;
    sessionExported[sessionId] = false;
    sessionFileMap[sessionId] = [];
    // Clean up receive session state to prevent memory leak
    receiveSessionStates[sessionId] = '';
    receiveSessionAutoAccepted[sessionId] = false;
    receiveSessionSenderAlias[sessionId] = '';
    // Periodically reset all session Records to prevent unbounded growth
    // (ArkTS does not allow delete on Record keys, so sentinel values accumulate)
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
  // Prune stale devices periodically
  let now = Date.now();
  let validDevices: Array<DiscoveredDevice> = [];
  for (let i = 0; i < discoveredDevices.length; i++) {
    if (now - discoveredDevices[i].lastSeen < DEVICE_EXPIRY_MS) {
      validDevices.push(discoveredDevices[i]);
    }
  }
  if (validDevices.length !== discoveredDevices.length) {
    discoveredDevices = validDevices;
  }
  notifyChange();
  drainNativeDebugLog();
  } finally {
    pollInProgress = false;
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
  // Auto-restart server if pending config changes (e.g. HTTPS toggle)
  // This ensures the running server protocol matches current settings
  if (serverNeedsRestart) {
    addLog('info', 'Auto-restarting server before send...');
    await restartServer();
  }

  // 协议协商逻辑（加密不可降级策略）：
  // 1. 发送端启用HTTPS + 接收端支持HTTPS → 使用HTTPS
  // 2. 发送端启用HTTPS + 接收端不支持HTTPS → 错误，拒绝降级
  // 3. 发送端禁用HTTPS + 接收端支持HTTPS → 使用HTTP（对方服务器同时接受HTTP）
  // 4. 发送端禁用HTTPS + 接收端不支持HTTPS → 使用HTTP
  let localHttps = getHttpsEnabled();
  let remoteHttps = device.protocol === 'https';
  
  // 如果发送端要求加密但接收端不支持，直接报错
  if (localHttps && !remoteHttps) {
    let errorMsg = '';
    if (appContext !== undefined) {
      errorMsg = appContext.resourceManager.getStringSync($r('app.string.protocol_mismatch_error').id).replace('%s', device.alias);
    } else {
      errorMsg = 'Protocol mismatch: receiver does not support HTTPS';
    }
    hilog.error(DOMAIN, TAG, 'Protocol mismatch: local requires HTTPS but remote only supports HTTP');
    hilog.error(DOMAIN, TAG, 'Device: %{public}s (%{public}s:%{public}d)', device.alias, device.ip, device.port);
    addLog('error', errorMsg);
    
    return { success: false, error: errorMsg };
  }
  
  // 确定实际使用的协议
  let actualProtocol = localHttps ? 'https' : 'http';
  
  hilog.info(DOMAIN, TAG, 'Protocol negotiation: local=%{public}s remote=%{public}s result=%{public}s',
    localHttps ? 'https' : 'http', 
    device.protocol, 
    actualProtocol);
  
  let target: NativeTargetDevice = {
    ip: device.ip,
    port: device.port,
    fingerprint: device.fingerprint,
    protocol: actualProtocol  // 使用发送端的协议设置
  };
  hilog.error(DOMAIN, TAG, 'sendToDevice: protocol=%{public}s ip=%{public}s port=%{public}d',
    actualProtocol, device.ip, device.port);
  let nativeFiles: Array<NativeFileToSend> = [];
  for (let i = 0; i < files.length; i++) {
    let f = files[i];
    hilog.error(DOMAIN, TAG, '  file[%{public}d]: id=%{public}s name=%{public}s path=%{public}s size=%{public}d type=%{public}s',
      i, f.fileId, f.fileName, f.filePath, f.size, f.fileType);
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
    hilog.error(DOMAIN, TAG, 'Calling nativeSendFiles...');
    let result = await nativeSendFiles(target, getDeviceAlias(), nativeFiles);
    hilog.error(DOMAIN, TAG, 'nativeSendFiles returned: success=%{public}s sessionId=%{public}s failedCount=%{public}d',
      result.success.toString(), result.sessionId, result.failedFiles.length);
    if (result.success) {
      addLog('info', 'Send success, session=' + result.sessionId.substring(0, 8));
      notifyChange();
      return { success: true };
    } else {
      let errorMsg = 'Send failed: ' + result.failedFiles.join(', ');
      // Special case: 204 No Content for text-only messages means the preview
      // was already delivered to the receiver — treat as success.
      // LocalSend protocol: /prepare-upload returns 204 when no file body upload
      // is needed (text content delivered via preview field).
      if (errorMsg.indexOf('204') >= 0 && isTextOnlySend(files)) {
        addLog('info', 'Text message delivered (204 = preview-only delivery)');
        notifyChange();
        return { success: true };
      }
      addLog('error', errorMsg);
      for (let i = 0; i < result.failedFiles.length; i++) {
        hilog.error(DOMAIN, TAG, '  failed file: %{public}s', result.failedFiles[i]);
      }
      notifyChange();
      return { success: false, error: errorMsg };
    }
  } catch (e) {
    let errorMsg = 'Send error: ' + e;
    addLog('error', errorMsg);
    hilog.error(DOMAIN, TAG, 'Send exception details: %{public}s', JSON.stringify(e));
    notifyChange();
    return { success: false, error: errorMsg };
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
  AppStorage.setOrCreate('autoSaveMode', mode);
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
  AppStorage.setOrCreate('serverNeedsRestart', true);
}

export function clearServerNeedsRestart(): void {
  serverNeedsRestart = false;
  AppStorage.setOrCreate('serverNeedsRestart', false);
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
  AppStorage.setOrCreate('serverReady', serverRunning);
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
    AppStorage.setOrCreate('checksumProgress', hashedCount);
    AppStorage.setOrCreate('checksumTotal', state.totalFiles);
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
    // Check if error is a PIN-related error (HTTP 401 or 429)
    if (result.error.indexOf('401') >= 0 || result.error.indexOf('Unauthorized') >= 0) {
      updateSendSessionStatus(sessionId, SendSessionStatus.waiting);
      AppStorage.setOrCreate('sendPinRequired_' + sessionId, {
        sessionId: sessionId,
        deviceAlias: device.alias,
        deviceIp: device.ip,
        httpStatus: 401
      });
    } else if (result.error.indexOf('429') >= 0 || result.error.indexOf('Too Many') >= 0) {
      updateSendSessionStatus(sessionId, SendSessionStatus.tooManyAttempts);
      AppStorage.setOrCreate('sendPinRequired_' + sessionId, {
        sessionId: sessionId,
        deviceAlias: device.alias,
        deviceIp: device.ip,
        httpStatus: 429
      });
    } else if (result.error.indexOf('declined') >= 0 || result.error.indexOf('rejected') >= 0) {
      // Receiver explicitly declined the transfer
      updateSendSessionStatus(sessionId, SendSessionStatus.declined);
    } else if (result.error.indexOf('204') >= 0 && isTextOnlySend(files)) {
      // 204 No Content from prepare-upload means no file body upload is needed
      // (text content delivered via preview field) — treat as success
      // Only treat as success for text-only sends; protocol mismatch errors
      // never produce 204, so this check is safe from false positives.
      updateSendSessionStatus(sessionId, SendSessionStatus.finished);
      return { success: true };
    } else {
      updateSendSessionStatus(sessionId, SendSessionStatus.finishedWithErrors);
    }
  } else {
    // No error message — generic failure
    updateSendSessionStatus(sessionId, SendSessionStatus.finishedWithErrors);
  }
  return result;
}

// ── Checksum calculation ──
// NOTE: nativeCalculateFileHash is a placeholder - Rust lib may not support it yet

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
      let hash = await nativeHashFile(files[i].filePath);
      files[i].hash = hash;
      hashedCount = hashedCount + 1;
      updateSendSessionHashProgress(sessionId, hashedCount);
    } catch (_e) {
      // Hash failure: skip this file's hash, still send the file
      files[i].hash = '';
      hashedCount = hashedCount + 1;
      updateSendSessionHashProgress(sessionId, hashedCount);
    }
  }
  // All hashing done, move to waiting status
  updateSendSessionStatus(sessionId, SendSessionStatus.waiting);
}

// ── Web Share exit restore ──


export function savePreWebShareState(): void {
}

export async function restorePreWebShareState(): Promise<void> {
  // Restore original server state when exiting Web Share
  // This ensures even if Web Share changed server config, we go back
  try {
    await restartServerFromSettings();
  } catch (_e) {
    // Graceful degradation: if restore fails, server may still be running
    // with Web Share config. User can manually restart.
    hilog.warn(DOMAIN, TAG, 'Failed to restore pre-WebShare state');
  }
}
