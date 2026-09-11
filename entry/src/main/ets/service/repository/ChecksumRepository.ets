import { fileIo as fs } from '@kit.CoreFileKit';
import { SendFileItem, DiscoveredDevice, SendSessionStatus } from '../../model/Types';
import {
  nativeCreateCancelToken,
  nativeHashFileStreamFd,
  nativeCancelHash,
  nativeFailFileDownload,
  nativeFailFileUpload,
  nativePrepareDownload,
  nativeDownloadFile,
  nativeUploadFromBuffer,
  nativeHashBuffer
} from '../NativeBridge';
import { getLogger } from '../../utils/Logger';
import { LogContext } from '../../common/LogFormat';
import { LogDomains } from '../../common/LogDomains';
import { isCreateChecksums } from './SettingsRepository';
import { updateSendSessionStatus, updateSendSessionHashProgress } from './SendRepository';
import { notifyChange } from './AppCore';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ChecksumRepository', '校验');

// ── 校验和状态 ──

let checksumProgress: number = 0;
let checksumTotal: number = 0;
let activeHashCancelId: string = '';

export function getChecksumProgress(): number {
  return checksumProgress;
}

export function getChecksumTotal(): number {
  return checksumTotal;
}

export async function calculateChecksumsForFiles(
  files: Array<SendFileItem>,
  sessionId?: string
): Promise<void> {
  if (!isCreateChecksums()) {
    return;
  }
  // 过滤出需要计算 hash 的文件（跳过已有 hash 的）
  let needHash: Array<number> = [];
  for (let i = 0; i < files.length; i++) {
    if (files[i].hash === undefined || files[i].hash!.length === 0) {
      needHash.push(i);
    }
  }
  if (needHash.length === 0) {
    return;
  }
  checksumTotal = files.length;
  checksumProgress = files.length - needHash.length;
  if (sessionId !== undefined && sessionId.length > 0) {
    updateSendSessionStatus(sessionId, SendSessionStatus.calculatingHash);
  }
  notifyChange();
  let hashedCount = checksumProgress;
  for (let idx = 0; idx < needHash.length; idx++) {
    let i = needHash[idx];
    let file: fs.File | undefined = undefined;
    try {
      // fd-direct：源文件为 picker URI/沙箱路径，先 openSync 拿到 fd 再交给 Rust 流式哈希
      // （fd 所有权移交 Rust，计算完成或取消后由 Rust 关闭，本层不 close）
      file = fs.openSync(files[i].filePath, fs.OpenMode.READ_ONLY);
      let token = nativeCreateCancelToken();
      activeHashCancelId = token.id;
      let hash = await nativeHashFileStreamFd(file.fd, token.id);
      activeHashCancelId = '';
      files[i].hash = hash;
      logger.debug('checksum[' + i + ']: path=' + files[i].filePath + ' sha256=' +
        (hash.length > 0 ? hash.substring(0, 16) + '...' : '(empty)'),
        { sessionId: sessionId, fileId: files[i].fileId });
      hashedCount = hashedCount + 1;
      checksumProgress = hashedCount;
      if (sessionId !== undefined && sessionId.length > 0) {
        updateSendSessionHashProgress(sessionId, hashedCount);
      }
      notifyChange();
    } catch (_e) {
      activeHashCancelId = '';
      files[i].hash = '';
      hashedCount = hashedCount + 1;
      checksumProgress = hashedCount;
      if (sessionId !== undefined && sessionId.length > 0) {
        updateSendSessionHashProgress(sessionId, hashedCount);
      }
      notifyChange();
    }
  }
  checksumTotal = 0;
  checksumProgress = 0;
  if (sessionId !== undefined && sessionId.length > 0) {
    updateSendSessionStatus(sessionId, SendSessionStatus.waiting);
  }
  notifyChange();
}

export function cancelChecksumCalculation(): void {
  if (activeHashCancelId.length > 0) {
    nativeCancelHash(activeHashCancelId);
    activeHashCancelId = '';
  }
}

export function reportFileDownloadFailure(sessionId: string, fileId: string): void {
  nativeFailFileDownload(sessionId, fileId);
}

export function reportFileUploadFailure(sessionId: string, fileId: string): void {
  nativeFailFileUpload(sessionId, fileId);
}

// ── Download API（反向文件传输） ──

interface DownloadSessionInfo {
  alias: string
  version: string
  deviceModel: string
  deviceType: string
  fingerprint: string
  download: boolean
  port: number
  protocol: string
  sessionId: string
  files: Record<string, Object>
}

export async function prepareDownloadFromDevice(
  device: DiscoveredDevice,
  sessionId?: string,
  pin?: string
): Promise<DownloadSessionInfo | undefined> {
  let protocol = device.protocol;
  try {
    let resultStr = await nativePrepareDownload(device.ip, device.port, protocol, sessionId, pin);
    let data: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
    let info: Record<string, Object> = {};
    if (data['info'] !== undefined && typeof data['info'] === 'object') {
      info = data['info'] as Record<string, Object>;
    }
    let filesObj: Record<string, Object> = {};
    if (data['files'] !== undefined && typeof data['files'] === 'object') {
      filesObj = data['files'] as Record<string, Object>;
    }
    return {
      alias: info['alias'] !== undefined ? info['alias'] as string : '',
      version: info['version'] !== undefined ? info['version'] as string : '',
      deviceModel: info['deviceModel'] !== undefined ? info['deviceModel'] as string : '',
      deviceType: info['deviceType'] !== undefined ? info['deviceType'] as string : 'desktop',
      fingerprint: info['fingerprint'] !== undefined ? info['fingerprint'] as string : '',
      download: info['download'] !== undefined ? info['download'] as boolean : false,
      port: info['port'] !== undefined ? info['port'] as number : device.port,
      protocol: info['protocol'] !== undefined ? info['protocol'] as string : protocol,
      sessionId: data['sessionId'] !== undefined ? data['sessionId'] as string : '',
      files: filesObj
    };
  } catch (e) {
    logger.error('Prepare download failed: ' + e);
    return undefined;
  }
}

export async function downloadFileFromDevice(
  device: DiscoveredDevice,
  sessionId: string,
  fileId: string,
  savePath: string
): Promise<boolean> {
  let protocol = device.protocol;
  if (protocol === 'http') {
    logger.warn('Downloading via unencrypted HTTP — data is not protected in transit');
  }
  try {
    await nativeDownloadFile(device.ip, device.port, protocol, sessionId, fileId, savePath, device.publicKey);
    logger.info('Downloaded file: ' + fileId + ' -> ' + savePath);
    return true;
  } catch (e) {
    logger.error('Download file failed: ' + e);
    return false;
  }
}

// ── 缓冲区上传 ──

export async function uploadBufferToDevice(
  targetIp: string,
  port: number,
  protocol: string,
  sessionId: string,
  fileId: string,
  token: string,
  buffer: ArrayBuffer,
  publicKey?: string,
  cancelId?: string
): Promise<boolean> {
  try {
    await nativeUploadFromBuffer(targetIp, port, protocol, sessionId, fileId, token, buffer, publicKey, cancelId);
    logger.info('Buffer uploaded: ' + fileId);
    return true;
  } catch (e) {
    logger.error('Buffer upload failed: ' + e);
    return false;
  }
}

// ── 内存哈希 ──

export function hashBufferSync(buffer: ArrayBuffer): string {
  return nativeHashBuffer(buffer);
}
