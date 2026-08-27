import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import {
  PendingRequest,
  PendingRequestFile,
  TransferProgress,
  AutoConfirmMode,
  FavoriteDevice,
  ReceiveHistoryEntry
} from '../../model/Types';
import {
  NativePrepareUploadEvent,
  NativeProgressUpdateEvent,
  NativeCancelReceivedEvent,
  NativeSessionEndEvent,
  NativeTransferFileInfo,
  NativePrepareUploadAbortedEvent
} from '../../model/NativeTypes';
import { nativeRespondTransfer, nativePollPendingRequests, nativeSanitizeFileName, nativeCancelTransferLocal } from '../NativeBridge';
import { getFavorites } from './FavoritesService';
import { addEntry as addHistoryEntry } from './ReceiveHistoryService';
import { getAppContext, addLog, notifyChange } from './AppCore';
import { getAutoConfirmMode, isAutoFinish, isSaveToHistory, isSaveToGallery } from './SettingsRepository';
import { isServerRunning, getReceiveSaveDir } from './ServerRepository';
import { getActiveProgress, upsertProgress, removeProgressForSession, handleSendProgress } from './SendRepository';
import { isImage, isVideo } from '../../utils/MimeUtils';
import { MediaFileInfo } from '../../model/Types';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ReceiveRepository');

interface ReceivedFileEntry {
  sessionId: string
  fileId: string
  filePath: string
  fileName: string
  fileType: string
  preview?: string
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
let receiveSessionStates: Record<string, string> = {
}; // sessionId -> 状态：'waiting'（等待）|'sending'（发送中）|'finished'（完成）|'finishedWithErrors'（完成但有错误）|'canceledBySender'（发送方取消）
let receiveSessionAutoAccepted: Record<string, boolean> = {}; // sessionId -> 是否已自动接收
let receiveSessionSenderAlias: Record<string, string> = {}; // sessionId -> 用于历史记录的发送方别名

// ── 一次性传输事件（取代 AppStorage 事件键） ──
let pendingRecvCompleted: string = '';
let pendingRecvCancelled: string = '';
let pendingRecvText: string = '';
// 媒体文件信息（JSON 序列化），传输完成时设置，由 TransferViewModel 消费
let pendingRecvMediaFiles: string = '';

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

// 查询接收会话是否已被发送方取消（供 TransferViewModel 防御竞态使用）
export function isRecvSessionCancelled(sessionId: string): boolean {
  return receiveSessionStates[sessionId] === 'canceledBySender';
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

export function peekRecvMediaFiles(): string {
  return pendingRecvMediaFiles;
}

export function consumeRecvMediaFiles(): string {
  let json: string = pendingRecvMediaFiles;
  pendingRecvMediaFiles = '';
  return json;
}

// 返回当前待消费（相册保存弹窗仍引用）的媒体文件沙箱路径列表，
// 供服务器启动时的孤儿文件清理跳过这些路径，避免误删仍在使用的沙箱副本。
export function getPendingRecvMediaPaths(): Array<string> {
  let result: Array<string> = [];
  if (pendingRecvMediaFiles.length === 0) {
    return result;
  }
  try {
    let parsed: Object = JSON.parse(pendingRecvMediaFiles);
    if (Array.isArray(parsed)) {
      let mediaList = parsed as Array<MediaFileInfo>;
      for (let i = 0; i < mediaList.length; i++) {
        if (mediaList[i].filePath.length > 0) {
          result.push(mediaList[i].filePath);
        }
      }
    }
  } catch (_e) {
    // 解析失败时返回空列表（不跳过任何文件，孤儿清理照常进行）
  }
  return result;
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
            fileType: f.fileType,
            preview: f.preview
          });
          allFileIds.push(f.fileId);
          // 检查是否为文本消息（仅手动输入文本带 preview，文件选择器选取的 txt 文件不带 preview）
          if (f.fileType === 'text/plain' && f.preview !== undefined && f.preview.length > 0) {
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
          logger.debug('AutoConfirm: auto-accepting from ' + r.senderAlias + ': ' +
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
          logger.debug('Incoming transfer from ' + r.senderAlias + ': ' +
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
      fileType: f.fileType,
      preview: f.preview
    });
    allFileIds.push(f.fileId);
    // 文本消息判断：仅手动输入文本带 preview，文件选择器选取的 txt 文件不带 preview
    if (f.fileType === 'text/plain' && f.preview !== undefined && f.preview.length > 0) {
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
    logger.debug('AutoConfirm: auto-accepting from ' + senderAlias + ': ' +
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
    logger.debug('Incoming transfer from ' + senderAlias + ': ' +
      files.length + ' file(s)', { direction: 'recv', targetAlias: senderAlias });
  }
  notifyChange();
}

export function handleSessionEndEventTyped(event: NativeSessionEndEvent): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length > 0) {
    if (event.reason === 'Cancelled') {
      // 发送方在传输中取消：Rust 服务器发 SessionEnd(reason=Cancelled)
      // 而非 cancel_received，必须按取消处理，否则已传完的文件
      // 进度会把会话判定为完成，用户看到"传输完成"的错误反馈。
      pendingRecvCancelled = sessionId;
      receiveSessionStates[sessionId] = 'canceledBySender';
      removeProgressForSession(sessionId);
      // 清理该会话在沙箱目录中的半成品文件
      cleanupSessionSandboxFiles(sessionId);
      addLog('info', 'Transfer cancelled by sender (session end): ' + sessionId.substring(0, 8));
      notifyChange();
    } else {
      addLog('info', 'Session ended: ' + sessionId.substring(0, 8));
    }
  }
}

export function handleCancelReceivedEventTyped(event: NativeCancelReceivedEvent): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length > 0) {
    pendingRecvCancelled = sessionId;
    receiveSessionStates[sessionId] = 'canceledBySender';
    removeProgressForSession(sessionId);
    // 清理该会话在沙箱目录中的半成品文件
    cleanupSessionSandboxFiles(sessionId);
    // 触发本地 CancellationToken 取消——中断 Rust 层进行中的 send_files
    // （当本机是发送方，收到接收方的 /cancel 通知时）
    nativeCancelTransferLocal(sessionId);
    addLog('info', 'Transfer cancelled by remote: ' + sessionId.substring(0, 8));
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
  // 清理该会话在沙箱目录中的半成品文件
  cleanupSessionSandboxFiles(sessionId);
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
    logger.debug('Share progress update: session=' + sessionId.substring(0, 8) + ' file=' + fileId);
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
    // 已取消的会话不再判定为完成——发送方取消时
    // 已传完文件的进度事件仍可能到达，须跳过。
    let total = sessionTotalFiles[sessionId] || 0;
    if (sessionCompletedCount[sessionId] >= total && total > 0 &&
      sessionExported[sessionId] === undefined &&
      receiveSessionStates[sessionId] !== 'canceledBySender') {
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
  // 防御：会话已被发送方取消时，不再走完成流程
  // （取消事件与最后文件进度事件的竞态窗口）。
  if (receiveSessionStates[sessionId] === 'canceledBySender') {
    return;
  }
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

  let entries = sessionFileMap[sessionId];
  // 文本消息判断：单文件 + text/plain + preview 有内容
  // （LocalSend 协议中手动输入文本的 preview 包含文本内容，文本文件无 preview）
  let isTextMessage = entries !== undefined && entries.length === 1 &&
    entries[0].fileType === 'text/plain' && entries[0].filePath.length > 0 &&
    entries[0].preview !== undefined && entries[0].preview.length > 0;

  if (isTextMessage) {
    // 文本消息分支：先读取内容，再记录历史（传递 textContent），最后消费文本内容
    let textContent: string = '';
    try {
      textContent = fs.readTextSync(entries[0].filePath);
      try {
        fs.unlinkSync(entries[0].filePath);
      } catch (_cleanupErr) {
      }
      pendingRecvText = JSON.stringify({
        sessionId: sessionId,
        content: textContent
      });
    } catch (_e) {
      await exportSessionFiles(sessionId);
    }
    if (sessionEntries !== undefined && sessionEntries.length > 0) {
      let textContentMap: Record<string, string> = {};
      textContentMap[sessionEntries[0].fileId] = textContent;
      recordReceiveHistory(sessionId, sessionEntries, senderAlias, undefined, textContentMap);
    }
  } else {
    // 非文本分支：先导出文件拿到真实路径映射（导出成功才写历史），
    // 使历史 path 指向 Download/<包名>/ 下真实存在的文件。
    let pathMap: Record<string, string> = {};
    if (sessionEntries !== undefined && sessionEntries.length > 0) {
      pathMap = await exportSessionFiles(sessionId);
      recordReceiveHistory(sessionId, sessionEntries, senderAlias, pathMap);
    } else {
      await exportSessionFiles(sessionId);
    }
  }
  // 二次防御：exportSessionFiles 是异步操作，期间可能到达取消事件
  // 并将 receiveSessionStates 改为 canceledBySender。
  // 必须在设置 pendingRecvCompleted 前再次检查，否则已消费取消事件
  // 后到达的 pendingRecvCompleted 会使 updateProgress 误判为完成。
  if (receiveSessionStates[sessionId] === 'canceledBySender') {
    logger.debug('[finishReceiveSession] session cancelled during async export, skip completed signal');
    return;
  }
  pendingRecvCompleted = sessionId;
  logger.debug('[callback] set recvTransferCompleted=' + sessionId);

  // ── 提取媒体文件信息供相册保存弹窗使用 ──
  if (isSaveToGallery()) {
    let allEntries = sessionFileMap[sessionId];
    if (allEntries !== undefined && allEntries.length > 0) {
      let mediaFiles: Array<MediaFileInfo> = [];
      for (let i = 0; i < allEntries.length; i++) {
        let e = allEntries[i];
        let isImg: boolean = isImage(e.fileType);
        let isVid: boolean = isVideo(e.fileType);
        if ((isImg || isVid) && e.filePath.length > 0) {
          let info: MediaFileInfo = {
            filePath: e.filePath,
            fileName: e.fileName,
            fileType: e.fileType,
            isImage: isImg
          };
          mediaFiles.push(info);
        }
      }
      if (mediaFiles.length > 0) {
        pendingRecvMediaFiles = JSON.stringify(mediaFiles);
        logger.debug('[callback] set pendingRecvMediaFiles, count=' + mediaFiles.length);
      }
    }
  }

  // ── 通知 UI 刷新 ──
  // finishReceiveSession 是异步的（exportSessionFiles 需要 await DocumentViewPicker），
  // 而调用方 handleProgressUpdateTyped 在调用 handleRecvProgress 后立即 notifyChange()，
  // 此时 pendingRecvCompleted 和 pendingRecvMediaFiles 尚未设置。
  // 必须在设置完这些信号后再次通知 UI，使 refreshCallback → updateProgress 能够消费它们。
  notifyChange();

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

/**
 * 检测目标路径是否已存在同名文件。
 * 与 ReceiveHistoryPage.isFileDefinitelyMissing 采用一致的健壮模式：
 * fs.accessSync 返回 true 表示存在；文件不存在时返回 false；
 * 校验失败（如权限不足抛 13900012）时抛出异常，统一按不存在处理（保守策略：不覆盖）。
 */
function fileExistsAtPath(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (e) {
    // 任何异常（如权限被拒 13900012）均视为不存在（保守策略：不覆盖）
    return false;
  }
}

/**
 * 检测目标目录中的同名文件冲突，返回不冲突的文件名。
 * 若 dir/fileName 已存在，则在文件名和扩展名之间插入 " (N)" 编号后缀（N 从 1 递增）。
 * - 无扩展名：README → README (1)
 * - 多点号：archive.tar.gz → archive.tar (1).gz（取最后一个点号分隔）
 * - 无冲突：直接返回原 fileName
 */
function uniquePath(dir: string, fileName: string): string {
  let candidatePath: string = dir + '/' + fileName;
  if (!fileExistsAtPath(candidatePath)) {
    return fileName;
  }
  // 分离文件名主干和扩展名（基于最后一个点号）
  let lastDot: number = fileName.lastIndexOf('.');
  let stem: string;
  let ext: string;
  if (lastDot > 0) {
    // 存在扩展名（lastDot > 0 排除 ".hidden" 这类以点号开头的隐藏文件）
    stem = fileName.substring(0, lastDot);
    ext = fileName.substring(lastDot); // 含点号，如 ".gz"
  } else {
    // 无扩展名或以点号开头的隐藏文件
    stem = fileName;
    ext = '';
  }
  let n: number = 1;
  let renamed: string = stem + ' (' + n + ')' + ext;
  candidatePath = dir + '/' + renamed;
  while (fileExistsAtPath(candidatePath)) {
    n++;
    renamed = stem + ' (' + n + ')' + ext;
    candidatePath = dir + '/' + renamed;
  }
  return renamed;
}

async function exportSessionFiles(sessionId: string): Promise<Record<string, string>> {
  let entries: Array<ReceivedFileEntry> | undefined = sessionFileMap[sessionId];
  let appContext = getAppContext();
  if (entries === undefined || appContext === undefined) {
    return {};
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
    return {};
  }
  // 返回 fileId → 导出后真实路径的映射（仅成功 copy 的条目），
  // 供历史记录 path 写回真实导出路径使用。
  let pathMap: Record<string, string> = {};
  try {
    let saveOptions = new picker.DocumentSaveOptions();
    saveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    saveOptions.newFileNames = names;
    let documentPicker = new picker.DocumentViewPicker();
    let uris: Array<string> = await documentPicker.save(saveOptions);
    if (uris.length === 0) {
      addLog('info', 'Export cancelled by user');
      return pathMap;
    }
    let dirUri: string = uris[0];
    let dirPath: string = new fileUri.FileUri(dirUri).path;
    let successCount = 0;
    let saveToGalleryEnabled: boolean = isSaveToGallery();
    for (let i = 0; i < validEntries.length; i++) {
      let sandboxPath: string = validEntries[i].filePath;
      let destFileName: string = uniquePath(dirPath, validEntries[i].fileName);
      let destPath: string = dirPath + '/' + destFileName;
      try {
        fs.copyFileSync(sandboxPath, destPath);
        // 记录导出成功条目的真实路径
        pathMap[validEntries[i].fileId] = destPath;
        // 当"保存到相册"开启且该文件为媒体文件时，保留沙箱副本
        // 供后续 GallerySaveService 读取；否则立即删除沙箱副本
        let isMediaFile: boolean = isImage(validEntries[i].fileType) || isVideo(validEntries[i].fileType);
        if (!saveToGalleryEnabled || !isMediaFile) {
          try {
            fs.unlinkSync(sandboxPath);
          } catch (_cleanupErr) {
          }
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
  return pathMap;
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

function recordReceiveHistory(sessionId: string, files: Array<ReceivedFileEntry>, senderAlias: string,
  pathMap?: Record<string, string>, textContentMap?: Record<string, string>): void {
  if (!isSaveToHistory()) {
    return;
  }
  for (let i = 0; i < files.length; i++) {
    let f = files[i];
    // 优先使用导出后的真实路径（pathMap），导出失败或未导出的条目回退沙箱路径
    let realPath: string = f.filePath;
    if (pathMap !== undefined && pathMap[f.fileId] !== undefined) {
      realPath = pathMap[f.fileId];
    }
    // 导出路径包含重命名后的实际文件名（如 "photo (1).jpg"），
    // 历史记录应显示磁盘上的真实文件名而非发送方原始文件名
    let displayFileName: string = f.fileName;
    if (pathMap !== undefined && pathMap[f.fileId] !== undefined) {
      let lastSlash: number = realPath.lastIndexOf('/');
      if (lastSlash >= 0) {
        displayFileName = realPath.substring(lastSlash + 1);
      } else {
        displayFileName = realPath;
      }
    }
    // 尝试从磁盘获取实际文件大小
    let fileSize: number = 0;
    if (realPath.length > 0) {
      try {
        let stat = fs.statSync(realPath);
        fileSize = stat.size;
      } catch (_e) {
        // 回退：尝试从待处理请求数据中获取大小
      }
    }
    // 文本消息内容：从 textContentMap 获取，非文本消息为空串
    let textContent: string = '';
    if (textContentMap !== undefined && textContentMap[f.fileId] !== undefined) {
      textContent = textContentMap[f.fileId];
    }
    // isMessage 判断：text/plain + preview 有内容（LocalSend 协议中手动输入文本的 preview 包含文本内容）
    let isMsg: boolean = f.fileType === 'text/plain' &&
      f.preview !== undefined && f.preview.length > 0;
    let entry: ReceiveHistoryEntry = {
      id: sessionId + '_' + i,
      fileName: displayFileName,
      fileType: f.fileType,
      path: realPath,
      savedToGallery: false, // 初始为 false，相册保存成功后更新
      isMessage: isMsg,
      fileSize: fileSize,
      senderAlias: senderAlias,
      timestamp: Date.now(),
      textContent: textContent
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

// ── 媒体文件沙箱副本清理 ──

// 清理已保留的媒体文件沙箱副本（相册保存弹窗关闭后调用）
export function cleanupMediaSandboxFiles(mediaFiles: Array<MediaFileInfo>): void {
  for (let i = 0; i < mediaFiles.length; i++) {
    try {
      fs.unlinkSync(mediaFiles[i].filePath);
    } catch (_e) {
      // 文件可能已被清理，忽略错误
    }
  }
}

// 清理接收会话在沙箱目录中的半成品文件（传输被取消或失败时调用）。
// 候选路径取 entry.filePath 非空值，否则按 fileName 拼接沙箱目录；
// best-effort 删除，单个文件删除失败不影响其余文件。
function cleanupSessionSandboxFiles(sessionId: string): void {
  let entries: Array<ReceivedFileEntry> | undefined = sessionFileMap[sessionId];
  if (entries === undefined) {
    return;
  }
  let saveDir: string = getReceiveSaveDir();
  for (let i = 0; i < entries.length; i++) {
    let candidate: string = entries[i].filePath.length > 0 ? entries[i].filePath : saveDir + entries[i].fileName;
    try {
      fs.unlinkSync(candidate);
    } catch (_e) {
      // 文件可能已被清理或不存在——忽略
    }
  }
}
