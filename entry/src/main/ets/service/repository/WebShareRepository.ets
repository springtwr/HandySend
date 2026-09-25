import { fileIo as fs } from '@kit.CoreFileKit';
import { getLogger } from '../../utils/Logger';
import { LogContext } from '../../common/LogFormat';
import { LogDomains } from '../../common/LogDomains';
import { SendFileItem, PendingWebDownload } from '../../model/Types';
import {
  NativeFileToSend,
  NativeWebSendPrepareDownloadEvent,
  NativeWebSendFileDownloadEvent,
  NativeWebSendProgressEvent
} from '../../model/NativeTypes';
import {
  nativeCreateShareLink,
  nativeStopShareServer,
  nativeStartWebUpload,
  nativeAcceptWebDownload,
  nativeDeclineWebDownload
} from '../NativeBridge';
import { getAppContext, notifyChange } from './AppCore';
import { getHttpsEnabled, getAutoAcceptWebDownload } from './SettingsRepository';
import { getDeviceAlias, getLocalDeviceInfo } from './DeviceRepository';
import {
  beginWebDownloadBurst,
  handleWebDownloadProgress,
  handleWebFileDownload,
  markWebDownloadAccepted,
  markWebDownloadDeclined,
  setWebDownloadInvokers
} from '../transfer/adapters/WebDownloadAdapter';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:WebShareRepository', '网页分享');

// ── Web 分享链接状态 ──

let shareLinkInfo: string = '';
let sharePort: number = 0;

// 当前分享打开的源文件句柄集合：模块级持有 fs.File 引用，阻止 GC 回收
// 对象时 fd 被自动关闭（否则 Rust 侧将持有失效 fd）。fd 所有权归本层——
// Rust 每次下载仅 dup 副本消费、从不关闭原始 fd；本层在停止/替换分享、
// 创建失败、切换上传模式时统一 closeSync 关闭。
let shareFileHandles: Array<fs.File> = [];

// 当前分享的源文件档案（fileId → 本地位置）：分享创建成功后写入，
// 下载事件按 fileId 命中，为会话文件回填本地内容位置（供文本内容预览）；
// 停止分享或切换为上传模式时清空（与分享句柄同生命周期）。
interface ShareFileProfile {
  path: string
}

let shareFileProfiles: Record<string, ShareFileProfile> = {};

/** 登记本次分享的源文件档案（分享创建成功后调用）。 */
function registerShareFileProfiles(files: Array<SendFileItem>): void {
  let next: Record<string, ShareFileProfile> = {};
  for (let i = 0; i < files.length; i++) {
    let f = files[i];
    next[f.fileId] = { path: f.filePath };
  }
  shareFileProfiles = next;
}

/** 清空分享源文件档案（停止分享/切换上传模式时调用）。 */
function clearShareFileProfiles(): void {
  shareFileProfiles = {};
}

/**
 * 关闭当前分享持有的全部源文件句柄并清空。
 * 调用时机由调用方保证：须在服务器已停止接受该分享的下载请求之后
 * （stopShareLink/startWebUpload 的 native 调用返回后，或创建新分享
 * 替换旧分享时），避免"句柄关闭后仍被下载读取"的竞态。
 */
function closeShareFileHandles(): void {
  for (let i = 0; i < shareFileHandles.length; i++) {
    try {
      fs.closeSync(shareFileHandles[i]);
    } catch (_ce) {
    }
  }
  shareFileHandles = [];
}

// ── Web 下载请求确认状态 ──

let pendingWebDownloads: Array<PendingWebDownload> = [];
let webDownloadSessionStates: Record<string, string> = {};

// 会话文件大小表（sessionId:fileId → 字节数）与已完成文件表，用于聚合分母与终态判定
let webDownloadFileSizes: Record<string, number> = {};
let webDownloadFileDone: Record<string, boolean> = {};
// 会话静默判定定时器（sessionId → timer id）：文件下载完成后延迟判定会话是否终态
let webDownloadQuietTimers: Record<string, number> = {};

// 下载完成后的静默窗口（毫秒）：期间无新文件/进度事件即判定会话成功终态，
// 避免浏览器连续下载多个文件时在文件间隙误判完成
const WEB_DOWNLOAD_QUIET_MS = 3000;

// 清理某会话的下载进度跟踪数据（会话替换/分享停止时调用）
function clearWebDownloadTracking(sessionId: string): void {
  let sizeKeys: Array<string> = Object.keys(webDownloadFileSizes);
  let newSizes: Record<string, number> = {};
  for (let i = 0; i < sizeKeys.length; i++) {
    if (sizeKeys[i].indexOf(sessionId + ':') !== 0) {
      newSizes[sizeKeys[i]] = webDownloadFileSizes[sizeKeys[i]];
    }
  }
  webDownloadFileSizes = newSizes;
  let doneKeys: Array<string> = Object.keys(webDownloadFileDone);
  let newDone: Record<string, boolean> = {};
  for (let i = 0; i < doneKeys.length; i++) {
    if (doneKeys[i].indexOf(sessionId + ':') !== 0) {
      newDone[doneKeys[i]] = webDownloadFileDone[doneKeys[i]];
    }
  }
  webDownloadFileDone = newDone;
  let existingTimer: number | undefined = webDownloadQuietTimers[sessionId];
  if (existingTimer !== undefined) {
    clearTimeout(existingTimer);
    let newTimers: Record<string, number> = {};
    let timerKeys: Array<string> = Object.keys(webDownloadQuietTimers);
    for (let i = 0; i < timerKeys.length; i++) {
      if (timerKeys[i] !== sessionId) {
        newTimers[timerKeys[i]] = webDownloadQuietTimers[timerKeys[i]];
      }
    }
    webDownloadQuietTimers = newTimers;
  }
}

// 该会话已知文件是否全部下载完成（至少已知一个文件）
function allWebDownloadFilesDone(sessionId: string): boolean {
  let sizeKeys: Array<string> = Object.keys(webDownloadFileSizes);
  let known: number = 0;
  let done: number = 0;
  for (let i = 0; i < sizeKeys.length; i++) {
    if (sizeKeys[i].indexOf(sessionId + ':') === 0) {
      known++;
      if (webDownloadFileDone[sizeKeys[i]] === true) {
        done++;
      }
    }
  }
  return known > 0 && done === known;
}

// 安排会话终态判定：静默窗口后若已知文件全部完成则标记会话成功终态
function scheduleWebDownloadQuietCheck(sessionId: string): void {
  let existing: number | undefined = webDownloadQuietTimers[sessionId];
  if (existing !== undefined) {
    clearTimeout(existing);
  }
  webDownloadQuietTimers[sessionId] = setTimeout(() => {
    let newTimers: Record<string, number> = {};
    let timerKeys: Array<string> = Object.keys(webDownloadQuietTimers);
    for (let i = 0; i < timerKeys.length; i++) {
      if (timerKeys[i] !== sessionId) {
        newTimers[timerKeys[i]] = webDownloadQuietTimers[timerKeys[i]];
      }
    }
    webDownloadQuietTimers = newTimers;
    // 会话已被替换/清理：不判定
    let state: string | undefined = webDownloadSessionStates[sessionId];
    if (state === undefined || state === 'pending' || state === 'finished' || state === 'declined') {
      return;
    }
    if (allWebDownloadFilesDone(sessionId)) {
      webDownloadSessionStates[sessionId] = 'finished';
      logger.info('Web download session finished: session=' + sessionId);
      notifyChange();
    }
  }, WEB_DOWNLOAD_QUIET_MS);
}

export function getShareLink(): string {
  return shareLinkInfo;
}

export async function createShareLink(files: Array<SendFileItem>): Promise<void> {
  let appContext = getAppContext();
  if (appContext === undefined) {
    logger.error('AppService not initialized');
    return;
  }
  // fd-direct：为每个源文件打开读 fd 一并交给 Rust；本层持有 fs.File
  // 对象至分享结束（Rust 每次下载 dup 副本直读，原始 fd 由本层关闭）
  let nativeFiles: Array<NativeFileToSend> = [];
  let openedHandles: Array<fs.File> = [];
  try {
    for (let i = 0; i < files.length; i++) {
      let f = files[i];
      let file = fs.openSync(f.filePath, fs.OpenMode.READ_ONLY);
      openedHandles.push(file);
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
  } catch (e) {
    // 任一源文件打开失败：关闭已打开句柄，不创建链接
    // （旧分享句柄未动，其链接保持可用）
    for (let k = 0; k < openedHandles.length; k++) {
      try {
        fs.closeSync(openedHandles[k]);
      } catch (_ce) {
      }
    }
    logger.error('open source file failed: ' + e);
    notifyChange();
    return;
  }
  try {
    let result = await nativeCreateShareLink(nativeFiles, getDeviceAlias());
    // 新分享创建成功：此时才关闭旧分享句柄（先关会造成替换失败时
    // 旧链接悬空——URL 仍有效但源 fd 已失效），并移交新句柄长期持有
    closeShareFileHandles();
    shareFileHandles = openedHandles;
    sharePort = result.port;
    // 使用 ArkTS 侧的本地 IP 构建 URL（比 Rust server_handle 的 IP 更可靠）
    let localIp = getLocalDeviceInfo().ip;
    let protocol = getHttpsEnabled() ? 'https' : 'http';
    shareLinkInfo = protocol + '://' + localIp + ':' + sharePort;
    logger.info('Share link created: ' + shareLinkInfo);
    // 登记本次分享的文件档案：供下载事件回填真实文件名与本地内容位置
    registerShareFileProfiles(files);
  } catch (e) {
    // 链接创建失败：关闭本次打开的全部句柄；旧分享句柄与链接保持一致可用，
    // 留待 stopShareLink 或下次成功创建时统一收口
    logger.error('Share link failed: ' + e);
    for (let k = 0; k < openedHandles.length; k++) {
      try {
        fs.closeSync(openedHandles[k]);
      } catch (_ce) {
      }
    }
  }
  notifyChange();
}

export async function stopShareLink(): Promise<void> {
  logger.debug('called');
  try {
    await nativeStopShareServer();
  } catch (_e) {
  }
  // 服务器已停止（不再接受新请求）：关闭分享持有的全部源文件句柄
  closeShareFileHandles();
  shareLinkInfo = '';
  sharePort = 0;
  clearShareFileProfiles();
  // 清理 Web 下载请求确认状态与全部会话的进度跟踪
  pendingWebDownloads = [];
  let allSessions: Array<string> = Object.keys(webDownloadSessionStates);
  for (let i = 0; i < allSessions.length; i++) {
    clearWebDownloadTracking(allSessions[i]);
  }
  webDownloadSessionStates = {};
  // 服务器已由 Rust stop_share_server 以正常模式重启
  logger.info('Share server stopped, server restored to normal mode');
  notifyChange();
}

/**
 * 启动 Web 上传模式：以启用上传的方式重启服务器，
 * 以便浏览器可通过 v2 协议向本设备上传文件。
 */
export async function startWebUpload(): Promise<void> {
  let webCtx: LogContext = { direction: 'share', protocol: getHttpsEnabled() ? 'https' : 'http' };
  logger.debug('httpsEnabled=' + getHttpsEnabled().toString(), webCtx);
  try {
    let uploadPort: number = await nativeStartWebUpload();
    logger.debug('nativeStartWebUpload returned port=' + uploadPort, webCtx);
    if (uploadPort <= 0) {
      logger.error('Web upload start failed: invalid port ' + uploadPort);
      notifyChange();
      return;
    }
    // 分享模式 → 上传模式切换：服务器已重启为上传模式（不再接受分享下载），
    // 回收遗留的分享句柄与文件档案
    closeShareFileHandles();
    clearShareFileProfiles();
    sharePort = uploadPort;
    let localIp = getLocalDeviceInfo().ip;
    shareLinkInfo = (getHttpsEnabled() ? 'https' : 'http') + '://' + localIp + ':' + sharePort;
    logger.debug('shareLink=' + shareLinkInfo, webCtx);
    logger.info('Web upload started: ' + shareLinkInfo);
  } catch (e) {
    logger.error('Web upload start failed: ' + e, webCtx);
  }
  notifyChange();
}

// ── Web 下载事件（由 handleNativeEvent 路由） ──

export function handlePrepareDownloadTyped(event: NativeWebSendPrepareDownloadEvent): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length === 0) {
    logger.warn('WebPrepareDownload event with empty sessionId, ignoring');
    return;
  }
  let ip: string = event.ip;

  // 网页场景 sessionId 即客户端 IP，打完整值便于定位问题
  logger.debug('sessionId=' + sessionId + ' ip=' + ip, { direction: 'share' });
  logger.info('Web download request from ' + ip + ' (session=' + sessionId + ')');

  // Web 下载自动接受遵循「自动确认下载请求」设置（而非自动确认请求三段式）
  let autoAcceptWebDownload: boolean = getAutoAcceptWebDownload();
  if (autoAcceptWebDownload) {
    logger.info('Web download auto-accepted (autoAcceptWebDownload=true)');
    logger.debug('calling nativeAcceptWebDownload(sessionId=' + sessionId + ')');
    nativeAcceptWebDownload(sessionId);
    // 自动接受时也记录状态为 accepted
    webDownloadSessionStates[sessionId] = 'accepted';
    // 统一会话事实源：一次下载突发 = 一个会话（自动接受直接进行中）
    beginWebDownloadBurst(ip, false);
    markWebDownloadAccepted(ip);
  } else {
    logger.info('Web download requires confirmation (autoAcceptWebDownload=false)');
    // 同一 IP 新请求替换旧请求（Rust 核心限制每个 IP 一个 session）
    let existingIdx: number = -1;
    for (let i = 0; i < pendingWebDownloads.length; i++) {
      if (pendingWebDownloads[i].ip === ip) {
        existingIdx = i;
        break;
      }
    }
    if (existingIdx >= 0) {
      // 移除旧请求
      let oldSessionId: string = pendingWebDownloads[existingIdx].sessionId;
      // ArkTS 禁止 delete，重建 Record 移除旧 key
      let newStates: Record<string, string> = {};
      let allKeys: Array<string> = Object.keys(webDownloadSessionStates);
      for (let i = 0; i < allKeys.length; i++) {
        if (allKeys[i] !== oldSessionId) {
          newStates[allKeys[i]] = webDownloadSessionStates[allKeys[i]];
        }
      }
      webDownloadSessionStates = newStates;
      pendingWebDownloads.splice(existingIdx, 1);
      clearWebDownloadTracking(oldSessionId);
    }
    // 入队列
    let download: PendingWebDownload = {
      sessionId: sessionId,
      ip: ip,
      userAgent: event.userAgent,
      timestamp: Date.now()
    };
    pendingWebDownloads.push(download);
    webDownloadSessionStates[sessionId] = 'pending';
    // 统一会话事实源：待确认会话（新增后由用户在任务确认/拒绝）；
    // 后台待确认提示通知由 PendingRequestNotifier 订阅注册表统一发布
    beginWebDownloadBurst(ip, true);
    notifyChange();
  }
}

export function handleFileDownloadTyped(event: NativeWebSendFileDownloadEvent): void {
  if (event.sessionId.length > 0) {
    logger.debug('sessionId=' + event.sessionId + ' fileId=' + event.fileId + ' name=' +
      event.fileName + ' size=' + event.size, { fileId: event.fileId, direction: 'share' });
    logger.info('Web file download: ' + event.fileName + ' (' + event.size + ' bytes) session=' +
      event.sessionId);
    // 记录文件大小（聚合分母）；空文件无进度事件，直接标记完成
    let sizeKey: string = event.sessionId + ':' + event.fileId;
    webDownloadFileSizes[sizeKey] = event.size;
    if (event.size <= 0) {
      webDownloadFileDone[sizeKey] = true;
    }
    // 统一会话事实源：按事件携带的真实文件名登记文件（分母增长）并重置静默窗口；
    // 命中分享文件档案时一并透传本地内容位置，供文本内容预览读取
    let profile: ShareFileProfile | undefined = shareFileProfiles[event.fileId];
    let localPath: string = profile !== undefined ? profile.path : '';
    handleWebFileDownload(event.sessionId, event.fileId, event.fileName, event.size, localPath);
    // 文件下载事件作为传输活跃信号，标记会话为 accepted（终态会话重新下载时复位）
    let currentState: string | undefined = webDownloadSessionStates[event.sessionId];
    if (currentState === undefined || currentState === 'pending' || currentState === 'finished') {
      webDownloadSessionStates[event.sessionId] = 'accepted';
    }
    scheduleWebDownloadQuietCheck(event.sessionId);
    notifyChange();
  }
}

// Web 下载字节级进度：记录会话×文件的已发送/总字节，文件到达终值时按静默窗口判定会话终态
export function handleWebSendProgressTyped(event: NativeWebSendProgressEvent): void {
  let sessionId: string = event.sessionId;
  let fileId: string = event.fileId;
  if (sessionId.length === 0 || fileId.length === 0) {
    return;
  }
  let sizeKey: string = sessionId + ':' + fileId;
  // 进度事件携带真实总大小，优先以其为准
  if (event.totalBytes > 0) {
    webDownloadFileSizes[sizeKey] = event.totalBytes;
  }
  if (event.totalBytes > 0 && event.sentBytes >= event.totalBytes) {
    webDownloadFileDone[sizeKey] = true;
  }
  // 统一会话事实源：同步字节进度（分母以事件携带的真实总大小为准）
  handleWebDownloadProgress(sessionId, fileId, event.sentBytes, event.totalBytes);
  let state: string | undefined = webDownloadSessionStates[sessionId];
  if (state !== 'finished' && state !== 'declined') {
    webDownloadSessionStates[sessionId] = 'transferring';
  }
  scheduleWebDownloadQuietCheck(sessionId);
  notifyChange();
}

// ── Web 下载请求确认操作 ──

export function getPendingWebDownloads(): Array<PendingWebDownload> {
  return pendingWebDownloads;
}

export function acceptWebDownloadRequest(sessionId: string): void {
  let idx: number = -1;
  for (let i = 0; i < pendingWebDownloads.length; i++) {
    if (pendingWebDownloads[i].sessionId === sessionId) {
      idx = i;
      break;
    }
  }
  if (idx < 0) {
    logger.warn('session not found in pending list, sessionId=' + sessionId);
    return;
  }
  // 调用 Rust 侧接受
  nativeAcceptWebDownload(sessionId);
  // 更新状态并从待确认队列移除（清除该会话可能的旧进度跟踪）
  clearWebDownloadTracking(sessionId);
  webDownloadSessionStates[sessionId] = 'accepted';
  pendingWebDownloads.splice(idx, 1);
  // 统一会话事实源：确认后进入进行中并安排接受后无活动超时
  markWebDownloadAccepted(sessionId);
  logger.info('Web download accepted: session=' + sessionId);
  notifyChange();
}

export function declineWebDownloadRequest(sessionId: string): void {
  let idx: number = -1;
  for (let i = 0; i < pendingWebDownloads.length; i++) {
    if (pendingWebDownloads[i].sessionId === sessionId) {
      idx = i;
      break;
    }
  }
  if (idx < 0) {
    logger.warn('session not found in pending list, sessionId=' + sessionId);
    return;
  }
  // 调用 Rust 侧拒绝
  nativeDeclineWebDownload(sessionId);
  // 更新状态并从待确认队列移除
  clearWebDownloadTracking(sessionId);
  webDownloadSessionStates[sessionId] = 'declined';
  pendingWebDownloads.splice(idx, 1);
  // 统一会话事实源：拒绝终态
  markWebDownloadDeclined(sessionId);
  logger.info('Web download declined: session=' + sessionId);
  notifyChange();
}

export function declineAllPendingWebDownloads(): void {
  if (pendingWebDownloads.length === 0) {
    return;
  }
  // 拒绝所有待确认请求
  for (let i = 0; i < pendingWebDownloads.length; i++) {
    let sessionId: string = pendingWebDownloads[i].sessionId;
    nativeDeclineWebDownload(sessionId);
    clearWebDownloadTracking(sessionId);
    webDownloadSessionStates[sessionId] = 'declined';
    markWebDownloadDeclined(sessionId);
    logger.info('Web download declined (bulk): session=' + sessionId);
  }
  pendingWebDownloads = [];
  notifyChange();
}

export function hasActiveWebDownloads(): boolean {
  // 遍历状态映射，检查是否有已接受/传输中的会话（含下载推进中的 transferring）
  let keys: Array<string> = Object.keys(webDownloadSessionStates);
  for (let i = 0; i < keys.length; i++) {
    let state: string = webDownloadSessionStates[keys[i]];
    if (state === 'accepted' || state === 'transferring') {
      return true;
    }
  }
  return false;
}

// 注册 Web 下载确认/拒绝入口：任务的待确认操作经适配器回调本仓库
setWebDownloadInvokers(
  (ip: string): void => {
    acceptWebDownloadRequest(ip);
  },
  (ip: string): void => {
    declineWebDownloadRequest(ip);
  }
);
