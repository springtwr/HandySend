// 接收直写目标（fd-direct）管理：接收文件在确认接收时预创建并注册 fd，
// Rust 网络流直接写入最终位置。
// 本模块持有 Download/<包名>/ 目录缓存与会话目标路径登记表，
// 会话状态（sessionFileMap/sessionFilePaths 等）仍归 ReceiveRepository 所有。

import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import {
  nativeSanitizeFileName, nativeRegisterRecvFileFd, nativeDiscardRecvFileFds
} from '../NativeBridge';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ReceiveTargets', '接收目标');

// 会话内单个待接收文件的登记条目（sessionFileMap 的元素类型）
export interface ReceivedFileEntry {
  sessionId: string
  fileId: string
  filePath: string
  fileName: string
  fileType: string
  preview?: string
}

// Download/<包名>/ 目录的持久化授权 URI 与路径（应用运行期惰性缓存；
// 会话目标准备时经 DocumentViewPicker.save(DOWNLOAD) 获取，一次获取多次复用）
let recvDirUriCache: string = '';
let recvDirPathCache: string = '';

// 会话已预注册的直写目标文件路径：sessionId → (fileId → 最终路径)。
// 用于会话取消/失败时清理 Download 中不完整的文件；成功会话的文件即交付物、不清除。
let recvTargetPaths: Map<string, Record<string, string>> = new Map<string, Record<string, string>>();

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
export function uniquePath(dir: string, fileName: string): string {
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
// registerRecvFileFd；同时把最终路径回写到传入的条目（filePath/fileName，
// 供历史/相册/文本使用）并返回 fileId → 最终路径映射。
// 文本与普通文件一律落 Download/<包名>/。
// 任一文件准备失败 → 回滚已建文件并关闭已注册 fd，返回 undefined（调用方拒绝会话，不回退沙箱）。
export async function prepareRecvTargets(sessionId: string, fileIds: Array<string>,
  entries: Array<ReceivedFileEntry> | undefined): Promise<Record<string, string> | undefined> {
  if (entries === undefined || entries.length === 0 || fileIds.length === 0) {
    return undefined;
  }
  // 文本与普通文件使用同一目标目录与重名规则（文本即文件）：文本不再落 cache 临时目录，
  // 而是与普通接收文件一样落 Download/<包名>/ 持久目录，重名自动加序号、不覆盖
  let dirPath: string = '';
  if (!(await ensureReceiveDir())) {
    return undefined;
  }
  dirPath = recvDirPathCache;
  // 归一化：去掉尾部斜杠，便于与 '/' + 文件名拼接（getReceiveCacheDir 返回值带尾斜杠）
  if (dirPath.endsWith('/')) {
    dirPath = dirPath.substring(0, dirPath.length - 1);
  }
  if (dirPath.length === 0) {
    return undefined;
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
    return undefined;
  }
  recvTargetPaths.set(sessionId, perFile);
  return perFile;
}

// 删除某会话预创建的目标文件（会话取消/失败时调用；成功会话的文件即交付物不删除）。
export function removeRecvTargetFiles(sessionId: string): void {
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

// 仅清空某会话的登记表（成功会话收尾调用：目标文件即交付物不删除，只回收登记表内存）。
export function clearRecvTargets(sessionId: string): void {
  recvTargetPaths.delete(sessionId);
}
