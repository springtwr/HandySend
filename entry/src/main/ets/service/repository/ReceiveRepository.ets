import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { PendingRequest, PendingRequestFile, TransferProgress,
  AutoConfirmMode, FavoriteDevice, ReceiveHistoryEntry } from '../../model/Types';
import { NativePrepareUploadEvent, NativeProgressUpdateEvent,
  NativeCancelReceivedEvent, NativeSessionEndEvent, NativeTransferFileInfo,
  NativePrepareUploadAbortedEvent } from '../../model/NativeTypes';
import { nativeRespondTransfer, nativePollPendingRequests, nativeSanitizeFileName } from '../NativeBridge';
import { getFavorites } from '../FavoritesService';
import { addEntry as addHistoryEntry } from '../ReceiveHistoryService';
import { getAppContext, addLog, notifyChange } from './AppCore';
import { getAutoConfirmMode, isAutoFinish, isSaveToHistory, isSaveToGallery } from './SettingsRepository';
import { isServerRunning } from './ServerRepository';
import { getActiveProgress, upsertProgress, removeProgressForSession, handleSendProgress } from './SendRepository';
import { getLogger, LogContext } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ReceiveRepository');

export interface ReceivedFileEntry {
  sessionId: string
  fileId: string
  filePath: string
  fileName: string
  fileType: string
}

// ── 接收状态 ──

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

// ── 接收会话状态跟踪 ──
let receiveSessionStates: Record<string, string> = {}; // sessionId -> 状态：'waiting'（等待）|'sending'（发送中）|'finished'（完成）|'finishedWithErrors'（完成但有错误）|'canceledBySender'（发送方取消）
let receiveSessionAutoAccepted: Record<string, boolean> = {}; // sessionId -> 是否已自动接收
let receiveSessionSenderAlias: Record<string, string> = {}; // sessionId -> 用于历史记录的发送方别名

// ── 一次性传输事件（取代 AppStorage 事件键） ──
let pendingRecvCompleted: string = '';
let pendingRecvCancelled: string = '';
let pendingRecvText: string = '';

// ── 一次性传输事件消费者（peek = 检查，consume = 读取并清除） ──

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

// 移除已路由的请求条目。用于以下自动确认请求：
// 已在事件层完成接收（没有调用 respondToRequest
// 稍后会移除该条目）。
export function removePendingRequest(sessionId: string): void {
  let kept: Array<PendingRequest> = [];
  for (let i = 0; i < pendingRequests.length; i++) {
    if (pendingRequests[i].sessionId !== sessionId) {
      kept.push(pendingRequests[i]);
    }
  }
  pendingRequests = kept;
}

export function isAutoAcceptedSession(sessionId: string): boolean {
  return receiveSessionAutoAccepted[sessionId] === true;
}

export function getAutoAcceptedSessionAlias(sessionId: string): string {
  let alias: string | undefined = receiveSessionSenderAlias[sessionId];
  if (alias !== undefined) {
    return alias;
  }
  return '';
}

// ── 请求轮询（生命周期由 AppService 门面管理） ──

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
  // 轮询现为备份/诊断路径——主要请求处理通过回调（handleNativeEvent）
  // 保留此逻辑以应对回调投递丢失或 DebugPage 的场景
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
          // 检查是否为文本消息
          if (f.fileType === 'text/plain' || f.fileName.endsWith('.txt')) {
            hasMessage = true;
          }
        }
        // ── 自动确认接收集成 ──
        let autoAccept = shouldAutoAccept(r.senderFingerprint, hasMessage);
        if (autoAccept) {
          // 自动接收：立即接收所有文件，但仍展示
          // 请求，使传输页进行路由并展示进度/完成。
          requestDoNotDisturb.push(r.sessionId);
          sessionTotalFiles[r.sessionId] = r.files.length;
          sessionCompletedCount[r.sessionId] = 0;
          sessionFileMap[r.sessionId] = fileEntries;
          receiveSessionStates[r.sessionId] = 'sending';
          receiveSessionAutoAccepted[r.sessionId] = true;
          receiveSessionSenderAlias[r.sessionId] = r.senderAlias;
          logger.info('AutoConfirm: auto-accepting from ' + r.senderAlias + ': ' +
            files.length + ' file(s)', { direction: 'recv', targetAlias: r.senderAlias });
          // 立即响应传输——接受所有文件
          nativeRespondTransfer(r.sessionId, true, allFileIds).catch((e: Error) => {
            logger.error('AutoConfirm auto-accept failed: ' + e.message);
          });
          pendingRequests.push({
            sessionId: r.sessionId,
            senderAlias: r.senderAlias,
            senderFingerprint: r.senderFingerprint,
            senderProtocol: r.senderProtocol,
            // 轮询路径不携带发送方网络身份——调用方
            // 回退到基于发现的查找。
            senderIp: '',
            senderDeviceType: '',
            senderDeviceModel: '',
            autoConfirmed: true,
            files: files
          });
          notifyChange();
        } else {
          // 需要手动确认：加入待处理请求列表
          pendingRequests.push({
            sessionId: r.sessionId,
            senderAlias: r.senderAlias,
            senderFingerprint: r.senderFingerprint,
            senderProtocol: r.senderProtocol,
            // 轮询路径不携带发送方网络身份——调用方
            // 回退到基于发现的查找。
            senderIp: '',
            senderDeviceType: '',
            senderDeviceModel: '',
            autoConfirmed: false,
            files: files
          });
          sessionTotalFiles[r.sessionId] = r.files.length;
          sessionCompletedCount[r.sessionId] = 0;
          sessionFileMap[r.sessionId] = fileEntries;
          receiveSessionStates[r.sessionId] = 'waiting';
          receiveSessionAutoAccepted[r.sessionId] = false;
          receiveSessionSenderAlias[r.sessionId] = r.senderAlias;
          logger.info('Incoming transfer from ' + r.senderAlias + ': ' +
            files.length + ' file(s)', { direction: 'recv', targetAlias: r.senderAlias });
          notifyChange();
        }
      }
    }
  }
}

// ── 接收事件处理器（由 handleNativeEvent 路由） ──

export function handlePrepareUploadEventTyped(event: NativePrepareUploadEvent): void {
  let sessionId: string = event.sessionId;
  // 服务器无 TLS 时，certFingerprint 可能为 null（来自 JSON null）或 undefined
  let certFp: string = (event.certFingerprint !== undefined && event.certFingerprint !== null) ?
    event.certFingerprint : '';
  let infoFp: string = (event.info.fingerprint !== undefined && event.info.fingerprint !== null) ?
    event.info.fingerprint : '';
  if (sessionId.length === 0) {
    logger.warn('PrepareUpload event with empty sessionId, ignoring');
    return;
  }
  let senderAlias: string = event.info.alias;
  let senderIp: string = event.ip;
  let senderDeviceType: string = '';
  if (event.info.deviceType !== undefined && event.info.deviceType !== null) {
    senderDeviceType = event.info.deviceType;
  }
  let senderDeviceModel: string = '';
  if (event.info.deviceModel !== undefined && event.info.deviceModel !== null) {
    senderDeviceModel = event.info.deviceModel;
  }
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
    logger.info('AutoConfirm: auto-accepting from ' + senderAlias + ': ' +
      files.length + ' file(s)', { direction: 'recv', targetAlias: senderAlias });
    nativeRespondTransfer(sessionId, true, allFileIds).then(() => {
    }).catch((e: Error) => {
      logger.error('AutoConfirm auto-accept failed: ' + e.message);
    });
    // 无论如何呈现该请求，使传输页路由并展示
    // 进度/完成（自动确认而非静默后台保存）。
    pendingRequests.push({
      sessionId: sessionId,
      senderAlias: senderAlias,
      senderFingerprint: senderFingerprint,
      senderProtocol: senderProtocol,
      senderIp: senderIp,
      senderDeviceType: senderDeviceType,
      senderDeviceModel: senderDeviceModel,
      autoConfirmed: true,
      files: files
    });
  } else {
    pendingRequests.push({
      sessionId: sessionId,
      senderAlias: senderAlias,
      senderFingerprint: senderFingerprint,
      senderProtocol: senderProtocol,
      senderIp: senderIp,
      senderDeviceType: senderDeviceType,
      senderDeviceModel: senderDeviceModel,
      autoConfirmed: false,
      files: files
    });
    sessionTotalFiles[sessionId] = files.length;
    sessionCompletedCount[sessionId] = 0;
    sessionFileMap[sessionId] = fileEntries;
    receiveSessionStates[sessionId] = 'waiting';
    receiveSessionAutoAccepted[sessionId] = false;
    receiveSessionSenderAlias[sessionId] = senderAlias;
    logger.info('Incoming transfer from ' + senderAlias + ': ' +
      files.length + ' file(s)', { direction: 'recv', targetAlias: senderAlias });
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

// 发送方在我们仍在决策时丢弃了 prepare-upload 请求
// （即在我们确认之前已取消）。Rust 服务器通过以下方式报告此情况
// prepare_upload_aborted；将其视同取消，以便
// 传输页即使在 Idle 状态也会作出反应。pendingRequests 条目
// 特意保留——MainTabViewModel 将其路由到传输页，
// 随后呈现取消反馈。
export function handlePrepareUploadAbortedEventTyped(event: NativePrepareUploadAbortedEvent): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length === 0) {
    return;
  }
  pendingRecvCancelled = sessionId;
  receiveSessionStates[sessionId] = 'canceledBySender';
  removeProgressForSession(sessionId);
  addLog('info', 'Transfer aborted by sender (before confirm): ' + sessionId.substring(0, 8));
  notifyChange();
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
    logger.info('Share progress update: session=' + sessionId.substring(0, 8) + ' file=' + fileId);
  }

  notifyChange();
}

/**
 * 处理单个接收进度更新事件。
 * 处理：文件完成检测、会话完成、文件导出、历史记录、自动完成、清理。
 */
function handleRecvProgress(progress: TransferProgress): void {
  let sessionId: string = progress.sessionId;
  let fileId: string = progress.fileId;
  let bytesSent: number = progress.bytesSent;
  let totalBytes: number = progress.totalBytes;
  let filePath: string = progress.filePath;

  // 检查该文件是否刚完成
  let key = sessionId + ':' + fileId;
  if (bytesSent >= totalBytes && totalBytes > 0 &&
    completedFileIds[key] === undefined) {
    completedFileIds[key] = true;
    completedFileCount++;
    // 定期重置 completedFileIds，防止无界增长
    if (completedFileCount > 500) {
      completedFileIds = {};
      completedFileCount = 0;
    }
    let prev = sessionCompletedCount[sessionId] || 0;
    sessionCompletedCount[sessionId] = prev + 1;

    // 更新会话文件映射中的文件路径
    let entries = sessionFileMap[sessionId];
    if (entries !== undefined) {
      for (let j = 0; j < entries.length; j++) {
        if (entries[j].fileId === fileId) {
          entries[j].filePath = filePath;
          break;
        }
      }
    }

    // 检查会话是否已完成（所有文件传输完毕）
    let total = sessionTotalFiles[sessionId] || 0;
    if (sessionCompletedCount[sessionId] >= total && total > 0 &&
      sessionExported[sessionId] === undefined) {
      sessionExported[sessionId] = true;
      finishReceiveSession(sessionId);
    }
  }
}

/**
 * 完成一个接收会话：导出文件、记录历史、自动完成、清理。
 * 当会话中的所有文件均下载完成时调用。
 */
async function finishReceiveSession(sessionId: string): Promise<void> {
  // 移除本会话的进度条目
  removeProgressForSession(sessionId);

  // ── 接收会话状态机：标记为已完成 ──
  receiveSessionStates[sessionId] = 'finished';

  // ── 记录接收历史 ──
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
  logger.info('[callback] set recvTransferCompleted=' + sessionId);

  // ── 自动完成逻辑 ──
  let wasAutoAccepted = receiveSessionAutoAccepted[sessionId];
  if (shouldAutoFinishSession(sessionId, false)) {
    // 自动完成：自动关闭会话
    addLog('info', 'Auto-finish: session ' + sessionId.substring(0, 8) + ' completed, auto-closing');
  }

  // 清理会话状态以防内存泄漏
  sessionTotalFiles[sessionId] = 0;
  sessionCompletedCount[sessionId] = 0;
  // 标记为已清理——完成逻辑中通过 === undefined 检查，
  // 因此设置为 false 可防止重复触发（false !== undefined）。
  sessionExported[sessionId] = false;
  sessionFileMap[sessionId] = [];
  // 清理接收会话状态以防内存泄漏
  receiveSessionStates[sessionId] = '';
  receiveSessionAutoAccepted[sessionId] = false;
  receiveSessionSenderAlias[sessionId] = '';
  // 定期重置所有会话记录，防止无界增长
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
  // 清理本会话的免打扰条目
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
      // 净化文件名，确保其符合当前平台规范
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

// ── 请求响应 ──

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
  // 更新接收会话状态
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

// ── 自动确认逻辑：判断入站请求是否应自动接收 ──

export function shouldAutoAccept(senderFingerprint: string, hasMessage: boolean): boolean {
  // 文本消息从不自动接收
  if (hasMessage) {
    return false;
  }
  if (getAutoConfirmMode() === AutoConfirmMode.on) {
    return true;
  }
  if (getAutoConfirmMode() === AutoConfirmMode.paired) {
    let favDevices: Array<FavoriteDevice> = getFavorites();
    for (let i = 0; i < favDevices.length; i++) {
      if (favDevices[i].fingerprint === senderFingerprint) {
        return true;
      }
    }
  }
  return false;
}

// ── 接收历史记录 ──

function recordReceiveHistory(sessionId: string, files: Array<ReceivedFileEntry>, senderAlias: string): void {
  if (!isSaveToHistory()) {
    return;
  }
  for (let i = 0; i < files.length; i++) {
    let f = files[i];
    // 尝试从磁盘获取实际文件大小
    let fileSize: number = 0;
    if (f.filePath.length > 0) {
      try {
        let stat = fs.statSync(f.filePath);
        fileSize = stat.size;
      } catch (_e) {
        // 回退：尝试从待处理请求数据中获取大小
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

// ── 自动完成逻辑 ──

function shouldAutoFinishSession(sessionId: string, hasErrors: boolean): boolean {
  if (!isAutoFinish()) {
    return false;
  }
  if (hasErrors) {
    return false;
  }
  return true;
}
