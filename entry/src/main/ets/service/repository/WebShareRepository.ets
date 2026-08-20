import { getLogger, LogContext } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { SendFileItem } from '../../model/Types';
import { NativeFileToSend, NativeWebSendPrepare, NativeWebSendFileDownload } from '../../model/NativeTypes';
import { nativeCreateShareLink, nativeStopShareServer, nativeStartWebUpload,
  nativeAcceptWebDownload } from '../NativeBridge';
import { getAppContext, addLog, notifyChange, getLocalIp, shortSid } from './AppCore';
import { getHttpsEnabled, getSilentReceive } from './SettingsRepository';
import { getDeviceAlias } from './DeviceRepository';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:WebShareRepository');

// ── Web 分享链接状态 ──

let shareLinkInfo: string = '';
let sharePort: number = 0;

export function getShareLink(): string {
  return shareLinkInfo;
}

export function getSharePort(): number {
  return sharePort;
}

export async function createShareLink(files: Array<SendFileItem>): Promise<void> {
  let appContext = getAppContext();
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
      size: f.size,
      preview: f.preview,
      sha256: f.hash
    });
  }
  try {
    let result = await nativeCreateShareLink(nativeFiles, getDeviceAlias());
    sharePort = result.port;
    // 使用 ArkTS 侧的本地 IP 构建 URL（比 Rust server_handle 的 IP 更可靠）
    let localIp = getLocalIp();
    let protocol = getHttpsEnabled() ? 'https' : 'http';
    shareLinkInfo = protocol + '://' + localIp + ':' + sharePort;
    addLog('info', 'Share link created: ' + shareLinkInfo);
  } catch (e) {
    addLog('error', 'Share link failed: ' + e);
  }
  notifyChange();
}

export async function stopShareLink(): Promise<void> {
  logger.info('[stopShareLink] called');
  try {
    await nativeStopShareServer();
  } catch (_e) {
  }
  shareLinkInfo = '';
  sharePort = 0;
  // 服务器已由 Rust stop_share_server 以正常模式重启
  addLog('info', 'Share server stopped, server restored to normal mode');
  notifyChange();
}

/**
 * 启动 Web 上传模式：以启用上传的方式重启服务器，
 * 以便浏览器可通过 v2 协议向本设备上传文件。
 */
export async function startWebUpload(): Promise<void> {
  logger.info('[startWebUpload] httpsEnabled=' + getHttpsEnabled().toString());
  try {
    let uploadPort: number = await nativeStartWebUpload();
    logger.info('[startWebUpload] nativeStartWebUpload returned port=' + uploadPort);
    if (uploadPort <= 0) {
      addLog('error', 'Web upload start failed: invalid port ' + uploadPort);
      notifyChange();
      return;
    }
    sharePort = uploadPort;
    let localIp = getLocalIp();
    shareLinkInfo = (getHttpsEnabled() ? 'https' : 'http') + '://' + localIp + ':' + sharePort;
    logger.info('[startWebUpload] shareLink=' + shareLinkInfo);
    addLog('info', 'Web upload started: ' + shareLinkInfo);
  } catch (e) {
    logger.error('[startWebUpload] FAILED: ' + String(e));
    addLog('error', 'Web upload start failed: ' + e);
  }
  notifyChange();
}

// ── Web 下载事件（由 handleNativeEvent 路由） ──

export function handlePrepareDownloadTyped(event: NativeWebSendPrepare): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length === 0) {
    addLog('warn', 'WebPrepareDownload event with empty sessionId, ignoring');
    return;
  }
  let ip: string = event.ip;

  logger.info('[webPrepareDownload] sessionId=' + shortSid(sessionId) + ' ip=' + ip);
  addLog('info', 'Web download request from ' + ip + ' (session=' + sessionId.substring(0, 8) + ')');

  // Web 下载自动接受遵循静默接收设置（而非 quickSaveMode）
  let silentReceive: boolean = getSilentReceive();
  if (silentReceive) {
    addLog('info', 'Web download auto-accepted (silentReceive=true)');
    logger.info('[webPrepareDownload] calling nativeAcceptWebDownload(sessionId=' + shortSid(sessionId) + ')');
    nativeAcceptWebDownload(sessionId);
  } else {
    addLog('info', 'Web download requires confirmation (silentReceive=false)');
  }
}

export function handleFileDownloadTyped(event: NativeWebSendFileDownload): void {
  if (event.sessionId.length > 0) {
    logger.info('[webFileDownload] sessionId=' + shortSid(event.sessionId) + ' fileId=' + event.fileId + ' name=' + event.fileName + ' size=' + event.size);
    addLog('info', 'Web file download: ' + event.fileName + ' (' + event.size + ' bytes) session=' + event.sessionId.substring(0, 8));
  }
}
