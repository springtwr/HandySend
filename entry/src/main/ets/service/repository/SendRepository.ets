import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DiscoveredDevice, TransferProgress, SendFileItem, StagedFile,
  SendMode, SendSessionStatus, SendSessionState } from '../../model/Types';
import { NativeTargetDevice, NativeFileToSend, NativeHttpError } from '../../model/NativeTypes';
import { nativeSendFiles, nativeSanitizeFileName, nativePollDebugLog } from '../NativeBridge';
import { getMimeForExt as mimeGetMimeForExt, getMimeForFileName as mimeGetMimeForFileName } from '../../utils/MimeUtils';
import { getAppContext, addLog, notifyChange, shortSid } from './AppCore';
import { doesServerNeedRestart, getHttpsEnabled } from './SettingsRepository';
import { getDeviceAlias } from './DeviceRepository';
import { restartServer } from './ServerRepository';

const TAG = 'LocalSend:SendRepository';
const DOMAIN = 0x0001;

export interface SendResult {
  success: boolean;
  error?: NativeHttpError;
}

// ── Send state ──

let sendSessions: Map<string, SendSessionState> = new Map();
let activeProgress: Array<TransferProgress> = [];
let pendingSendCompleted = false;
// Shared-URIs inbox (replaces AppStorage sharedFileUris/pendingSharedUris):
// EntryAbility writes shared URIs here; SendViewModel consumes them.
let pendingSharedUrisJson: string = '';

export function setPendingSharedUris(json: string): void {
  pendingSharedUrisJson = json;
}

export function consumePendingSharedUris(): string {
  let json: string = pendingSharedUrisJson;
  pendingSharedUrisJson = '';
  return json;
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

// Progress helpers shared with ReceiveRepository (activeProgress lives here
// because it is also owned by the send-session lifecycle).

export function upsertProgress(progress: TransferProgress): void {
  let found: boolean = false;
  for (let j = 0; j < activeProgress.length; j++) {
    if (activeProgress[j].sessionId === progress.sessionId &&
      activeProgress[j].fileId === progress.fileId) {
      activeProgress[j] = progress;
      found = true;
      break;
    }
  }
  if (!found) {
    activeProgress.push(progress);
  }
}

export function removeProgressForSession(sessionId: string): void {
  let cleaned: Array<TransferProgress> = [];
  for (let j = 0; j < activeProgress.length; j++) {
    if (activeProgress[j].sessionId !== sessionId) {
      cleaned.push(activeProgress[j]);
    }
  }
  activeProgress = cleaned;
}

// ── Send error message mapping ──

export function sendResultErrorMessage(err: NativeHttpError | undefined): string {
  if (err === undefined) {
    return '';
  }
  let appContext = getAppContext();
  if (err.kind === 'statusCode') {
    if (err.status === 401) {
      if (appContext !== undefined) {
        return appContext.resourceManager.getStringSync($r('app.string.send_error_unauthorized').id);
      }
      return 'PIN required';
    } else if (err.status === 403) {
      if (appContext !== undefined) {
        return appContext.resourceManager.getStringSync($r('app.string.send_error_declined').id);
      }
      return 'Receiver declined';
    } else if (err.status === 429) {
      if (appContext !== undefined) {
        return appContext.resourceManager.getStringSync($r('app.string.send_error_too_many').id);
      }
      return 'Too many attempts, try later';
    } else if (err.status === 409) {
      if (appContext !== undefined) {
        return appContext.resourceManager.getStringSync($r('app.string.send_error_busy').id);
      }
      return 'Recipient is busy, please try again later';
    }
    // Unknown status codes fall through to existing logic
    if (err.message !== undefined && err.message.length > 0) {
      return err.message;
    }
    if (err.status !== undefined) {
      return 'HTTP ' + err.status;
    }
    return err.kind;
  }
  // Non-statusCode errors (reqwest/io/other/partialFailure) — connection error
  if (appContext !== undefined) {
    return appContext.resourceManager.getStringSync($r('app.string.send_error_connection').id);
  }
  return 'Connection failed';
}

// ── Send ──

export async function sendToDevice(
  device: DiscoveredDevice,
  files: Array<SendFileItem>
): Promise<SendResult> {
  // Auto-restart server if pending config changes (e.g. HTTPS toggle)
  // This ensures the running server protocol matches current settings
  if (doesServerNeedRestart()) {
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
    let appContext = getAppContext();
    if (appContext !== undefined) {
      errorMsg = appContext.resourceManager.getStringSync($r('app.string.protocol_mismatch_error').id).replace('%s', device.alias);
    } else {
      errorMsg = 'Protocol mismatch: receiver does not support HTTPS';
    }
    addLog('error', errorMsg);
    return { success: false, error: { kind: 'other', message: errorMsg } };
  }

  // 确定实际使用的协议
  let actualProtocol = localHttps ? 'https' : 'http';

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
    let result = await nativeSendFiles(target, getDeviceAlias(), nativeFiles);
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
      if (result.error !== undefined && result.error.kind === 'statusCode' && result.error.status === 403 && isTextOnlySend(files)) {
        addLog('info', 'Text message viewed but declined (403 = preview-only delivery with rejection)');
        notifyChange();
        return { success: true };
      }
      if (result.error !== undefined && result.error.kind === 'partialFailure' && isTextOnlySend(files)) {
        addLog('info', 'Text message delivered (partialFailure = preview-only delivery, upload failures are expected)');
        notifyChange();
        return { success: true };
      }
      let errorMsg = 'Send failed: ' + result.failedFiles.join(', ');
      if (result.error !== undefined && result.error.message !== undefined) {
        errorMsg = result.error.message;
      }
      addLog('error', errorMsg);
      notifyChange();
      return { success: false, error: result.error };
    }
  } catch (e) {
    let errorMsg = 'Send error: ' + e;
    addLog('error', errorMsg);
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

// ── Send progress logging (called by ReceiveRepository for send-direction events) ──

export function handleSendProgress(progress: TransferProgress): void {
  let sessionId: string = progress.sessionId;
  let fileId: string = progress.fileId;
  let bytesSent: number = progress.bytesSent;
  let totalBytes: number = progress.totalBytes;

  // Check if this send file just completed
  if (bytesSent >= totalBytes && totalBytes > 0) {
    // Send session completion is handled by the sendToDevice/sendToDeviceMulti flow
    // (nativeSendFiles resolves after all uploads finish)
    hilog.info(0x0001, TAG, '[send-callback] file complete: session=%{public}s file=%{public}s',
      shortSid(sessionId), fileId);
  }
}

// ── File staging / preparation ──

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
  let appContext = getAppContext();
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
  let appContext = getAppContext();
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

function drainNativeDebugLog(): void {
  let lines: Array<string> = nativePollDebugLog();
  for (let i = 0; i < lines.length; i++) {
    hilog.info(DOMAIN, TAG, '[native] %{public}s', lines[i]);
  }
}

// ── Send session management ──

export function getSendSessions(): Array<SendSessionState> {
  let result: Array<SendSessionState> = [];
  sendSessions.forEach((state: SendSessionState) => {
    result.push(state);
  });
  return result;
}

export function createSendSession(sessionId: string, targetIp: string,
  targetAlias: string, files: Array<SendFileItem>): void {
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

export function updateSendSessionStatus(sessionId: string, status: SendSessionStatus): void {
  let state = sendSessions.get(sessionId);
  if (state !== undefined) {
    state.status = status;
    // Auto-cleanup terminal sessions after a delay
    if (status === SendSessionStatus.finished || status === SendSessionStatus.finishedWithErrors ||
        status === SendSessionStatus.declined || status === SendSessionStatus.viewed ||
        status === SendSessionStatus.recipientBusy || status === SendSessionStatus.tooManyAttempts) {
      setTimeout(() => {
        sendSessions.delete(sessionId);
        notifyChange();
      }, 5000);
    }
    notifyChange();
  }
}

export function updateSendSessionHashProgress(sessionId: string, hashedCount: number): void {
  let state = sendSessions.get(sessionId);
  if (state !== undefined) {
    state.hashedFileCount = hashedCount;
    if (hashedCount >= state.totalFiles) {
      state.status = SendSessionStatus.waiting;
    } else {
      state.status = SendSessionStatus.calculatingHash;
    }
    notifyChange();
  }
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
      } else if (status === 429) {
        updateSendSessionStatus(sessionId, SendSessionStatus.tooManyAttempts);
      } else if (status === 403) {
        if (isTextOnlySend(files)) {
          updateSendSessionStatus(sessionId, SendSessionStatus.viewed);
          return { success: true };
        }
        updateSendSessionStatus(sessionId, SendSessionStatus.declined);
      } else if (status === 409) {
        updateSendSessionStatus(sessionId, SendSessionStatus.recipientBusy);
      } else if (status === 204 && isTextOnlySend(files)) {
        updateSendSessionStatus(sessionId, SendSessionStatus.finished);
        return { success: true };
      } else {
        updateSendSessionStatus(sessionId, SendSessionStatus.finishedWithErrors);
      }
    } else {
      if (err.kind === 'partialFailure' && isTextOnlySend(files)) {
        updateSendSessionStatus(sessionId, SendSessionStatus.finished);
        return { success: true };
      }
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
