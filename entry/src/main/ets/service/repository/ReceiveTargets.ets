// 接收直写目标（fd-direct）管理：接收文件在确认接收时预创建并注册 fd，
// Rust 网络流直接写入最终位置。
// 本模块持有 Download/<包名>/ 目录缓存与会话目标路径登记表，
// 会话状态（sessionFileMap/sessionFilePaths 等）仍归 ReceiveRepository 所有。

import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import {
  nativeSanitizeFileName, nativeRegisterRecvFileFd, nativeDiscardRecvFileFds
} from '../NativeBridge';
import { getAppContext } from './AppCore';
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

// 「接收文本」目录：接收文本消息的落盘目录，位于应用私有持久目录（filesDir/text_recv/）下，
// 与发送文本目录（filesDir/text_send/）分目录存放、清理判据共用同一前缀集合。
// 文本落沙箱后文件名仅为内部实现细节，UI 不再向用户展示。应用上下文缺失时返回空串，由调用方拒绝会话。
export function recvTextDir(): string {
  let appContext = getAppContext();
  if (appContext === undefined) {
    return '';
  }
  return appContext.filesDir + '/text_recv/';
}

// 文本消息条目判定（与 ReceiveRepository 的摄入判据同源）：text/plain + 携带文本内容信息。
// 文件选择器选取的 .txt 文件不带 preview，不在此列。
function isRecvTextEntry(entry: ReceivedFileEntry): boolean {
  return entry.fileType === 'text/plain' &&
    entry.preview !== undefined && entry.preview.length > 0;
}

// 会话已预注册的直写目标文件路径：sessionId → (fileId → 最终路径)。
// 用于会话取消/失败时清理不完整的文件（Download 与接收文本目录均在此登记）；
// 成功会话的文件即交付物、不清除。
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
      logger.warn('获取接收目录失败：结果为空');
      return false;
    }
    recvDirUriCache = uris[0];
    recvDirPathCache = new fileUri.FileUri(uris[0]).path;
    return true;
  } catch (e) {
    logger.error('获取接收目录失败：' + e);
    return false;
  }
}

/**
 * 确保 Download/<包名>/ 目录可用并返回其路径（归一化去尾斜杠）；不可得返回空串。
 * 进程内缓存复用，供落盘前的存储预留检查使用。
 */
export async function ensureRecvDownloadDir(): Promise<string> {
  if (!(await ensureReceiveDir())) {
    return '';
  }
  let dirPath: string = recvDirPathCache;
  // 归一化：去掉尾部斜杠，便于与 '/' + 文件名拼接
  if (dirPath.endsWith('/')) {
    dirPath = dirPath.substring(0, dirPath.length - 1);
  }
  return dirPath;
}

/** 确保接收文本目录存在并返回其路径；应用上下文缺失时返回空串。 */
function ensureRecvTextDir(): string {
  let dir: string = recvTextDir();
  if (dir.length === 0) {
    return '';
  }
  try {
    if (!fs.accessSync(dir, fs.AccessModeType.EXIST)) {
      fs.mkdirSync(dir, true);
    }
  } catch (_e) {
    return '';
  }
  // recvTextDir 恒带尾斜杠，去掉后与 Download 路径口径一致
  if (dir.endsWith('/')) {
    dir = dir.substring(0, dir.length - 1);
  }
  return dir;
}

/** 按 fileId 在条目表中定位下标；未命中返回 -1。 */
function findEntryIndex(entries: Array<ReceivedFileEntry>, fileId: string): number {
  for (let j = 0; j < entries.length; j++) {
    if (entries[j].fileId === fileId) {
      return j;
    }
  }
  return -1;
}

/** 本次待接收集合中是否含普通文件条目（需 Download 目录）。 */
function needsDownloadDir(entries: Array<ReceivedFileEntry>, fileIds: Array<string>): boolean {
  for (let i = 0; i < fileIds.length; i++) {
    let idx: number = findEntryIndex(entries, fileIds[i]);
    if (idx >= 0 && !isRecvTextEntry(entries[idx])) {
      return true;
    }
  }
  return false;
}

/** 本次待接收集合中是否含文本消息条目（需接收文本目录）。 */
function needsTextDir(entries: Array<ReceivedFileEntry>, fileIds: Array<string>): boolean {
  for (let i = 0; i < fileIds.length; i++) {
    let idx: number = findEntryIndex(entries, fileIds[i]);
    if (idx >= 0 && isRecvTextEntry(entries[idx])) {
      return true;
    }
  }
  return false;
}

// 预注册某会话待接收文件的直写目标：净化/去重文件名 → 创建文件 → open 写 fd →
// registerRecvFileFd；同时把最终路径回写到传入的条目（filePath/fileName，
// 供历史/相册/文本使用）并返回 fileId → 最终路径映射。
// 文本消息条目落应用私有接收文本目录（filesDir/text_recv/），普通文件落 Download/<包名>/，
// 重名规则一致（自动加序号、不覆盖）。
// 任一文件准备失败 → 回滚已建文件并关闭已注册 fd，返回 undefined（调用方拒绝会话）。
export async function prepareRecvTargets(sessionId: string, fileIds: Array<string>,
  entries: Array<ReceivedFileEntry> | undefined): Promise<Record<string, string> | undefined> {
  if (entries === undefined || entries.length === 0 || fileIds.length === 0) {
    return undefined;
  }
  // 按条目是否文本消息决定目标目录：文本目录为应用沙箱（mkdir 直建），
  // 普通文件目录经 DocumentViewPicker 惰性获取；任一所需目录不可得即整体拒绝
  let needDownload: boolean = needsDownloadDir(entries, fileIds);
  let needText: boolean = needsTextDir(entries, fileIds);
  let downloadDir: string = needDownload ? await ensureRecvDownloadDir() : '';
  let textDir: string = needText ? ensureRecvTextDir() : '';
  if (needDownload && downloadDir.length === 0) {
    return undefined;
  }
  if (needText && textDir.length === 0) {
    return undefined;
  }
  let perFile: Record<string, string> = {};
  let allOk: boolean = true;
  for (let i = 0; i < fileIds.length; i++) {
    let fileId: string = fileIds[i];
    let entryIdx: number = findEntryIndex(entries, fileId);
    if (entryIdx < 0) {
      allOk = false;
      continue;
    }
    let entry: ReceivedFileEntry = entries[entryIdx];
    // 文本消息条目落接收文本目录（沙箱），其余落 Download 目录
    let dirPath: string = isRecvTextEntry(entry) ? textDir : downloadDir;
    let destPath: string = '';
    let opened: fs.File | undefined = undefined;
    try {
      let name: string = nativeSanitizeFileName(entry.fileName);
      if (name.length === 0) {
        name = 'file_' + Date.now();
      }
      let uniqueName: string = uniquePath(dirPath, name);
      destPath = dirPath + '/' + uniqueName;
      opened = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      nativeRegisterRecvFileFd(sessionId, fileId, opened.fd, destPath);
      perFile[fileId] = destPath;
      // 回写最终路径：历史记录/相册保存/文本读取均以登记路径为准
      entry.filePath = destPath;
      entry.fileName = uniqueName;
      // 注册成功后文件句柄所有权移交原生侧，本层不再关闭
      opened = undefined;
    } catch (e) {
      allOk = false;
      // 注册失败时已打开的文件句柄仍归本层所有，需主动关闭并删除半成品文件
      if (opened !== undefined) {
        try {
          fs.closeSync(opened);
        } catch (_closeErr) {
        }
        opened = undefined;
      }
      if (destPath.length > 0) {
        try {
          fs.unlinkSync(destPath);
        } catch (_unlinkErr) {
        }
      }
      logger.error('准备接收目标失败 fileId=' + fileId + '：' + e);
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
