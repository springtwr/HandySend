import { nativeCreateServer, nativeStopServer, nativeGetServerStatus,
  nativePollPendingRequests, nativePollProgress, nativeRespondTransfer,
  nativeSendFiles } from './NativeBridge';
import { startDiscovery, stopDiscovery, sendAnnounceNow } from './DiscoveryService';
import { DiscoveredDevice, PendingRequest, PendingRequestFile,
  TransferProgress, SendFileItem, LogEntry } from '../model/Types';
import { NativeTargetDevice, NativeFileToSend } from '../model/NativeTypes';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'LocalSend:AppService';
const DOMAIN = 0x0001;

const DEFAULT_PORT = 53317;
const POLL_INTERVAL_MS = 500;
const DEVICE_EXPIRY_MS = 30000;

let appContext: common.UIAbilityContext | undefined = undefined;
let serverRunning = false;
let serverFingerprint = '';
let discoveredDevices: Array<DiscoveredDevice> = [];
let pendingRequests: Array<PendingRequest> = [];
let activeProgress: Array<TransferProgress> = [];
let logs: Array<LogEntry> = [];
let pollTimer: number | undefined = undefined;
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

export function isServerRunning(): boolean {
  return serverRunning;
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
  let handle = await nativeCreateServer({
    alias: alias,
    deviceModel: deviceInfo.productModel,
    deviceType: 'mobile',
    port: DEFAULT_PORT,
    saveDir: saveDir
  });
  serverFingerprint = handle.fingerprint;
  serverRunning = true;
  addLog('info', 'Server started, fingerprint=' + handle.fingerprint.substring(0, 10) + '...');
  try {
    await startDiscovery(alias, handle.fingerprint, onDeviceDiscovered);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'startDiscovery FAILED: %{public}s', JSON.stringify(e));
    addLog('error', 'Discovery start failed: ' + e);
  }
  startPolling();
  notifyChange();
  return handle.fingerprint;
}

export async function stopLocalServer(): Promise<void> {
  stopPolling();
  try {
    await stopDiscovery();
  } catch (_e) {
  }
  try {
    await nativeStopServer();
  } catch (_e) {
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
    sendAnnounceNow(alias, serverFingerprint);
    addLog('info', 'Rescan sent');
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
  let raw = nativePollProgress();
  if (raw.length > 0) {
    activeProgress = [];
    for (let i = 0; i < raw.length; i++) {
      let p = raw[i];
      activeProgress.push({
        sessionId: p.sessionId,
        fileId: p.fileId,
        bytesSent: p.bytesSent,
        totalBytes: p.totalBytes
      });
    }
    notifyChange();
  }
}

export async function respondToRequest(sessionId: string, accept: boolean): Promise<void> {
  requestDoNotDisturb.push(sessionId);
  let newPending: Array<PendingRequest> = [];
  for (let i = 0; i < pendingRequests.length; i++) {
    if (pendingRequests[i].sessionId !== sessionId) {
      newPending.push(pendingRequests[i]);
    }
  }
  pendingRequests = newPending;
  try {
    await nativeRespondTransfer(sessionId, accept);
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
    fingerprint: device.fingerprint
  };
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
      let fileName = 'file_' + i + '_' + Date.now();
      let destPath = sendDir + fileName;
      let srcFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      fs.copyFileSync(srcFile.fd, destPath);
      let stat = fs.statSync(destPath);
      fs.closeSync(srcFile);
      items.push({
        fileId: 'send_' + i + '_' + Date.now(),
        filePath: destPath,
        fileName: fileName,
        fileType: 'application/octet-stream',
        size: stat.size
      });
    } catch (e) {
      addLog('error', 'Failed to prepare file: ' + e);
    }
  }
  return items;
}
