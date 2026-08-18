import { hilog } from '@kit.PerformanceAnalysisKit';
import { SendFileItem } from '../../model/Types';
import { NativeFileToSend, NativeWebSendPrepare, NativeWebSendFileDownload } from '../../model/NativeTypes';
import { nativeCreateShareLink, nativeStopShareServer, nativeStartWebUpload,
  nativeAcceptWebDownload } from '../NativeBridge';
import { getAppContext, addLog, notifyChange, getLocalIp, shortSid } from './AppCore';
import { getHttpsEnabled, getSilentReceive } from './SettingsRepository';
import { getDeviceAlias } from './DeviceRepository';

const TAG = 'LocalSend:WebShareRepository';
const DOMAIN = 0x0001;

// ── Web share link state ──

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
    // Construct URL using local IP from ArkTS side (more reliable than Rust server_handle IP)
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
  hilog.info(DOMAIN, TAG, '[DBG-SHARE] stopShareLink called');
  try {
    await nativeStopShareServer();
  } catch (_e) {
  }
  shareLinkInfo = '';
  sharePort = 0;
  // Server has been restarted in normal mode by Rust stop_share_server
  addLog('info', 'Share server stopped, server restored to normal mode');
  notifyChange();
}

/**
 * Start web upload mode: restart server with upload enabled,
 * so browsers can upload files to this device via v2 protocol.
 */
export async function startWebUpload(): Promise<void> {
  hilog.info(DOMAIN, TAG, '[DBG-WEB-UP] startWebUpload: httpsEnabled=%{public}s', getHttpsEnabled().toString());
  try {
    let uploadPort: number = await nativeStartWebUpload();
    hilog.info(DOMAIN, TAG, '[DBG-WEB-UP]   nativeStartWebUpload returned port=%{public}d', uploadPort);
    if (uploadPort <= 0) {
      addLog('error', 'Web upload start failed: invalid port ' + uploadPort);
      notifyChange();
      return;
    }
    sharePort = uploadPort;
    let localIp = getLocalIp();
    shareLinkInfo = (getHttpsEnabled() ? 'https' : 'http') + '://' + localIp + ':' + sharePort;
    hilog.info(DOMAIN, TAG, '[DBG-WEB-UP]   shareLink=%{public}s', shareLinkInfo);
    addLog('info', 'Web upload started: ' + shareLinkInfo);
  } catch (e) {
    hilog.error(DOMAIN, TAG, '[DBG-WEB-UP]   FAILED: %{public}s', String(e));
    addLog('error', 'Web upload start failed: ' + e);
  }
  notifyChange();
}

// ── Web download events (routed from handleNativeEvent) ──

export function handlePrepareDownloadTyped(event: NativeWebSendPrepare): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length === 0) {
    addLog('warn', 'WebPrepareDownload event with empty sessionId, ignoring');
    return;
  }
  let ip: string = event.ip;

  hilog.info(DOMAIN, TAG, '[DBG-WEB-DL] web_prepare_download: sessionId=%{public}s ip=%{public}s',
    shortSid(sessionId), ip);
  addLog('info', 'Web download request from ' + ip + ' (session=' + sessionId.substring(0, 8) + ')');

  // Web download auto-accept follows silentReceive setting (not quickSaveMode)
  let silentReceive: boolean = getSilentReceive();
  if (silentReceive) {
    addLog('info', 'Web download auto-accepted (silentReceive=true)');
    hilog.info(DOMAIN, TAG, '[DBG-WEB-DL]   calling nativeAcceptWebDownload(sessionId=%{public}s)', shortSid(sessionId));
    nativeAcceptWebDownload(sessionId);
  } else {
    addLog('info', 'Web download requires confirmation (silentReceive=false)');
  }
}

export function handleFileDownloadTyped(event: NativeWebSendFileDownload): void {
  if (event.sessionId.length > 0) {
    hilog.info(DOMAIN, TAG, '[DBG-WEB-DL] web_file_download: sessionId=%{public}s fileId=%{public}s name=%{public}s size=%{public}d',
      shortSid(event.sessionId), event.fileId, event.fileName, event.size);
    addLog('info', 'Web file download: ' + event.fileName + ' (' + event.size + ' bytes) session=' + event.sessionId.substring(0, 8));
  }
}
