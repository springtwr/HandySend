import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  DiscoveredDevice,
  TransferProgress,
  SendFileItem,
  StagedFile,
  SendSessionStatus,
  SendSessionState
} from '../../model/Types';
import {
  NativeTargetDevice,
  NativeFileToSend,
  NativeHttpError,
  NativeSendResult,
  NativeCancelTarget
} from '../../model/NativeTypes';
import {
  nativeSendFiles,
  nativeSanitizeFileName,
  nativePollDebugLog,
  nativeCancelTransfer,
  nativeGetCurrentSendSessionId
} from '../NativeBridge';
import {
  getMimeForExt as mimeGetMimeForExt,
  getMimeForFileName as mimeGetMimeForFileName
} from '../../utils/MimeUtils';
import { getAppContext, notifyChange } from './AppCore';
import { DialogService } from '../DialogService';
import { doesServerNeedRestart, getHttpsEnabled } from './SettingsRepository';
import { getDeviceAlias } from './DeviceRepository';
import { restartServer } from './ServerRepository';
import { getLogger } from '../../utils/Logger';
import { LogContext } from '../../common/LogFormat';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendRepository', '发送');

export interface SendResult {
  success: boolean;
  error?: NativeHttpError;

  // 接收方返回的会话 id（UUID），供多目标会话记录 receiverSessionId 以清除残留进度。
  sessionId?: string;
}

// ── 发送状态 ──

let sendSessions: Map<string, SendSessionState> = new Map();
// 终态会话的延迟清理定时器（会话 id → timer id）：可取消，
// 防止终态反复更新叠加定时器、会话重建后被旧定时器误删
let pendingSessionCleanups: Map<string, number> = new Map();
let activeProgress: Array<TransferProgress> = [];
let pendingSendCompleted = false;
// 共享 URI 收件箱：
// EntryAbility 在此写入共享 URI；SendViewModel 消费它们。
let pendingSharedUrisJson: string = '';
// 共享文本收件箱：EntryAbility 在此写入分享的文本/链接内容；SendViewModel 消费它们。
let pendingSharedTextsJson: string = '';

// ── 发送文件信息映射（fileId → 大小/路径）──
// 供发送方向进度事件补齐 totalBytes/filePath（新事件仅携带 progress）。

export interface SendFileInfo {
  fileId: string
  size: number
  filePath: string
}

let sendFileInfos: Record<string, SendFileInfo> = {};

export function registerSendFileInfo(info: SendFileInfo): void {
  sendFileInfos[info.fileId] = info;
}

export function getSendFileInfo(fileId: string): SendFileInfo | undefined {
  return sendFileInfos[fileId];
}

export function clearSendFileInfos(): void {
  sendFileInfos = {};
}

// 预准备的发送文件缓存：当主页面提前调用 prepareSendFiles + calculateChecksums 时，
// 将结果暂存于此，TransferViewModel 可直接消费而无需重复准备。
let prePreparedItems: Array<SendFileItem> | undefined = undefined;

export function setPrePreparedItems(items: Array<SendFileItem> | undefined): void {
  prePreparedItems = items;
}

// 查看缓存但不消费（多目标模式每台设备复用）
export function peekPrePreparedItems(): Array<SendFileItem> | undefined {
  return prePreparedItems;
}

// 一次性消费并清空缓存（单目标模式导航到 TransferPage 时使用）
export function consumePrePreparedItems(): Array<SendFileItem> | undefined {
  let items: Array<SendFileItem> | undefined = prePreparedItems;
  prePreparedItems = undefined;
  return items;
}

// 清空缓存（文件列表变化时调用）
export function invalidatePrePreparedItems(): void {
  prePreparedItems = undefined;
}

export function setPendingSharedUris(json: string): void {
  pendingSharedUrisJson = json;
}

export function consumePendingSharedUris(): string {
  let json: string = pendingSharedUrisJson;
  pendingSharedUrisJson = '';
  return json;
}

export function setPendingSharedTexts(json: string): void {
  pendingSharedTextsJson = json;
}

export function consumePendingSharedTexts(): string {
  let json: string = pendingSharedTextsJson;
  pendingSharedTextsJson = '';
  return json;
}

export function getActiveProgress(): Array<TransferProgress> {
  return activeProgress;
}

export function clearActiveProgress(): void {
  activeProgress = [];
}

export function clearSendProgress(): void {
  // 仅清除发送会话（以 sendSessions 中出现的会话 ID 识别）的进度
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

// 与 ReceiveRepository 共享的进度辅助（activeProgress 定义于此
// 因为其生命周期同样归属于发送会话生命周期）。

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

// ── 发送错误消息映射 ──

/** 本地化资源读取：应用上下文缺失或资源读取失败时回退英文文案 */
function localizedText(res: Resource, fallback: string): string {
  let appContext = getAppContext();
  if (appContext === undefined) {
    return fallback;
  }
  try {
    return appContext.resourceManager.getStringSync(res.id);
  } catch (_e) {
    return fallback;
  }
}

export function sendResultErrorMessage(err: NativeHttpError | undefined): string {
  if (err === undefined) {
    return '';
  }
  if (err.kind === 'statusCode') {
    if (err.status === 401) {
      return localizedText($r('app.string.send_error_unauthorized'), 'PIN required');
    } else if (err.status === 403) {
      return localizedText($r('app.string.send_error_declined'), 'Receiver declined');
    } else if (err.status === 429) {
      return localizedText($r('app.string.send_error_too_many'), 'Too many attempts, try later');
    } else if (err.status === 409) {
      return localizedText($r('app.string.send_error_busy'), 'Recipient is busy, please try again later');
    }
    // 未知状态码落到现有逻辑
    if (err.message !== undefined && err.message.length > 0) {
      return err.message;
    }
    if (err.status !== undefined) {
      return 'HTTP ' + err.status;
    }
    return err.kind;
  }
  // 非状态码错误（reqwest/io/其他/部分失败）
  // 如果错误带有用户可读的消息（如协议不匹配），直接使用。
  if (err.message !== undefined && err.message.length > 0) {
    // Reqwest 层超时 / 连接失败（例如接收方从未
    // 响应了 prepare-upload）会以原始英文消息呈现，例如
    // "error sending request for url (...)": "operation timed out"。
    // 将其映射为本地化、可操作的消息，而不是泄露
    // 向用户隐藏实现细节。
    if (err.kind === 'cancelled') {
      return localizedText($r('app.string.send_error_cancelled'), 'Transfer cancelled by receiver');
    }
    if (err.kind === 'reqwest') {
      let lower: string = err.message.toLowerCase();
      if (lower.indexOf('timed out') >= 0 || lower.indexOf('timeout') >= 0 ||
        lower.indexOf('error sending request') >= 0 || lower.indexOf('connect') >= 0 ||
        lower.indexOf('connection') >= 0 || lower.indexOf('reset') >= 0) {
        return localizedText($r('app.string.send_error_timeout'), 'Receiver did not respond');
      }
      // 其他 reqwest 错误（协议不匹配等）保留其原始消息。
      return err.message;
    }
    return err.message;
  }
  return localizedText($r('app.string.send_error_connection'), 'Connection failed');
}

// ── 发送 ──

/**
 * 发送协议协商的纯逻辑（可独立测试）。
 * 加密不可降级策略：
 * - 本地 HTTPS + 远程 HTTP → 拒绝（加密不可降级）
 * - 本地 HTTPS + 远程 HTTPS → https
 * - 本地 HTTP + 远程 HTTPS → https（升级）
 * - 本地 HTTP + 远程 HTTP → http
 * @returns 协议字符串，null 表示协议不匹配应拒绝
 */
export function resolveSendProtocol(localHttps: boolean, remoteHttps: boolean): string | null {
  // 加密不可降级：本地要求加密但远程不支持
  if (localHttps && !remoteHttps) {
    return null;
  }
  if (localHttps) {
    return 'https';
  }
  if (remoteHttps) {
    return 'https';
  }
  return 'http';
}

export async function sendToDevice(
  device: DiscoveredDevice,
  files: Array<SendFileItem>
): Promise<SendResult> {
  // 若存在待应用的配置变更（如 HTTPS 开关），自动重启服务器
  // 这确保运行中的服务器协议与当前设置一致
  if (doesServerNeedRestart()) {
    logger.debug('Auto-restarting server before send...');
    await restartServer();
  }

  // 协议协商逻辑（加密不可降级策略）：
  let localHttps = getHttpsEnabled();
  let remoteHttps = device.protocol === 'https';
  let actualProtocol: string | null = resolveSendProtocol(localHttps, remoteHttps);

  // 如果协议不匹配（本地要求加密但远程不支持），直接报错
  if (actualProtocol === null) {
    let errorMsg = localizedText($r('app.string.protocol_mismatch_error'),
      'Protocol mismatch: receiver does not support HTTPS').replace('%s', device.alias);
    logger.warn('Protocol mismatch: local=https remote=http, declining',
      { direction: 'send', targetAlias: device.alias, protocol: 'https' });
    return { success: false, error: { kind: 'other', message: errorMsg } };
  }
  let sendCtx: LogContext = {
    direction: 'send',
    targetIp: device.ip,
    targetAlias: device.alias,
    protocol: actualProtocol
  };

  logger.debug('Protocol negotiated: ' + actualProtocol, sendCtx);

  let target: NativeTargetDevice = {
    ip: device.ip,
    port: device.port,
    fingerprint: device.fingerprint,
    protocol: actualProtocol,
    publicKey: device.publicKey
  };
  // 记录发送文件信息（元数据），供发送方向进度事件补齐 totalBytes/filePath。
  // 内容 fd 不在准备期持有：每次 nativeSendFiles 调用前临时打开（见下方重试循环）。
  for (let i = 0; i < files.length; i++) {
    let f = files[i];
    let hashVal: string | undefined = f.hash;
    logger.debug('sendToDevice file[' + i + ']: id=' + f.fileId + ' path=' + f.filePath +
      ' size=' + f.size + ' sha256=' + (hashVal !== undefined ? hashVal.substring(0, 16) + '...' : '(none)'));
    registerSendFileInfo({
      fileId: f.fileId,
      size: f.size,
      filePath: f.filePath
    });
  }
  logger.debug(actualProtocol + '://' + device.ip + ':' + device.port, sendCtx);
  // 接收方开启 PIN 保护时，prepare-upload 会返回 401（PIN required）。
  // 这里弹出输入框让用户输入 PIN 后带 pin 重试；用户取消则按 401 错误结束。
  const MAX_PIN_ATTEMPTS = 5;
  const MAX_BUSY_RETRIES = 2;
  let pinAttempts = 0;
  let busyRetries = 0;
  let result: NativeSendResult | undefined = undefined;
  // 当前迭代已打开、尚未交由 Rust 接管的文件句柄（nativeSendFiles 正常返回后
  // Rust 对所有传入 fd 全权负责并关闭；仅当调用抛异常时才由本层关闭避免泄漏）
  let pendingFileHandles: Array<fs.File> = [];
  try {
    while (true) {
      // 每次发送前重新打开源文件 fd：上一次 nativeSendFiles（无论成功/失败/可重试错误）
      // 返回后，Rust 已关闭全部传入 fd，重试必须重新打开
      let nativeFiles: Array<NativeFileToSend> = [];
      let opened: Array<fs.File> = [];
      try {
        for (let i = 0; i < files.length; i++) {
          let f = files[i];
          let file = fs.openSync(f.filePath, fs.OpenMode.READ_ONLY);
          opened.push(file);
          nativeFiles.push({
            fileId: f.fileId,
            filePath: f.filePath,
            fileName: f.fileName,
            fileType: f.fileType,
            size: f.size,
            fd: file.fd,
            preview: f.preview,
            sha256: f.hash
          });
        }
      } catch (openErr) {
        // 任一源文件打开失败（如授权失效）：关闭已打开句柄，按整体失败返回
        for (let k = 0; k < opened.length; k++) {
          try {
            fs.closeSync(opened[k]);
          } catch (_ce) {
          }
        }
        logger.error('Open source file failed: ' + openErr, sendCtx);
        notifyChange();
        return { success: false, error: { kind: 'other', message: String(openErr) } };
      }
      pendingFileHandles = opened;
      result = await nativeSendFiles(target, getDeviceAlias(), nativeFiles);
      // Rust 已接管全部 fd 并负责关闭；本层不再关闭，避免 double-close
      pendingFileHandles = [];
      if (result.success) {
        logger.debug('Send success', { sessionId: result.sessionId, direction: 'send' });
        notifyChange();
        return { success: true, sessionId: result.sessionId };
      }
      let err = result.error;
      if (err !== undefined && err.kind === 'statusCode' && err.status === 401 && pinAttempts < MAX_PIN_ATTEMPTS) {
        // 用户取消（askForPin 返回 undefined）时跳出循环，按 401 错误结束
        let pin: string | undefined = await askForPin(device.alias, pinAttempts > 0);
        pinAttempts++;
        if (pin === undefined || pin.length === 0) {
          break;
        }
        target.pin = pin;
        logger.debug('Retrying send with PIN', { targetAlias: device.alias, direction: 'send' });
        continue;
      }
      // 409 = 接收方正忙（有残留 session），尝试发送 cancel 清理后重试
      if (err !== undefined && err.kind === 'statusCode' && err.status === 409 && busyRetries < MAX_BUSY_RETRIES) {
        busyRetries++;
        // 用上一次发送的 sessionId cancel（能清除 Active session）
        let lastSessionId: string = nativeGetCurrentSendSessionId();
        if (lastSessionId.length > 0) {
          logger.debug('Recipient busy (409), sending cancel (sessionId=' +
            lastSessionId.substring(0, 8) + '...) to clear session, retry ' + busyRetries, sendCtx);
          let cancelTarget: NativeCancelTarget = {
            ip: device.ip,
            port: device.port,
            fingerprint: device.fingerprint,
            protocol: actualProtocol
          };
          try {
            await nativeCancelTransfer(cancelTarget, lastSessionId);
          } catch (_ce) {
            logger.warn('Cancel request failed (non-fatal): ' + String(_ce), sendCtx);
          }
          // 等待接收端处理 cancel 并释放 session slot
          await new Promise<void>((resolve: (value: void) => void) => setTimeout(() => resolve(), 800));
        } else {
          logger.debug('Recipient busy (409) but no known sessionId, retry ' + busyRetries, sendCtx);
        }
        continue;
      }
      break;
    }
    if (result !== undefined) {
      // 发送失败后向接收端发送 cancel，清理可能残留的 session
      let cancelSessionId: string = result.sessionId.length > 0 ? result.sessionId : '';
      if (cancelSessionId.length === 0) {
        cancelSessionId = nativeGetCurrentSendSessionId();
      }
      // 只在有 sessionId 时发送 cancel（空 sessionId 对上游无意义）
      if (cancelSessionId.length > 0) {
        let cancelTarget: NativeCancelTarget = {
          ip: device.ip,
          port: device.port,
          fingerprint: device.fingerprint,
          protocol: actualProtocol
        };
        try {
          await nativeCancelTransfer(cancelTarget, cancelSessionId);
          logger.debug('Sent cancel after send failure (sessionId=' +
            cancelSessionId.substring(0, 8) + '...)', { direction: 'send' });
        } catch (_ce) {
          logger.warn('Cancel after send failure failed (non-fatal): ' + String(_ce), { direction: 'send' });
        }
      } else {
        logger.debug('No sessionId available, skip cancel after send failure', { direction: 'send' });
      }
      return finishSendFailure(result, files);
    }
    return { success: false, error: { kind: 'other', message: 'Send cancelled' } };
  } catch (e) {
    // 调用抛异常（Rust 未接管 fd）：关闭本次已打开句柄，避免泄漏
    for (let k = 0; k < pendingFileHandles.length; k++) {
      try {
        fs.closeSync(pendingFileHandles[k]);
      } catch (_ce) {
      }
    }
    pendingFileHandles = [];
    logger.error('Send exception: ' + e, { direction: 'send', targetIp: device.ip });
    notifyChange();
    return { success: false, error: { kind: 'other', message: String(e) } };
  } finally {
    drainNativeDebugLog();
  }
}

// 弹出 PIN 输入弹窗，等待用户输入；用户取消返回 undefined
function askForPin(deviceName: string, isRetry: boolean): Promise<string | undefined> {
  let pinErrorHint = '';
  if (isRetry) {
    pinErrorHint = localizedText($r('app.string.pin_dialog_error'), 'PIN code incorrect, please try again');
  }
  return new Promise<string | undefined>((resolve) => {
    DialogService.showPinDialog(deviceName, pinErrorHint, (pin: string) => {
      if (pin.length > 0) {
        resolve(pin);
      } else {
        resolve(undefined);
      }
    });
  });
}

// 发送失败结果处理（含文本发送的特殊成功分支）
function finishSendFailure(result: NativeSendResult, files: Array<SendFileItem>): SendResult {
  let sid: string = result.sessionId ?? '';
  if (result.error !== undefined && result.error.kind === 'statusCode' && result.error.status === 204 &&
    isTextOnlySend(files)) {
    logger.debug('Text message delivered (204 = preview-only delivery)',
      { sessionId: result.sessionId, direction: 'send' });
    notifyChange();
    return { success: true, sessionId: sid };
  }
  if (result.error !== undefined && result.error.kind === 'statusCode' && result.error.status === 403 &&
    isTextOnlySend(files)) {
    logger.debug('Text message viewed but declined (403)', { sessionId: result.sessionId, direction: 'send' });
    notifyChange();
    return { success: true, sessionId: sid };
  }
  if (result.error !== undefined && result.error.kind === 'partialFailure' && isTextOnlySend(files)) {
    logger.debug('Text message delivered (partialFailure = preview-only)',
      { sessionId: result.sessionId, direction: 'send' });
    notifyChange();
    return { success: true, sessionId: sid };
  }
  let errorMsg = 'Send failed: ' + result.failedFiles.join(', ');
  if (result.error !== undefined && result.error.message !== undefined) {
    errorMsg = result.error.message;
  }
  if (result.error !== undefined && result.error.kind === 'statusCode') {
    logger.warn('Send declined: HTTP ' + result.error.status, { sessionId: result.sessionId, direction: 'send' });
  } else {
    logger.error('Send failed: ' + errorMsg, { sessionId: result.sessionId, direction: 'send' });
  }
  notifyChange();
  return { success: false, error: result.error, sessionId: sid };
}

// 检查本次发送的所有文件是否仅含文本（预览已包含内容）
function isTextOnlySend(files: Array<SendFileItem>): boolean {
  for (let i = 0; i < files.length; i++) {
    if (files[i].fileType !== 'text/plain') {
      return false;
    }
  }
  return files.length > 0;
}

// ── 发送进度日志（由 ReceiveRepository 为发送方向事件调用） ──

export function handleSendProgress(progress: TransferProgress): void {
  let sessionId: string = progress.sessionId;
  let fileId: string = progress.fileId;
  let bytesSent: number = progress.bytesSent;
  let totalBytes: number = progress.totalBytes;

  // 检查该发送文件是否刚完成
  if (bytesSent >= totalBytes && totalBytes > 0) {
    logger.debug('File upload complete', { sessionId: sessionId, fileId: fileId, direction: 'send' });
  } else {
    logger.debug('File progress: ' + bytesSent + '/' + totalBytes + ' bytes',
      { sessionId: sessionId, fileId: fileId, direction: 'send' });
  }
}

// ── 文件暂存 / 准备 ──

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

export async function prepareSendFiles(
  uris: Array<string>
): Promise<Array<SendFileItem>> {
  // 新一次发送开始前，消费上次发送遗留的完成标志并清理暂存目录。
  // 否则该标志可能在本次发送期间被 refresh() 消费，误删刚写入 send/ 的手动文本文件。
  isSendCompletedAndReset();
  let items: Array<SendFileItem> = [];
  for (let i = 0; i < uris.length; i++) {
    try {
      let uri = uris[i];
      let rawName = extractFileName(uri);
      if (rawName === '' || rawName.length > 200) {
        rawName = 'file_' + Date.now();
      }
      // 净化文件名，确保其符合当前平台规范
      rawName = nativeSanitizeFileName(rawName);
      // 不再复制文件到沙箱：filePath 直接承载源定位（picker URI 或沙箱路径），
      // 发送时由 sendToDevice 打开 fd 直读源文件；此处仅 open+stat 取真实大小后立即关闭
      let file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      let size: number;
      try {
        size = fs.statSync(file.fd).size;
      } finally {
        fs.closeSync(file);
      }
      // preview 仅用于手动输入文本（由调用方根据 isManualText 补设），
      // 文件选择器选取的 txt 文件不应带 preview，否则接收端会误判为文本消息、
      // 网页分享也会错误显示文本预览
      items.push({
        fileId: 'send_' + i + '_' + Date.now(),
        filePath: uri,
        fileName: rawName,
        fileType: getMimeForExt(rawName),
        size: size,
        preview: undefined
      });
    } catch (e) {
      logger.error('Failed to prepare file: ' + e);
    }
  }
  return items;
}

export function markSendCompleted(): void {
  pendingSendCompleted = true;
  // 发送完成立即清理暂存文件并通知刷新：
  // 1) 不依赖 refresh() 的触发时机，避免暂存文件遗留混入下次发送；
  // 2) notifyChange 触发 SendViewModel.refresh() → isSendCompletedAndReset()
  //    消费标志并清空文件列表。notifyChange 必须在标志置位后发出，
  //    否则列表残留、标志遗留到下次发送期间被 refresh() 消费而误删
  //    本次发送的文件（接收端 0 字节 → 500）。
  cleanupSendDir();
  notifyChange();
}

export function isSendCompletedAndReset(): boolean {
  if (pendingSendCompleted) {
    pendingSendCompleted = false;
    cleanupSendDir();
    return true;
  }
  return false;
}

export function cleanupSendDir(): void {
  let appContext = getAppContext();
  if (appContext === undefined) {
    return;
  }
  cleanupSendDirWithContext(appContext);
}

// 带 context 的清理变体：供冷启动（EntryAbility.onCreate）使用——
// 此时 AppCore 尚未保存应用 context，getAppContext() 返回 undefined。
// 仅限启动清扫场景调用；运行期清理一律走 cleanupSendDir()。
// 清理 {cacheDir}/send/（手动文本暂存临时目录），并顺带清空旧版本
// 遗留的 {filesDir}/send/（已不再写入，全量删除安全）。
export function cleanupSendDirWithContext(context: common.UIAbilityContext): void {
  clearDirContents(context.cacheDir + '/send/');
  clearDirContents(context.filesDir + '/send/');
}

// 清空目录内全部文件（目录不存在时静默跳过），best-effort：单文件删除失败不阻塞。
function clearDirContents(dirPath: string): void {
  try {
    let entries = fs.listFileSync(dirPath);
    for (let i = 0; i < entries.length; i++) {
      try {
        fs.unlinkSync(dirPath + entries[i]);
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
    // 缓冲元素带 `level|message` 前缀；此处统一按 debug 输出，仅剥离前缀避免串扰
    let line = lines[i];
    let sep = line.indexOf('|');
    let message = sep >= 0 ? line.substring(sep + 1) : line;
    logger.debug('Rust: ' + message);
  }
}

// ── 发送会话管理 ──

export function getSendSessions(): Array<SendSessionState> {
  let result: Array<SendSessionState> = [];
  sendSessions.forEach((state: SendSessionState) => {
    result.push(state);
  });
  return result;
}

export function createSendSession(sessionId: string, targetIp: string,
  targetAlias: string, files: Array<SendFileItem>): void {
  // 若同一目标设备已有会话（例如用户在发送成功后再次点击同一设备），
  // 先清除旧会话及其残留进度，避免新会话被 fileId 回退匹配到旧进度而直接显示 100%。
  let removed: Array<string> = [];
  sendSessions.forEach((existing: SendSessionState, existingId: string) => {
    if (existing.targetIp === targetIp) {
      removed.push(existingId);
      if (existing.receiverSessionId !== undefined && existing.receiverSessionId.length > 0) {
        removeProgressForSession(existing.receiverSessionId);
      }
    }
  });
  for (let i = 0; i < removed.length; i++) {
    sendSessions.delete(removed[i]);
  }
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
  // 该 id 若存在挂起的延迟清理（同 id 重建场景），取消以免新会话被误删
  cancelSessionCleanup(sessionId);
  notifyChange();
}

export function clearAllSendSessions(): void {
  pendingSessionCleanups.forEach((timerId: number) => {
    clearTimeout(timerId);
  });
  pendingSessionCleanups.clear();
  sendSessions.clear();
  notifyChange();
}

// 记录某发送会话对应的接收方会话 id（UUID），供重新发送时清除该会话残留进度。
function updateSendSessionReceiverId(sessionId: string, receiverId: string): void {
  let state = sendSessions.get(sessionId);
  if (state !== undefined && receiverId.length > 0) {
    state.receiverSessionId = receiverId;
  }
}

// 判断发送会话是否处于终态（终态才会触发延迟清理）
function isTerminalSendStatus(status: SendSessionStatus): boolean {
  return status === SendSessionStatus.finished || status === SendSessionStatus.finishedWithErrors ||
    status === SendSessionStatus.declined || status === SendSessionStatus.viewed ||
    status === SendSessionStatus.recipientBusy || status === SendSessionStatus.tooManyAttempts ||
    status === SendSessionStatus.timeout || status === SendSessionStatus.pinRequired;
}

// 取消会话挂起的延迟清理定时器
function cancelSessionCleanup(sessionId: string): void {
  let timerId = pendingSessionCleanups.get(sessionId);
  if (timerId !== undefined) {
    clearTimeout(timerId);
    pendingSessionCleanups.delete(sessionId);
  }
}

export function updateSendSessionStatus(sessionId: string, status: SendSessionStatus,
  errorMessage?: string): void {
  let state = sendSessions.get(sessionId);
  if (state !== undefined) {
    state.status = status;
    if (errorMessage !== undefined) {
      state.errorMessage = errorMessage;
    }
    // 延迟后自动清理终态会话，并同步清除该会话残留进度
    if (isTerminalSendStatus(status)) {
      // 同一会话可能反复更新到终态（事件竞态）：先取消旧定时器避免叠加
      cancelSessionCleanup(sessionId);
      let receiverId: string = state.receiverSessionId ?? '';
      let timerId: number = setTimeout(() => {
        pendingSessionCleanups.delete(sessionId);
        // 等待期内会话被重建/复用时不再清理，避免误删
        let current = sendSessions.get(sessionId);
        if (current === undefined || !isTerminalSendStatus(current.status)) {
          return;
        }
        sendSessions.delete(sessionId);
        if (receiverId.length > 0) {
          removeProgressForSession(receiverId);
        }
        notifyChange();
      }, 5000);
      pendingSessionCleanups.set(sessionId, timerId);
    } else {
      // 非终态更新：取消挂起的清理，防止终态→非终态竞态误删
      cancelSessionCleanup(sessionId);
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

// ── 多设备发送：并行发送到多台设备 ──

export async function sendToDeviceMulti(
  devices: Array<DiscoveredDevice>,
  files: Array<SendFileItem>
): Promise<void> {
  // 为每台设备创建独立的会话，使用一致的 sessionId
  let sessionIds: Array<string> = [];
  for (let i = 0; i < devices.length; i++) {
    let sessionId = 'multi_' + Date.now() + '_' + i;
    sessionIds.push(sessionId);
    let device = devices[i];
    createSendSession(sessionId, device.ip, device.alias, files);
  }

  // 并行发送到每台设备
  let promises: Array<Promise<SendResult>> = [];
  for (let i = 0; i < devices.length; i++) {
    let device = devices[i];
    promises.push(sendToDeviceWithSession(device, files, sessionIds[i]));
  }

  // 等待所有发送完成（但不因错误而阻塞）
  let results = await Promise.all(promises);

  // 仅为成功的发送更新会话状态
  // 失败的发送已由 sendToDeviceWithSession 设置精确状态（declined、tooManyAttempts 等）
  for (let i = 0; i < devices.length; i++) {
    if (results[i].success) {
      updateSendSessionStatus(sessionIds[i], SendSessionStatus.finished);
    }
  }
  notifyChange();
  // 不在此处清理 send/ 目录：fd 直读改造后该目录仅存手动文本暂存文件
  // （多目标模式下暂存列表保留，文件需继续可用来发送给更多设备）。
}

// 判断错误是否为超时/连接失败（接收方未响应），与 sendResultErrorMessage 中的映射逻辑一致
function isTimeoutOrConnectionError(err: NativeHttpError): boolean {
  if (err.kind === 'reqwest' || err.kind === 'cancelled') {
    let msg: string = '';
    if (err.message !== undefined) {
      msg = err.message.toLowerCase();
    }
    if (msg.indexOf('timed out') >= 0 || msg.indexOf('timeout') >= 0 ||
      msg.indexOf('error sending request') >= 0 || msg.indexOf('connect') >= 0 ||
      msg.indexOf('connection') >= 0 || msg.indexOf('reset') >= 0) {
      return true;
    }
  }
  return false;
}

async function sendToDeviceWithSession(
  device: DiscoveredDevice,
  files: Array<SendFileItem>,
  sessionId: string
): Promise<SendResult> {
  updateSendSessionStatus(sessionId, SendSessionStatus.sending);
  let result = await sendToDevice(device, files);
  // 记录接收方会话 id（UUID），供重新发送到同一设备时清除此会话残留进度，避免进度直接 100%。
  if (result.sessionId !== undefined && result.sessionId.length > 0) {
    updateSendSessionReceiverId(sessionId, result.sessionId);
  }
  if (result.success) {
    // 成功状态将由 sendToDeviceMulti 设置
  } else if (result.error !== undefined) {
    let err = result.error;
    let errMsg = sendResultErrorMessage(err);
    if (err.kind === 'statusCode' && err.status !== undefined) {
      let status = err.status;
      if (status === 401) {
        updateSendSessionStatus(sessionId, SendSessionStatus.pinRequired, errMsg);
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
        updateSendSessionStatus(sessionId, SendSessionStatus.finishedWithErrors, errMsg);
      }
    } else {
      if (err.kind === 'partialFailure' && isTextOnlySend(files)) {
        updateSendSessionStatus(sessionId, SendSessionStatus.finished);
        return { success: true };
      }
      let msg = err.message !== undefined ? err.message : '';
      if (msg.indexOf('declined') >= 0 || msg.indexOf('rejected') >= 0) {
        updateSendSessionStatus(sessionId, SendSessionStatus.declined);
      } else if (isTimeoutOrConnectionError(err)) {
        updateSendSessionStatus(sessionId, SendSessionStatus.timeout);
      } else {
        updateSendSessionStatus(sessionId, SendSessionStatus.finishedWithErrors, errMsg);
      }
    }
  } else {
    // 无错误信息——通用失败
    updateSendSessionStatus(sessionId, SendSessionStatus.finishedWithErrors);
  }
  return result;
}
