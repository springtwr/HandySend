import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import {
  PendingRequest,
  PendingRequestFile,
  TransferProgress,
  AutoConfirmMode,
  FavoriteDevice,
  ReceiveHistoryEntry,
  MediaFileInfo
} from '../../model/Types';
import {
  NativePrepareUploadEvent,
  NativeProgressEvent,
  NativeCancelReceivedEvent,
  NativeSessionEndEvent,
  NativeTransferFileInfo,
  NativePrepareUploadAbortedEvent
} from '../../model/NativeTypes';
import {
  nativeRespondTransfer,
  nativePollPendingRequests,
  nativeSanitizeFileName,
  nativeCancelTransferLocal,
  nativeRegisterRecvFileFd,
  nativeDiscardRecvFileFds
} from '../NativeBridge';
import { getFavorites } from './FavoritesService';
import { addEntry as addHistoryEntry } from './ReceiveHistoryService';
import { notifyChange } from './AppCore';
import { getAutoConfirmMode, isAutoFinish, isSaveToHistory, isSaveToGallery } from './SettingsRepository';
import { isServerRunning, getReceiveCacheDir } from './ServerRepository';
import {
  getActiveProgress,
  upsertProgress,
  removeProgressForSession,
  handleSendProgress,
  getSendFileInfo,
  SendFileInfo
} from './SendRepository';
import { isImage, isVideo } from '../../utils/MimeUtils';
import { getLogger } from '../../utils/Logger';
import { LogContext } from '../../common/LogFormat';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ReceiveRepository', '接收');

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
// 会话文件大小/路径映射（sessionId:fileId → 值），用于进度事件补齐 bytesSent/totalBytes/filePath
let sessionFileSizes: Record<string, number> = {};
let sessionFilePaths: Record<string, string> = {};
let completedFileIds: Record<string, boolean> = {};

// ── 接收直写目标（fd-direct，无沙箱导出） ──

// Download/<包名>/ 目录的持久化授权 URI 与路径（应用运行期惰性缓存；
// 会话目标准备时经 DocumentViewPicker.save(DOWNLOAD) 获取，一次获取多次复用）
let recvDirUriCache: string = '';
let recvDirPathCache: string = '';

// 会话已预注册的直写目标文件路径：sessionId → (fileId → 最终路径)。
// 用于会话取消/失败时清理 Download 中不完整的文件；成功会话的文件即交付物、不清除。
let recvTargetPaths: Map<string, Record<string, string>> = new Map<string, Record<string, string>>();

// ── 接收会话状态跟踪 ──
let receiveSessionStates: Record<string, string> = {
}; // sessionId -> 状态：'waiting'（等待）|'sending'（发送中）|'finished'（完成）|'finishedWithErrors'（完成但有错误）|'canceledBySender'（发送方取消）|'failed'（传输中断失败）
let receiveSessionAutoAccepted: Record<string, boolean> = {}; // sessionId -> 是否已自动接收
let receiveSessionSenderAlias: Record<string, string> = {}; // sessionId -> 用于历史记录的发送方别名

// ── 一次性传输事件 ──
let pendingRecvCompleted: string = '';
let pendingRecvCancelled: string = '';
let pendingRecvFailed: string = '';
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

export function peekRecvFailed(): string {
  return pendingRecvFailed;
}

export function consumeRecvFailed(): string {
  let sessionId: string = pendingRecvFailed;
  pendingRecvFailed = '';
  return sessionId;
}

// 查询接收会话是否因传输中断而失败（供 TransferViewModel 防御竞态使用）
export function isRecvSessionFailed(sessionId: string): boolean {
  return receiveSessionStates[sessionId] === 'failed';
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
          logger.debug('auto-accepting from ' + r.senderAlias + ': ' +
            files.length + ' file(s)', { direction: 'recv', targetAlias: r.senderAlias });
          // 立即响应传输——接受所有文件
          nativeRespondTransfer(r.sessionId, true, allFileIds).catch((e: Error) => {
            logger.warn('AutoConfirm auto-accept failed: ' + e.message);
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
  let infoFp: string = (event.senderFingerprint !== undefined && event.senderFingerprint !== null) ?
    event.senderFingerprint : '';
  if (sessionId.length === 0) {
    logger.warn('PrepareUpload event with empty sessionId, ignoring');
    return;
  }
  let senderAlias: string = event.senderAlias;
  let senderIp: string = event.senderIp;
  let senderDeviceType: string = '';
  if (event.senderDeviceType !== undefined && event.senderDeviceType !== null) {
    senderDeviceType = event.senderDeviceType;
  }
  let senderDeviceModel: string = '';
  if (event.senderDeviceModel !== undefined && event.senderDeviceModel !== null) {
    senderDeviceModel = event.senderDeviceModel;
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
    // 记录文件大小/路径，供进度事件补齐（新事件仅携带 progress）
    sessionFileSizes[sessionId + ':' + f.fileId] = f.size;
    sessionFilePaths[sessionId + ':' + f.fileId] = '';
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
    logger.debug('auto-accepting from ' + senderAlias + ': ' +
      files.length + ' file(s)', { direction: 'recv', targetAlias: senderAlias });
    // 自动接收同样走"预注册直写目标 → accept"流程（fd-direct）；失败按取消呈现
    acceptWithTargets(sessionId, allFileIds).then((ok: boolean) => {
      if (!ok) {
        receiveSessionStates[sessionId] = 'canceledBySender';
        logger.warn('Auto accept failed for session ' + sessionId.substring(0, 8));
      }
    }).catch((e: Error) => {
      logger.warn('AutoConfirm auto-accept failed: ' + e.message);
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
    if (event.reason === 'Cancelled' || event.reason === 'cancelled') {
      // 发送方在传输中取消：Rust 服务器发 SessionEnd(reason=Cancelled)
      // 而非 cancel_received，必须按取消处理，否则已传完的文件
      // 进度会把会话判定为完成，用户看到"传输完成"的错误反馈。
      pendingRecvCancelled = sessionId;
      receiveSessionStates[sessionId] = 'canceledBySender';
      removeProgressForSession(sessionId);
      // 清理该会话在沙箱目录中的半成品文件
      cleanupSessionReceiveFiles(sessionId);
      logger.info('Transfer cancelled by sender (session end): ' + sessionId.substring(0, 8));
      notifyChange();
    } else {
      // reason === 'Finished'：Rust 侧会话已结束。可能是成功完成（全部文件
      // 到位），也可能是失败（网络中断/写入失败导致文件未全部完成）。由于
      // 100% 进度事件与 SessionEnd 由不同 tokio 任务推送、到达顺序不保证，
      // 若这里立即按失败清理，会误删刚写完、尚未导出的文件。因此延迟 3 秒
      // 再判定：期间会话完成导出则视为成功；否则按失败处理并清理。
      scheduleSessionEndFinishedCheck(sessionId);
    }
  }
}

// 延迟判定 SessionEnd(Finished)：等待可能仍在下行的 100% 进度事件处理完。
let sessionEndCheckTimers: Record<string, number> = {};

// 已成功完成导出的会话标记。finishReceiveSession 结尾会同步清理各状态
// （含 receiveSessionStates 置 ''、sessionExported 置 false），延迟判定若依赖
// 这些被清理的字段将无法识别成功会话（仅靠 '' 不匹配失败分支碰巧不误判；
// 一旦 finishReceiveSession 引入 await 即会误判失败并误删文件），
// 因此用独立标记显式表达终结语义。
let sessionFinished: Record<string, boolean> = {};

function scheduleSessionEndFinishedCheck(sessionId: string): void {
  if (sessionEndCheckTimers[sessionId] !== undefined) {
    return;
  }
  sessionEndCheckTimers[sessionId] = setTimeout(() => {
    // ArkTS 禁止 delete，重建 Record 移除当前条目
    let newTimers: Record<string, number> = {};
    let timerKeys: Array<string> = Object.keys(sessionEndCheckTimers);
    for (let i = 0; i < timerKeys.length; i++) {
      if (timerKeys[i] !== sessionId) {
        newTimers[timerKeys[i]] = sessionEndCheckTimers[timerKeys[i]];
      }
    }
    sessionEndCheckTimers = newTimers;
    // 会话已成功完成（finishReceiveSession 已执行导出）——无需处理
    if (sessionFinished[sessionId] === true || receiveSessionStates[sessionId] === 'finished') {
      logger.info('Session ended (completed): ' + sessionId.substring(0, 8));
      return;
    }
    // 仍未完成：按失败处理（网络中断/写入失败导致传输中止），
    // 清理进度与半成品文件并通知 UI。
    if (receiveSessionStates[sessionId] === 'sending' || receiveSessionStates[sessionId] === 'failed') {
      pendingRecvFailed = sessionId;
      receiveSessionStates[sessionId] = 'failed';
      removeProgressForSession(sessionId);
      // 清理该会话在沙箱目录中的半成品文件
      cleanupSessionReceiveFiles(sessionId);
      logger.info('Transfer interrupted (session ended with failures): ' + sessionId.substring(0, 8));
      notifyChange();
    }
  }, 3000);
}

// 重建 Record 并剔除 drop 中列出的键（ArkTS 禁止 delete，用重建实现）
function recordWithoutKeys<T>(source: Record<string, T>, drop: Record<string, boolean>): Record<string, T> {
  let result: Record<string, T> = {};
  let keys: Array<string> = Object.keys(source);
  for (let i = 0; i < keys.length; i++) {
    if (drop[keys[i]] === undefined) {
      result[keys[i]] = source[keys[i]];
    }
  }
  return result;
}

// 重建以 sessionId:fileId 为键的 Record，剔除属于 drop 中会话的条目
function fileIdRecordWithoutSessions<T>(source: Record<string, T>,
  drop: Record<string, boolean>): Record<string, T> {
  let result: Record<string, T> = {};
  let keys: Array<string> = Object.keys(source);
  for (let i = 0; i < keys.length; i++) {
    let sep: number = keys[i].indexOf(':');
    let sid: string = sep >= 0 ? keys[i].substring(0, sep) : keys[i];
    if (drop[sid] === undefined) {
      result[keys[i]] = source[keys[i]];
    }
  }
  return result;
}

// 会话状态表键数超阈值时剔除已终结会话的全部状态条目，防止键无界增长。
// 仅剔除 ''（已清理）/ 'failed' / 'canceledBySender' 的会话；
// waiting/sending/finished（完成导出中）等会话条目保留，不受影响。
// 旧实现为按计数全量重置，会波及进行中会话：sessionTotalFiles 被清后
// total=0，该会话所有文件传完也无法判定完成。
function pruneTerminalSessionState(): void {
  let ids: Array<string> = Object.keys(receiveSessionStates);
  if (ids.length <= 100) {
    return;
  }
  let drop: Record<string, boolean> = {};
  let dropped: number = 0;
  for (let i = 0; i < ids.length; i++) {
    let st: string = receiveSessionStates[ids[i]];
    if (st === '' || st === 'failed' || st === 'canceledBySender') {
      drop[ids[i]] = true;
      dropped++;
    }
  }
  // 无可剔除项时跳过重建，避免无谓开销
  if (dropped === 0) {
    return;
  }
  sessionTotalFiles = recordWithoutKeys(sessionTotalFiles, drop);
  sessionCompletedCount = recordWithoutKeys(sessionCompletedCount, drop);
  sessionExported = recordWithoutKeys(sessionExported, drop);
  sessionFinished = recordWithoutKeys(sessionFinished, drop);
  sessionFileMap = recordWithoutKeys(sessionFileMap, drop);
  receiveSessionStates = recordWithoutKeys(receiveSessionStates, drop);
  receiveSessionAutoAccepted = recordWithoutKeys(receiveSessionAutoAccepted, drop);
  receiveSessionSenderAlias = recordWithoutKeys(receiveSessionSenderAlias, drop);
  completedFileIds = fileIdRecordWithoutSessions(completedFileIds, drop);
  sessionFileSizes = fileIdRecordWithoutSessions(sessionFileSizes, drop);
  sessionFilePaths = fileIdRecordWithoutSessions(sessionFilePaths, drop);
}

export function handleCancelReceivedEventTyped(event: NativeCancelReceivedEvent): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length > 0) {
    pendingRecvCancelled = sessionId;
    receiveSessionStates[sessionId] = 'canceledBySender';
    removeProgressForSession(sessionId);
    // 清理该会话在沙箱目录中的半成品文件
    cleanupSessionReceiveFiles(sessionId);
    // 触发本地 CancellationToken 取消——中断 Rust 层进行中的 send_files
    // （当本机是发送方，收到接收方的 /cancel 通知时）
    nativeCancelTransferLocal(sessionId);
    logger.info('Transfer cancelled by remote: ' + sessionId.substring(0, 8));
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
  cleanupSessionReceiveFiles(sessionId);
  logger.info('Transfer aborted by sender (before confirm): ' + sessionId.substring(0, 8));
  notifyChange();
}

export function handleProgressUpdateTyped(event: NativeProgressEvent): void {
  let sessionId: string = event.sessionId;
  let fileId: string = event.fileId;
  let progress: number = event.progress;

  if (sessionId.length === 0 || fileId.length === 0) {
    return;
  }

  // 发送方向进度：转发给 SendRepository 处理
  if (event.direction === 'send') {
    handleSendProgressProgress(sessionId, fileId, progress);
    notifyChange();
    return;
  }

  // 接收方向：从会话文件大小映射补齐 totalBytes/bytesSent/filePath（新事件仅携带 progress）
  let key: string = sessionId + ':' + fileId;
  let size: number = sessionFileSizes[key] !== undefined ? sessionFileSizes[key] : 0;
  let totalBytes: number = size;
  let bytesSent: number = Math.floor(progress * size);
  let filePath: string = sessionFilePaths[key] !== undefined ? sessionFilePaths[key] : '';
  if (filePath.length === 0) {
    // 兜底：接收文件保存路径 = 保存目录 + 文件名
    let entries = sessionFileMap[sessionId];
    if (entries !== undefined) {
      for (let i = 0; i < entries.length; i++) {
        if (entries[i].fileId === fileId) {
          filePath = getReceiveCacheDir() + entries[i].fileName;
          break;
        }
      }
    }
  }

  let progressEntry: TransferProgress = {
    sessionId: sessionId,
    fileId: fileId,
    bytesSent: bytesSent,
    totalBytes: totalBytes,
    filePath: filePath
  };

  upsertProgress(progressEntry);

  if (progress >= 1) {
    handleRecvProgress(progressEntry, true);
  } else {
    handleRecvProgress(progressEntry, false);
  }

  notifyChange();
}

/**
 * 发送方向进度：转发给 SendRepository（从 SendRepository 获取 totalBytes/filePath）。
 */
function handleSendProgressProgress(sessionId: string, fileId: string, progress: number): void {
  let info: SendFileInfo | undefined = getSendFileInfo(fileId);
  let totalBytes: number = info !== undefined ? info.size : 0;
  let bytesSent: number = Math.floor(progress * totalBytes);
  let filePath: string = info !== undefined ? info.filePath : '';
  let progressEntry: TransferProgress = {
    sessionId: sessionId,
    fileId: fileId,
    bytesSent: bytesSent,
    totalBytes: totalBytes,
    filePath: filePath
  };
  upsertProgress(progressEntry);
  handleSendProgress(progressEntry);
}

/**
 * 处理单个接收进度更新事件。
 * 处理：文件完成检测、会话完成、文件导出、历史记录、自动完成、清理。
 */
function handleRecvProgress(progress: TransferProgress, completed: boolean): void {
  let sessionId: string = progress.sessionId;
  let fileId: string = progress.fileId;
  let bytesSent: number = progress.bytesSent;
  let totalBytes: number = progress.totalBytes;
  let filePath: string = progress.filePath;

  // 检查该文件是否刚完成（progress >= 1 或字节数达标）
  let key = sessionId + ':' + fileId;
  if ((completed || (bytesSent >= totalBytes && totalBytes > 0)) &&
    completedFileIds[key] === undefined) {
    // 已完成文件的去重表（防止迟到进度事件重复计数导致提前误判完成）；
    // 条目随已终结会话在 pruneTerminalSessionState 中剔除，不做整表重置
    completedFileIds[key] = true;
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
  // 显式标记成功终结，供 3 秒延迟判定识别（见 sessionFinished 声明处注释）
  sessionFinished[sessionId] = true;

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
    // 文本消息分支：直写目标为沙箱接收目录（阅后即删），读取内容后删除文件
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
      logger.warn('Read text message failed for session ' + sessionId.substring(0, 8));
    }
    if (sessionEntries !== undefined && sessionEntries.length > 0) {
      let textContentMap: Record<string, string> = {};
      textContentMap[sessionEntries[0].fileId] = textContent;
      recordReceiveHistory(sessionId, sessionEntries, senderAlias, undefined, textContentMap);
    }
  } else {
    // 非文本分支：文件已在 Download/<包名>/ 就位（fd-direct），
    // 无需导出；历史 path 直接用登记的真实路径（含去重后文件名）
    let pathMap: Record<string, string> = {};
    if (sessionEntries !== undefined && sessionEntries.length > 0) {
      for (let i = 0; i < sessionEntries.length; i++) {
        let e = sessionEntries[i];
        if (e.filePath.length > 0) {
          pathMap[e.fileId] = e.filePath;
        }
      }
      recordReceiveHistory(sessionId, sessionEntries, senderAlias, pathMap);
    }
  }
  // 二次防御：期间可能到达取消事件并将 receiveSessionStates 改为 canceledBySender。
  // 必须在设置 pendingRecvCompleted 前再次检查，否则已消费取消事件
  // 后到达的 pendingRecvCompleted 会使 updateProgress 误判为完成。
  if (receiveSessionStates[sessionId] === 'canceledBySender') {
    logger.debug('session cancelled during async export, skip completed signal',
      { sessionId: sessionId, direction: 'recv' });
    return;
  }
  pendingRecvCompleted = sessionId;
  logger.debug('set recvTransferCompleted=' + sessionId, { sessionId: sessionId, direction: 'recv' });

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
        logger.debug('set pendingRecvMediaFiles, count=' + mediaFiles.length,
          { sessionId: sessionId, direction: 'recv' });
      }
    }
  }

  // ── 通知 UI 刷新 ──
  // 调用方 handleProgressUpdateTyped 在调用 handleRecvProgress 后立即 notifyChange()，
  // 此时 pendingRecvCompleted 和 pendingRecvMediaFiles 尚未设置。
  // 必须在设置完这些信号后再次通知 UI，使 refreshCallback → updateProgress 能够消费它们。
  notifyChange();

  // ── 自动完成逻辑 ──
  let wasAutoAccepted = receiveSessionAutoAccepted[sessionId];
  if (shouldAutoFinishSession(sessionId, false)) {
    // 自动完成：自动关闭会话
    logger.info('session ' + sessionId.substring(0, 8) + ' completed, auto-closing');
  }

  // 清理会话状态以防内存泄漏
  sessionTotalFiles[sessionId] = 0;
  sessionCompletedCount[sessionId] = 0;
  // 标记为已清理——完成逻辑中通过 === undefined 检查，
  // 因此设置为 false 可防止重复触发（false !== undefined）。
  sessionExported[sessionId] = false;
  sessionFileMap[sessionId] = [];
  // 成功会话的目标文件即交付物（不删除），仅清空登记表避免内存增长
  recvTargetPaths.delete(sessionId);
  // 清理接收会话状态以防内存泄漏
  receiveSessionStates[sessionId] = '';
  receiveSessionAutoAccepted[sessionId] = false;
  receiveSessionSenderAlias[sessionId] = '';
  // 会话状态表键数超阈值时剔除已终结会话条目（原全量重置会波及进行中会话）
  pruneTerminalSessionState();
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

// ── 接收直写目标（fd-direct） ──
// 接收文件在确认接收时预创建并注册 fd，Rust 网络流直接写入最终位置；
// 不再有"落沙箱 + 完成后拷贝导出"的两段式流程（exportSessionFiles 已移除）。

// 惰性获取 Download/<包名>/ 目录（DocumentViewPicker.save 的 DOWNLOAD 模式：
// 不弹选择界面、返回的 URI 具备持久化授权），进程内缓存复用。
async function ensureReceiveDir(): Promise<boolean> {
  if (recvDirUriCache.length > 0 && recvDirPathCache.length > 0) {
    return true;
  }
  try {
    let saveOptions = new picker.DocumentSaveOptions();
    saveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    let documentPicker = new picker.DocumentViewPicker();
    let uris: Array<string> = await documentPicker.save(saveOptions);
    if (uris === undefined || uris.length === 0) {
      logger.warn('Get receive dir failed: empty result');
      return false;
    }
    recvDirUriCache = uris[0];
    recvDirPathCache = new fileUri.FileUri(uris[0]).path;
    return true;
  } catch (e) {
    logger.error('Get receive dir failed: ' + e);
    return false;
  }
}

// 预注册某会话待接收文件的直写目标：净化/去重文件名 → 创建文件 → open 写 fd →
// registerRecvFileFd；同时把最终路径写回 sessionFileMap 供历史/相册/文本使用。
// 文本消息会话（单文件 text/plain + preview）落 cache receive 临时目录（阅后即删，不进 Download）；
// 其余文件落 Download/<包名>/。
// 任一文件准备失败 → 回滚已建文件并关闭已注册 fd，返回 false（调用方拒绝会话，不回退沙箱）。
async function prepareRecvTargets(sessionId: string, fileIds: Array<string>): Promise<boolean> {
  let entries: Array<ReceivedFileEntry> | undefined = sessionFileMap[sessionId];
  if (entries === undefined || entries.length === 0 || fileIds.length === 0) {
    return false;
  }
  let isTextMsg: boolean = entries.length === 1 &&
    entries[0].fileType === 'text/plain' &&
    entries[0].preview !== undefined && entries[0].preview.length > 0;
  let dirPath: string = '';
  if (isTextMsg) {
    dirPath = getReceiveCacheDir();
    // 防御性建目录：openSync 只建文件不建父目录
    try {
      fs.mkdirSync(dirPath);
    } catch (_e) {
    }
  } else {
    if (!(await ensureReceiveDir())) {
      return false;
    }
    dirPath = recvDirPathCache;
  }
  // 归一化：去掉尾部斜杠，便于与 '/' + 文件名拼接（getReceiveCacheDir 返回值带尾斜杠）
  if (dirPath.endsWith('/')) {
    dirPath = dirPath.substring(0, dirPath.length - 1);
  }
  if (dirPath.length === 0) {
    return false;
  }
  let perFile: Record<string, string> = {};
  let allOk: boolean = true;
  for (let i = 0; i < fileIds.length; i++) {
    let fileId: string = fileIds[i];
    let entryIdx: number = -1;
    for (let j = 0; j < entries.length; j++) {
      if (entries[j].fileId === fileId) {
        entryIdx = j;
        break;
      }
    }
    if (entryIdx < 0) {
      allOk = false;
      continue;
    }
    let entry: ReceivedFileEntry = entries[entryIdx];
    try {
      let name: string = nativeSanitizeFileName(entry.fileName);
      if (name.length === 0) {
        name = 'file_' + Date.now();
      }
      let uniqueName: string = uniquePath(dirPath, name);
      let destPath: string = dirPath + '/' + uniqueName;
      let file = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      nativeRegisterRecvFileFd(sessionId, fileId, file.fd, destPath);
      perFile[fileId] = destPath;
      // 回写最终路径：历史记录/相册保存/文本读取均以登记路径为准
      entry.filePath = destPath;
      entry.fileName = uniqueName;
      sessionFilePaths[sessionId + ':' + fileId] = destPath;
    } catch (e) {
      allOk = false;
      logger.error('Prepare recv target failed for ' + fileId + ': ' + e);
    }
  }
  if (!allOk || Object.keys(perFile).length !== fileIds.length) {
    // 回滚：关闭已注册 fd + 删除已创建的（半）文件
    nativeDiscardRecvFileFds(sessionId);
    let keys: Array<string> = Object.keys(perFile);
    for (let k = 0; k < keys.length; k++) {
      try {
        fs.unlinkSync(perFile[keys[k]]);
      } catch (_e) {
      }
    }
    return false;
  }
  recvTargetPaths.set(sessionId, perFile);
  return true;
}

// 删除某会话预创建的目标文件（会话取消/失败时调用；成功会话的文件即交付物不删除）。
function removeRecvTargetFiles(sessionId: string): void {
  let perFile: Record<string, string> | undefined = recvTargetPaths.get(sessionId);
  if (perFile === undefined) {
    return;
  }
  let keys: Array<string> = Object.keys(perFile);
  for (let k = 0; k < keys.length; k++) {
    try {
      fs.unlinkSync(perFile[keys[k]]);
    } catch (_e) {
      // 文件可能已被清理或不存在——忽略
    }
  }
  recvTargetPaths.delete(sessionId);
}

// 收集某会话全部待接收文件的 fileId。
function collectSessionFileIds(sessionId: string): Array<string> {
  let result: Array<string> = [];
  let entries: Array<ReceivedFileEntry> | undefined = sessionFileMap[sessionId];
  if (entries === undefined) {
    return result;
  }
  for (let i = 0; i < entries.length; i++) {
    result.push(entries[i].fileId);
  }
  return result;
}

// ── 请求响应 ──

// 执行"接收确认"：先预创建直写目标并注册 fd，再向 Rust 发送 accept 响应。
// 目标准备失败时拒绝会话并回滚已创建文件；respond 抛异常（如会话已过期）时同样回滚。
// 返回是否成功接受。
async function acceptWithTargets(sessionId: string, fileIds: Array<string>): Promise<boolean> {
  if (fileIds.length === 0) {
    logger.warn('Accept with empty file list, declining session');
    try {
      await nativeRespondTransfer(sessionId, false, []);
    } catch (_e) {
    }
    return false;
  }
  if (!(await prepareRecvTargets(sessionId, fileIds))) {
    logger.error('Prepare receive targets failed, declining session ' + sessionId.substring(0, 8));
    try {
      await nativeRespondTransfer(sessionId, false, []);
    } catch (_e) {
    }
    return false;
  }
  try {
    await nativeRespondTransfer(sessionId, true, fileIds);
    logger.info('Accepted request ' + sessionId.substring(0, 8) + ' with ' +
      fileIds.length + ' file(s)');
    return true;
  } catch (e) {
    // respond 失败（如会话已被发送方清理/过期）：回滚已注册 fd 与已建文件
    logger.error('Accept respond failed: ' + e);
    nativeDiscardRecvFileFds(sessionId);
    removeRecvTargetFiles(sessionId);
    return false;
  }
}

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
  if (accept) {
    receiveSessionStates[sessionId] = 'sending';
    let ids: Array<string> = acceptedFileIds.length > 0 ? acceptedFileIds : collectSessionFileIds(sessionId);
    let ok: boolean = await acceptWithTargets(sessionId, ids);
    if (!ok) {
      // 准备失败/响应异常：按取消呈现（发送方收到拒绝；本端清理已建文件）
      receiveSessionStates[sessionId] = 'canceledBySender';
      logger.error('Session ' + sessionId.substring(0, 8) + ' declined by local prepare failure');
    }
  } else {
    receiveSessionStates[sessionId] = 'canceledBySender';
    try {
      await nativeRespondTransfer(sessionId, false, acceptedFileIds);
      logger.info('Request ' + sessionId.substring(0, 8) + ' declined');
    } catch (e) {
      logger.error('Respond failed: ' + e);
    }
  }
  notifyChange();
}

// ── 自动确认逻辑：判断入站请求是否应自动接收 ──

/**
 * 自动接收决策的纯逻辑（可独立测试）。
 * - 文本消息从不自动接收
 * - on 模式：始终自动接收
 * - paired 模式：仅收藏设备自动接收
 * - off 模式：不自动接收
 */
export function computeShouldAutoAccept(
  mode: AutoConfirmMode,
  favorites: Array<FavoriteDevice>,
  senderFingerprint: string,
  hasMessage: boolean
): boolean {
  if (hasMessage) {
    return false;
  }
  if (mode === AutoConfirmMode.on) {
    return true;
  }
  if (mode === AutoConfirmMode.paired) {
    for (let i = 0; i < favorites.length; i++) {
      if (favorites[i].fingerprint === senderFingerprint) {
        return true;
      }
    }
  }
  return false;
}

export function shouldAutoAccept(senderFingerprint: string, hasMessage: boolean): boolean {
  return computeShouldAutoAccept(getAutoConfirmMode(), getFavorites(), senderFingerprint, hasMessage);
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

// ── 媒体文件沙箱副本清理（fd-direct 后已无沙箱副本） ──

// fd-direct 模式下媒体文件直接落在 Download/<包名>/（交付物），无沙箱副本；
// 相册保存从该路径读取、成功后保留文件（与旧行为"Download 副本保留"一致）。
// 保留空实现以兼容既有调用点（避免误删交付物）。
export function cleanupMediaSandboxFiles(mediaFiles: Array<MediaFileInfo>): void {
  let _ = mediaFiles;
}

// 清理接收会话残留文件（传输被取消或失败时调用）。
// fd-direct 模式下首要是删除 Download/<包名>/ 中本次预创建的不完整目标文件
// （recvTargetPaths 登记）；同时兜底清理 cache 临时目录中的文本消息残留，
// best-effort 删除。
function cleanupSessionReceiveFiles(sessionId: string): void {
  removeRecvTargetFiles(sessionId);
  let entries: Array<ReceivedFileEntry> | undefined = sessionFileMap[sessionId];
  if (entries === undefined) {
    return;
  }
  let saveDir: string = getReceiveCacheDir();
  for (let i = 0; i < entries.length; i++) {
    let candidate: string = entries[i].filePath.length > 0 ? entries[i].filePath : saveDir + entries[i].fileName;
    try {
      fs.unlinkSync(candidate);
    } catch (_e) {
      // 文件可能已被清理或不存在——忽略
    }
  }
}
