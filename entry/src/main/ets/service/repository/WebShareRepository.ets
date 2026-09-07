import { fileIo as fs } from '@kit.CoreFileKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { SendFileItem, PendingWebDownload } from '../../model/Types';
import {
  NativeFileToSend,
  NativeWebSendPrepareDownloadEvent,
  NativeWebSendFileDownloadEvent
} from '../../model/NativeTypes';
import {
  nativeCreateShareLink,
  nativeStopShareServer,
  nativeStartWebUpload,
  nativeAcceptWebDownload,
  nativeDeclineWebDownload
} from '../NativeBridge';
import { getAppContext, addLog, notifyChange, shortSid } from './AppCore';
import { getHttpsEnabled, getAutoAcceptWebDownload } from './SettingsRepository';
import { getDeviceAlias, getLocalDeviceInfo } from './DeviceRepository';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:WebShareRepository');

// ── Web 分享链接状态 ──

let shareLinkInfo: string = '';
let sharePort: number = 0;

// 当前分享打开的源文件句柄集合：模块级持有 fs.File 引用，阻止 GC 回收
// 对象时 fd 被自动关闭（否则 Rust 侧将持有失效 fd）。fd 所有权归本层——
// Rust 每次下载仅 dup 副本消费、从不关闭原始 fd；本层在停止/替换分享、
// 创建失败、切换上传模式时统一 closeSync 关闭。
let shareFileHandles: Array<fs.File> = [];

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

export function getShareLink(): string {
  return shareLinkInfo;
}

export async function createShareLink(files: Array<SendFileItem>): Promise<void> {
  let appContext = getAppContext();
  if (appContext === undefined) {
    addLog('error', 'Share: AppService not initialized');
    return;
  }
  // fd-direct：为每个源文件打开读 fd 一并交给 Rust；本层持有 fs.File
  // 对象至分享结束（Rust 每次下载 dup 副本直读，原始 fd 由本层关闭）
  let nativeFiles: Array<NativeFileToSend> = [];
  let openedHandles: Array<fs.File> = [];
  // 替换场景：旧分享即将被覆盖，先关闭其持有的全部句柄
  closeShareFileHandles();
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
    for (let k = 0; k < openedHandles.length; k++) {
      try {
        fs.closeSync(openedHandles[k]);
      } catch (_ce) {
      }
    }
    addLog('error', 'Share: open source file failed: ' + e);
    notifyChange();
    return;
  }
  try {
    let result = await nativeCreateShareLink(nativeFiles, getDeviceAlias());
    // 分享创建成功：句柄移交模块数组长期持有（阻止 GC 关闭 fd）
    shareFileHandles = openedHandles;
    sharePort = result.port;
    // 使用 ArkTS 侧的本地 IP 构建 URL（比 Rust server_handle 的 IP 更可靠）
    let localIp = getLocalDeviceInfo().ip;
    let protocol = getHttpsEnabled() ? 'https' : 'http';
    shareLinkInfo = protocol + '://' + localIp + ':' + sharePort;
    addLog('info', 'Share link created: ' + shareLinkInfo);
  } catch (e) {
    // 链接创建失败：fd 所有权在本层，直接关闭本次打开的全部句柄
    // （无需触发 Rust 服务器清理重启）
    addLog('error', 'Share link failed: ' + e);
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
  logger.debug('[stopShareLink] called');
  try {
    await nativeStopShareServer();
  } catch (_e) {
  }
  // 服务器已停止（不再接受新请求）：关闭分享持有的全部源文件句柄
  closeShareFileHandles();
  shareLinkInfo = '';
  sharePort = 0;
  // 清理 Web 下载请求确认状态
  pendingWebDownloads = [];
  webDownloadSessionStates = {};
  // 服务器已由 Rust stop_share_server 以正常模式重启
  addLog('info', 'Share server stopped, server restored to normal mode');
  notifyChange();
}

/**
 * 启动 Web 上传模式：以启用上传的方式重启服务器，
 * 以便浏览器可通过 v2 协议向本设备上传文件。
 */
export async function startWebUpload(): Promise<void> {
  logger.debug('[startWebUpload] httpsEnabled=' + getHttpsEnabled().toString());
  try {
    let uploadPort: number = await nativeStartWebUpload();
    logger.debug('[startWebUpload] nativeStartWebUpload returned port=' + uploadPort);
    if (uploadPort <= 0) {
      addLog('error', 'Web upload start failed: invalid port ' + uploadPort);
      notifyChange();
      return;
    }
    // 分享模式 → 上传模式切换：服务器已重启为上传模式（不再接受分享下载），
    // 回收遗留的分享句柄
    closeShareFileHandles();
    sharePort = uploadPort;
    let localIp = getLocalDeviceInfo().ip;
    shareLinkInfo = (getHttpsEnabled() ? 'https' : 'http') + '://' + localIp + ':' + sharePort;
    logger.debug('[startWebUpload] shareLink=' + shareLinkInfo);
    addLog('info', 'Web upload started: ' + shareLinkInfo);
  } catch (e) {
    logger.error('[startWebUpload] FAILED: ' + String(e));
    addLog('error', 'Web upload start failed: ' + e);
  }
  notifyChange();
}

// ── Web 下载事件（由 handleNativeEvent 路由） ──

export function handlePrepareDownloadTyped(event: NativeWebSendPrepareDownloadEvent): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length === 0) {
    addLog('warn', 'WebPrepareDownload event with empty sessionId, ignoring');
    return;
  }
  let ip: string = event.ip;

  logger.debug('[webPrepareDownload] sessionId=' + shortSid(sessionId) + ' ip=' + ip);
  addLog('info', 'Web download request from ' + ip + ' (session=' + sessionId.substring(0, 8) + ')');

  // Web 下载自动接受遵循「自动确认下载请求」设置（而非自动确认请求三段式）
  let autoAcceptWebDownload: boolean = getAutoAcceptWebDownload();
  if (autoAcceptWebDownload) {
    addLog('info', 'Web download auto-accepted (autoAcceptWebDownload=true)');
    logger.debug('[webPrepareDownload] calling nativeAcceptWebDownload(sessionId=' + shortSid(sessionId) + ')');
    nativeAcceptWebDownload(sessionId);
    // 自动接受时也记录状态为 accepted
    webDownloadSessionStates[sessionId] = 'accepted';
  } else {
    addLog('info', 'Web download requires confirmation (autoAcceptWebDownload=false)');
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
    notifyChange();
  }
}

export function handleFileDownloadTyped(event: NativeWebSendFileDownloadEvent): void {
  if (event.sessionId.length > 0) {
    logger.debug('[webFileDownload] sessionId=' + shortSid(event.sessionId) + ' fileId=' + event.fileId + ' name=' +
      event.fileName + ' size=' + event.size);
    addLog('info', 'Web file download: ' + event.fileName + ' (' + event.size + ' bytes) session=' +
      event.sessionId.substring(0, 8));
    // 文件下载事件作为传输活跃信号，标记会话为 accepted
    let currentState: string | undefined = webDownloadSessionStates[event.sessionId];
    if (currentState === undefined || currentState === 'pending') {
      webDownloadSessionStates[event.sessionId] = 'accepted';
      notifyChange();
    }
  }
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
    addLog('warn', 'acceptWebDownloadRequest: session not found in pending list, sessionId=' + shortSid(sessionId));
    return;
  }
  // 调用 Rust 侧接受
  nativeAcceptWebDownload(sessionId);
  // 更新状态并从待确认队列移除
  webDownloadSessionStates[sessionId] = 'accepted';
  pendingWebDownloads.splice(idx, 1);
  addLog('info', 'Web download accepted: session=' + shortSid(sessionId));
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
    addLog('warn', 'declineWebDownloadRequest: session not found in pending list, sessionId=' + shortSid(sessionId));
    return;
  }
  // 调用 Rust 侧拒绝
  nativeDeclineWebDownload(sessionId);
  // 更新状态并从待确认队列移除
  webDownloadSessionStates[sessionId] = 'declined';
  pendingWebDownloads.splice(idx, 1);
  addLog('info', 'Web download declined: session=' + shortSid(sessionId));
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
    webDownloadSessionStates[sessionId] = 'declined';
    addLog('info', 'Web download declined (bulk): session=' + shortSid(sessionId));
  }
  pendingWebDownloads = [];
  notifyChange();
}

export function hasActiveWebDownloads(): boolean {
  // 遍历状态映射，检查是否有 accepted 状态的会话
  let keys: Array<string> = Object.keys(webDownloadSessionStates);
  for (let i = 0; i < keys.length; i++) {
    if (webDownloadSessionStates[keys[i]] === 'accepted') {
      return true;
    }
  }
  return false;
}
