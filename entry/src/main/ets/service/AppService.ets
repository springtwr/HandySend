import { nativeCreateServer, nativeStopServer, nativeGetServerStatus,
  nativePollPendingRequests, nativePollProgress, nativePollSendProgress,
  nativeRespondTransfer, nativeSendFiles,
  nativeCreateShareLink, nativeStopShareServer, nativePollShareProgress } from './NativeBridge';
import { startDiscovery, stopDiscovery, sendAnnounceNow, scanSubnetHttp } from './DiscoveryService';
import { DiscoveredDevice, PendingRequest, PendingRequestFile,
  TransferProgress, SendFileItem, LogEntry, LocalDeviceInfo } from '../model/Types';
import { NativeTargetDevice, NativeFileToSend } from '../model/NativeTypes';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { connection } from '@kit.NetworkKit';

const TAG = 'LocalSend:AppService';
const DOMAIN = 0x0001;

const DEFAULT_PORT = 53317;
const POLL_INTERVAL_MS = 500;
const DEVICE_EXPIRY_MS = 120000;
const KEEPALIVE_INTERVAL_MS = 60000;

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
let changeCallbacks: Array<() => void> = [];
let requestDoNotDisturb: Array<string> = [];

export function initAppService(context: common.UIAbilityContext): void {
  appContext = context;
  alias = deviceInfo.manufacture + ' ' + deviceInfo.productModel;
}

export function getDeviceAlias(): string {
  return alias;
}

export function getServerFingerprint(): string {
  return serverFingerprint;
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
  for (let i = 0; i < changeCallbacks.length; i++) {
    changeCallbacks[i]();
  }
}

function getLocalIp(): string {
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
    deviceModel: deviceInfo.productModel,
    deviceType: 'mobile',
    port: DEFAULT_PORT,
    saveDir: saveDir,
    useHttps: httpsEnabled
  });
  serverFingerprint = handle.fingerprint;
  serverRunning = true;
  addLog('info', 'Server started, fingerprint=' + handle.fingerprint.substring(0, 10) + '...');
  try {
    await startDiscovery(alias, handle.fingerprint, onDeviceDiscovered, protocol);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'startDiscovery FAILED: %{public}s', JSON.stringify(e));
    addLog('error', 'Discovery start failed: ' + e);
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
    sendAnnounceNow(alias, serverFingerprint, protocol);
    scanSubnetHttp(onDeviceDiscovered, alias, serverFingerprint, protocol);
    addLog('info', 'Rescan sent + HTTP subnet scan');
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
        for (let fi = 0; fi < r.files.length; fi++) {
          let f = r.files[fi];
          files.push({
            fileId: f.fileId,
            fileName: f.fileName,
            size: f.size,
            fileType: f.fileType
          });
        }
        pendingRequests.push({
          sessionId: r.sessionId,
          senderAlias: r.senderAlias,
          senderFingerprint: r.senderFingerprint,
          files: files
        });
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
  for (let i = 0; i < raw.length; i++) {
    let p = raw[i];
    merged.push({
      sessionId: p.sessionId,
      fileId: p.fileId,
      bytesSent: p.bytesSent,
      totalBytes: p.totalBytes
    });
  }
  let sendRaw = nativePollSendProgress();
  for (let i = 0; i < sendRaw.length; i++) {
    let p = sendRaw[i];
    merged.push({
      sessionId: p.sessionId,
      fileId: p.fileId,
      bytesSent: p.bytesSent,
      totalBytes: p.totalBytes
    });
  }
  let shareRaw = nativePollShareProgress();
  for (let i = 0; i < shareRaw.length; i++) {
    let p = shareRaw[i];
    merged.push({
      sessionId: 'share-' + p.fileId,
      fileId: p.fileId,
      bytesSent: p.bytesSent,
      totalBytes: p.totalBytes
    });
  }
  if (merged.length > 0) {
    activeProgress = merged;
    notifyChange();
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
): Promise<void> {
  let target: NativeTargetDevice = {
    ip: device.ip,
    port: device.port,
    fingerprint: device.fingerprint,
    protocol: device.protocol
  };
  hilog.error(DOMAIN, TAG, 'sendToDevice: protocol=%{public}s ip=%{public}s port=%{public}d',
    device.protocol, device.ip, device.port);
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
  addLog('info', 'Sending ' + nativeFiles.length + ' file(s) to ' + device.alias);
  try {
    let result = await nativeSendFiles(target, alias, nativeFiles);
    if (result.success) {
      addLog('info', 'Send success, session=' + result.sessionId.substring(0, 8));
    } else {
      addLog('error', 'Send failed: ' + result.failedFiles.join(', '));
    }
  } catch (e) {
    addLog('error', 'Send exception: ' + e);
  }
  notifyChange();
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
      items.push({
        fileId: 'send_' + i + '_' + Date.now(),
        filePath: destPath,
        fileName: finalName,
        fileType: getMimeForExt(finalName),
        size: stat.size
      });
    } catch (e) {
      addLog('error', 'Failed to prepare file: ' + e);
    }
  }
  return items;
}
