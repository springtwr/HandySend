import { fileIo as fs } from '@kit.CoreFileKit';
import { SendFileItem, SendSessionStatus } from '../../model/Types';
import {
  nativeCreateCancelToken,
  nativeHashFileStreamFd
} from '../NativeBridge';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { isCreateChecksums } from './SettingsRepository';
import { updateSendSessionStatus, updateSendSessionHashProgress } from './SendRepository';
import { notifyChange } from './AppCore';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ChecksumRepository', '校验');

// ── 校验和状态 ──

let checksumProgress: number = 0;
let checksumTotal: number = 0;

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
      let hash = await nativeHashFileStreamFd(file.fd, token.id);
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
