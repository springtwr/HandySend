import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PendingRequest, PendingRequestFile, TransferProgress,
  QuickSaveMode, FavoriteDevice, ReceiveHistoryEntry } from '../../model/Types';
import { NativePrepareUploadEvent, NativeProgressUpdateEvent,
  NativeCancelReceivedEvent, NativeSessionEndEvent, NativeTransferFileInfo } from '../../model/NativeTypes';
import { nativeRespondTransfer, nativePollPendingRequests, nativeSanitizeFileName } from '../NativeBridge';
import { getFavorites } from '../FavoritesService';
import { addEntry as addHistoryEntry } from '../ReceiveHistoryService';
import { getAppContext, addLog, notifyChange } from './AppCore';
import { getAutoSaveMode, isAutoFinish, isSaveToHistory, isSaveToGallery } from './SettingsRepository';
import { isServerRunning } from './ServerRepository';
import { getActiveProgress, upsertProgress, removeProgressForSession, handleSendProgress } from './SendRepository';

const TAG = 'LocalSend:ReceiveRepository';
const DOMAIN = 0x0001;

export interface ReceivedFileEntry {
  sessionId: string
  fileId: string
  filePath: string
  fileName: string
  fileType: string
}

// ── Receive state ──

let pendingRequests: Array<PendingRequest> = [];
let requestDoNotDisturb: Array<string> = [];
let requestPollTimer: number | undefined = undefined;

let sessionTotalFiles: Record<string, number> = {};
let sessionCompletedCount: Record<string, number> = {};
let sessionExported: Record<string, boolean> = {};
let sessionFileMap: Record<string, Array<ReceivedFileEntry>> = {};
let completedFileIds: Record<string, boolean> = {};
let completedFileCount: number = 0;
let sessionCleanupCount: number = 0;

// ── Receive session state tracking ──
let receiveSessionStates: Record<string, string> = {}; // sessionId -> 'waiting'|'sending'|'finished'|'finishedWithErrors'|'canceledBySender'
let receiveSessionAutoAccepted: Record<string, boolean> = {}; // sessionId -> was auto-accepted
let receiveSessionSenderAlias: Record<string, string> = {}; // sessionId -> senderAlias for history recording

// ── One-shot transfer events (replacing AppStorage event keys) ──
let pendingRecvCompleted: string = '';
let pendingRecvCancelled: string = '';
let pendingRecvText: string = '';

// ── One-shot transfer event consumers (peek = inspect, consume = read-and-clear) ──

export function peekRecvCompleted(): string {
  return pendingRecvCompleted;
}

export function consumeRecvCompleted(): string {
  let sessionId: string = pendingRecvCompleted;
  pendingRecvCompleted = '';
  return sessionId;
}

export function peekRecvCancelled(): string {
  return pendingRecvCancelled;
}

export function consumeRecvCancelled(): string {
  let sessionId: string = pendingRecvCancelled;
  pendingRecvCancelled = '';
  return sessionId;
}

export function peekRecvText(): string {
  return pendingRecvText;
}

export function consumeRecvText(): string {
  let json: string = pendingRecvText;
  pendingRecvText = '';
  return json;
}

export function getPendingRequests(): Array<PendingRequest> {
  return pendingRequests;
}

// ── Request polling (lifecycle managed by the AppService facade) ──

export function startRequestPolling(): void {
  if (requestPollTimer !== undefined) {
    return;
  }
  requestPollTimer = setInterval(() => {
    doPollRequests();
  }, 30000);
}

export function stopRequestPolling(): void {
  if (requestPollTimer !== undefined) {
    clearInterval(requestPollTimer);
    requestPollTimer = undefined;
  }
}

export function hasActiveTransfers(): boolean {
  return getActiveProgress().length > 0;
}

function doPollRequests(): void {
  // Poll is now a backup/diagnostic path — primary request handling is via callback (handleNativeEvent)
  // Keep this for cases where callback delivery was missed or for DebugPage
  if (!isServerRunning()) {
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

// ── Receive event handlers (routed from handleNativeEvent) ──

export function handlePrepareUploadEventTyped(event: NativePrepareUploadEvent): void {
  let sessionId: string = event.sessionId;
  // certFingerprint can be null (from JSON null) or undefined when server has no TLS
  let certFp: string = (event.certFingerprint !== undefined && event.certFingerprint !== null) ?
    event.certFingerprint : '';
  let infoFp: string = (event.info.fingerprint !== undefined && event.info.fingerprint !== null) ?
    event.info.fingerprint : '';
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
    return;
  }

  let files: Array<PendingRequestFile> = [];
  let fileEntries: Array<ReceivedFileEntry> = [];
  let hasMessage: boolean = false;
  let allFileIds: Array<string> = [];
  for (let fi = 0; fi < event.files.length; fi++) {
    let f: NativeTransferFileInfo = event.files[fi];
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
  if (autoAccept) {
    requestDoNotDisturb.push(sessionId);
    sessionTotalFiles[sessionId] = files.length;
    sessionCompletedCount[sessionId] = 0;
    sessionFileMap[sessionId] = fileEntries;
    receiveSessionStates[sessionId] = 'sending';
    receiveSessionAutoAccepted[sessionId] = true;
    receiveSessionSenderAlias[sessionId] = senderAlias;
    addLog('info', 'QuickSave: auto-accepting from ' + senderAlias + ': ' +
      files.length + ' file(s)');
    nativeRespondTransfer(sessionId, true, allFileIds).then(() => {
    }).catch((e: Error) => {
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

export function handleSessionEndEventTyped(event: NativeSessionEndEvent): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length > 0) {
    addLog('info', 'Session ended: ' + sessionId.substring(0, 8));
  }
}

export function handleCancelReceivedEventTyped(event: NativeCancelReceivedEvent): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length > 0) {
    pendingRecvCancelled = sessionId;
    receiveSessionStates[sessionId] = 'canceledBySender';
    removeProgressForSession(sessionId);
    addLog('info', 'Transfer cancelled by sender: ' + sessionId.substring(0, 8));
    notifyChange();
  }
}

export function handleProgressUpdateTyped(event: NativeProgressUpdateEvent): void {
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

  upsertProgress(progress);

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
  removeProgressForSession(sessionId);

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
  if (entries !== undefined && entries.length === 1 &&
    entries[0].fileType === 'text/plain' && entries[0].filePath.length > 0) {
    try {
      let content = fs.readTextSync(entries[0].filePath);
      try {
        fs.unlinkSync(entries[0].filePath);
      } catch (_cleanupErr) {
      }
      pendingRecvText = JSON.stringify({
        sessionId: sessionId,
        content: content
      });
    } catch (_e) {
      await exportSessionFiles(sessionId);
    }
  } else {
    await exportSessionFiles(sessionId);
  }
  pendingRecvCompleted = sessionId;
  hilog.info(0x0001, TAG, '[callback] set recvTransferCompleted=%{public}s', sessionId);

  // ── Auto-finish logic ──
  let wasAutoAccepted = receiveSessionAutoAccepted[sessionId];
  if (shouldAutoFinishSession(sessionId, false)) {
    // Auto-finish: close the session automatically
    addLog('info', 'Auto-finish: session ' + sessionId.substring(0, 8) + ' completed, auto-closing');
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

async function exportSessionFiles(sessionId: string): Promise<void> {
  let entries: Array<ReceivedFileEntry> | undefined = sessionFileMap[sessionId];
  let appContext = getAppContext();
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
      validEntries.push({
        sessionId: entry.sessionId,
        fileId: entry.fileId,
        filePath: entry.filePath,
        fileName: diskName,
        fileType: entry.fileType
      });
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

// ── Request response ──

export async function respondToRequest(sessionId: string, accept: boolean,
  acceptedFileIds: Array<string> = []): Promise<void> {
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

// ── QuickSave logic: determine if incoming request should be auto-accepted ──

export function shouldAutoAccept(senderFingerprint: string, hasMessage: boolean): boolean {
  // Text messages are never auto-accepted
  if (hasMessage) {
    return false;
  }
  if (getAutoSaveMode() === QuickSaveMode.on) {
    return true;
  }
  if (getAutoSaveMode() === QuickSaveMode.paired) {
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
  if (!isSaveToHistory()) {
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
      }
    }
    let entry: ReceiveHistoryEntry = {
      id: sessionId + '_' + i,
      fileName: f.fileName,
      fileType: f.fileType,
      path: f.filePath,
      savedToGallery: isSaveToGallery(),
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
  if (!isAutoFinish()) {
    return false;
  }
  if (hasErrors) {
    return false;
  }
  return true;
}
