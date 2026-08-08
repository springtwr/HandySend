import { nativeCreateServer, nativeStopServer, nativeGetServerStatus,
  nativePollPendingRequests, nativePollProgress, nativePollSendProgress,
  nativeRespondTransfer, nativeSendFiles,
  nativeCreateShareLink, nativeStopShareServer, nativePollShareProgress, nativeGetRecvDiag,
  nativePollDebugLog } from './NativeBridge';
import { startDiscovery, stopDiscovery, sendAnnounceNow, scanSubnetHttp } from './DiscoveryService';
import { DiscoveredDevice, PendingRequest, PendingRequestFile,
  TransferProgress, SendFileItem, LogEntry, LocalDeviceInfo, StagedFile } from '../model/Types';
import { NativeTargetDevice, NativeFileToSend, CANCEL_EVENT_FILE_ID, NativeProgressInfo } from '../model/NativeTypes';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { connection } from '@kit.NetworkKit';
import { preferencesUtil } from '../utils/PreferencesUtil';

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

let appContext: common.UIAbilityContext | undefined = undefined;
let serverRunning = false;
let serverFingerprint = '';
let httpsEnabled = true;
let shareLinkInfo: string = '';
let sharePort: number = 0;
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

export function initAppService(context: common.UIAbilityContext): void {
  appContext = context;
  httpsEnabled = preferencesUtil.getBoolean('encryptedTransfer', true);
  refreshDeviceInfo();
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

export function refreshDeviceInfo(): void {
  let customAlias = preferencesUtil.getString('customAlias', '');
  let customDeviceType = preferencesUtil.getString('customDeviceType', '');
  let customDeviceModel = preferencesUtil.getString('customDeviceModel', '');

  alias = customAlias || (deviceInfo.manufacture + ' ' + deviceInfo.productModel);
  deviceType = customDeviceType || 'mobile';
  deviceModel = customDeviceModel || deviceInfo.productModel;
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

  let savedFingerprint: string = serverFingerprint;
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
      port: DEFAULT_PORT,
      saveDir: saveDir,
      useHttps: httpsEnabled
    });
    serverFingerprint = handle.fingerprint;

    await startDiscovery(alias, handle.fingerprint, onDeviceDiscovered, protocol, deviceModel, deviceType);
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
        port: DEFAULT_PORT,
        saveDir: saveDir,
        useHttps: savedHttps
      });
      serverFingerprint = handle.fingerprint;
      await startDiscovery(savedAlias, handle.fingerprint, onDeviceDiscovered, protocol, savedDeviceModel, savedDeviceType);
      addLog('warn', 'Rollback OK, server running with previous settings');
    } catch (rollbackError) {
      serverRunning = false;
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
    ip: getLocalIp()
  };
  return info;
}

export function isServerRunning(): boolean {
  return serverRunning;
}

export function setHttpsEnabled(enabled: boolean): void {
  httpsEnabled = enabled;
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
      size: f.size
    });
  }
  try {
    let result = await nativeCreateShareLink(nativeFiles, alias);
    sharePort = result.port;
    let localIp = getLocalIp();
    shareLinkInfo = 'http://' + localIp + ':' + sharePort;
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

export function getLocalIp(): string {
  try {
    let netHandle = connection.getDefaultNetSync();
    let props = connection.getConnectionPropertiesSync(netHandle);
    if (props.linkAddresses !== undefined) {
      for (let i = 0; i < props.linkAddresses.length; i++) {
        let addr = props.linkAddresses[i].address;
        if (addr !== undefined && addr.family === 1) {
          return addr.address;
        }
      }
    }
  } catch (_e) {
  }
  return '0.0.0.0';
}

function addLog(level: string, message: string): void {
  logs.push({ timestamp: Date.now(), level: level, message: message });
  if (logs.length > 200) {
    logs = logs.slice(-100);
  }
  hilog.error(DOMAIN, TAG, '[%{public}s] %{public}s', level, message);
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
  let saveDir = appContext.filesDir + '/LocalSend/';
  try {
    fs.mkdirSync(saveDir);
  } catch (_e) {
  }
  let protocol = httpsEnabled ? 'https' : 'http';
  let handle = await nativeCreateServer({
    alias: alias,
    deviceModel: deviceModel,
    deviceType: deviceType,
    port: DEFAULT_PORT,
    saveDir: saveDir,
    useHttps: httpsEnabled
  });
  serverFingerprint = handle.fingerprint;
  serverRunning = true;
  addLog('info', 'Server started, fingerprint=' + handle.fingerprint.substring(0, 10) + '...');
  try {
    await startDiscovery(alias, handle.fingerprint, onDeviceDiscovered, protocol, deviceModel, deviceType);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'startDiscovery FAILED: %{public}s', JSON.stringify(e));
    addLog('error', 'Discovery start failed: ' + e);
  }
  // 1-second fallback: if UDP multicast finds no devices, try HTTP subnet scan
  setTimeout(() => {
    if (serverRunning && discoveredDevices.length === 0) {
      hilog.error(DOMAIN, TAG, 'No devices found after 1s, triggering HTTP subnet scan');
      addLog('info', 'No devices via UDP, trying HTTP scan...');
      scanSubnetHttp(onDeviceDiscovered, alias, handle.fingerprint, protocol, deviceModel, deviceType);
    }
  }, 1000);
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
  serverFingerprint = '';
  discoveredDevices = [];
  pendingRequests = [];
  activeProgress = [];
  addLog('info', 'Server stopped');
  notifyChange();
}

function onDeviceDiscovered(
  dtoAlias: string, ip: string, port: number, fingerprint: string,
  version: string, deviceModel: string, deviceType: string, protocol: string
): void {
  let existing = -1;
  for (let i = 0; i < discoveredDevices.length; i++) {
    if (discoveredDevices[i].ip === ip &&
        discoveredDevices[i].fingerprint === fingerprint) {
      existing = i;
      break;
    }
  }
  if (existing >= 0) {
    discoveredDevices[existing].alias = dtoAlias;
    discoveredDevices[existing].lastSeen = Date.now();
    discoveredDevices[existing].version = version;
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
  notifyChange();
}

export function rescanDevices(): void {
  if (serverFingerprint.length > 0) {
    let protocol = httpsEnabled ? 'https' : 'http';
    sendAnnounceNow(alias, serverFingerprint, protocol, deviceModel, deviceType);
    scanSubnetHttp(onDeviceDiscovered, alias, serverFingerprint, protocol, deviceModel, deviceType);
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
    doPollProgress();
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
        for (let fi = 0; fi < r.files.length; fi++) {
          let f = r.files[fi];
          files.push({
            fileId: f.fileId,
            fileName: f.fileName,
            size: f.size,
            fileType: f.fileType,
            preview: f.preview
          });
          fileEntries.push({
            sessionId: r.sessionId,
            fileId: f.fileId,
            filePath: '',
            fileName: f.fileName,
            fileType: f.fileType
          });
        }
        pendingRequests.push({
          sessionId: r.sessionId,
          senderAlias: r.senderAlias,
          senderFingerprint: r.senderFingerprint,
          files: files
        });
        sessionTotalFiles[r.sessionId] = r.files.length;
        sessionCompletedCount[r.sessionId] = 0;
        sessionFileMap[r.sessionId] = fileEntries;
        addLog('info', 'Incoming transfer from ' + r.senderAlias + ': ' +
          files.length + ' file(s)');
        notifyChange();
      }
    }
  }
}

function doPollProgress(): void {
  if (!serverRunning) {
    return;
  }
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
        exportSessionFiles(sessionId);
      }
    } else {
      exportSessionFiles(sessionId);
    }
    AppStorage.setOrCreate('recvTransferCompleted', sessionId);
    hilog.info(0x0001, TAG, '[diag] set recvTransferCompleted=%{public}s', sessionId);
  }
  notifyChange();
  drainNativeDebugLog();
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
      names.push(diskName);
      validEntries.push({ sessionId: entry.sessionId, fileId: entry.fileId,
        filePath: entry.filePath, fileName: diskName, fileType: entry.fileType });
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
    let dirUri: string = uris[0];
    let dirPath: string = new fileUri.FileUri(dirUri).path;
    let successCount = 0;
    for (let i = 0; i < validEntries.length; i++) {
      let sandboxPath: string = validEntries[i].filePath;
      let destPath: string = dirPath + '/' + validEntries[i].fileName;
      try {
        let srcFile = fs.openSync(sandboxPath, fs.OpenMode.READ_ONLY);
        fs.copyFileSync(srcFile.fd, destPath);
        fs.closeSync(srcFile);
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
  // 协议协商逻辑：
  // 1. 发送端启用HTTPS + 接收端支持HTTPS → 使用HTTPS
  // 2. 发送端启用HTTPS + 接收端不支持HTTPS → 错误，不传输
  // 3. 发送端禁用HTTPS → 使用HTTP（接收端协议不重要）
  let localHttps = getHttpsEnabled();
  let remoteHttps = device.protocol === 'https';
  
  // 如果发送端要求加密但接收端不支持，直接报错
  if (localHttps && !remoteHttps) {
    let errorMsg = `接收端不支持加密传输。设备 "${device.alias}" 使用的是 HTTP 协议。请在设置中关闭加密传输，或让对方启用加密。`;
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
      preview: f.preview
    });
  }
  addLog('info', 'Sending ' + nativeFiles.length + ' file(s) to ' + device.alias);
  addLog('info', 'Target: ' + device.protocol + '://' + device.ip + ':' + device.port);
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
      let errorMsg = '发送失败: ' + result.failedFiles.join(', ');
      addLog('error', errorMsg);
      for (let i = 0; i < result.failedFiles.length; i++) {
        hilog.error(DOMAIN, TAG, '  failed file: %{public}s', result.failedFiles[i]);
      }
      notifyChange();
      return { success: false, error: errorMsg };
    }
  } catch (e) {
    let errorMsg = '发送异常: ' + e;
    addLog('error', errorMsg);
    hilog.error(DOMAIN, TAG, 'Send exception details: %{public}s', JSON.stringify(e));
    notifyChange();
    return { success: false, error: errorMsg };
  } finally {
    drainNativeDebugLog();
  }
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
  let dot = fileName.lastIndexOf('.');
  if (dot < 0) {
    return 'application/octet-stream';
  }
  let ext = fileName.substring(dot + 1).toLowerCase();
  let map: Record<string, string> = {
    'jpg': 'image/jpeg', 'jpeg': 'image/jpeg',
    'png': 'image/png', 'gif': 'image/gif', 'bmp': 'image/bmp',
    'webp': 'image/webp', 'svg': 'image/svg+xml', 'heic': 'image/heic',
    'mp4': 'video/mp4', 'avi': 'video/x-msvideo',
    'mkv': 'video/x-matroska', 'mov': 'video/quicktime', 'webm': 'video/webm',
    'mp3': 'audio/mpeg', 'wav': 'audio/wav', 'ogg': 'audio/ogg',
    'flac': 'audio/flac', 'aac': 'audio/aac', 'm4a': 'audio/mp4',
    'pdf': 'application/pdf',
    'doc': 'application/msword', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel', 'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint', 'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'zip': 'application/zip', 'rar': 'application/vnd.rar', '7z': 'application/x-7z-compressed',
    'tar': 'application/x-tar', 'gz': 'application/gzip',
    'txt': 'text/plain', 'html': 'text/html', 'css': 'text/css',
    'js': 'application/javascript', 'json': 'application/json', 'xml': 'application/xml',
    'apk': 'application/vnd.android.package-archive', 'exe': 'application/x-msdownload',
  };
  let mime = map[ext];
  if (mime !== undefined) {
    return mime;
  }
  return 'application/octet-stream';
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
    let candidate = sendDir + base + '_' + n + ext;
    if (!fs.accessSync(candidate)) {
      return candidate;
    }
  }
  return sendDir + base + '_' + Date.now() + ext;
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
      let destPath = resolveDestPath(sendDir, rawName);
      let srcFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      fs.copyFileSync(srcFile.fd, destPath);
      let stat = fs.statSync(destPath);
      fs.closeSync(srcFile);
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
    return true;
  }
  return false;
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
  let map: Record<string, string> = {
    'jpg': 'image/jpeg', 'jpeg': 'image/jpeg',
    'png': 'image/png', 'gif': 'image/gif', 'bmp': 'image/bmp',
    'webp': 'image/webp', 'svg': 'image/svg+xml', 'heic': 'image/heic',
    'mp4': 'video/mp4', 'avi': 'video/x-msvideo',
    'mkv': 'video/x-matroska', 'mov': 'video/quicktime', 'webm': 'video/webm',
    'mp3': 'audio/mpeg', 'wav': 'audio/wav', 'ogg': 'audio/ogg',
    'flac': 'audio/flac', 'aac': 'audio/aac', 'm4a': 'audio/mp4',
    'pdf': 'application/pdf',
    'doc': 'application/msword', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel', 'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint', 'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'zip': 'application/zip', 'rar': 'application/vnd.rar', '7z': 'application/x-7z-compressed',
    'txt': 'text/plain', 'html': 'text/html', 'json': 'application/json',
    'apk': 'application/vnd.android.package-archive'
  };
  let mime: string | undefined = map[ext];
  if (mime !== undefined) {
    return mime;
  }
  return 'application/octet-stream';
}
