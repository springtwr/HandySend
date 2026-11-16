// 接收目标管理：接收文件在确认接收时于目标目录的临时区预创建空文件，
// 以路径目标模式注册最终路径（fd = -1）；Rust 在上传到达时用 O_NOFOLLOW
// 打开临时文件，写入完成后原子改名到最终位置。
// 本模块持有会话目标路径/新建目录登记表；接收目录统一由 ReceiveDirectory 提供，
// 会话状态（sessionFileMap/sessionFilePaths 等）仍归 ReceiveRepository 所有。

import { fileIo as fs } from '@kit.CoreFileKit';
import { ensureReceiveDirectory } from './ReceiveDirectory';
import {
  dirNameOf,
  LEGACY_TEMP_DIR_NAMES,
  LEGACY_TEMP_SUBDIRS,
  TEMP_DIR_NAME,
  TEMP_SUBDIR_LOCAL_SEND,
  TEMP_SUBDIRS,
  tempPathForFinal
} from '../../model/transfer/TransferTempPaths';
import {
  nativeSanitizeFileName, nativeRegisterRecvFileFd, nativeDiscardRecvFileFds
} from '../NativeBridge';
import {
  ParsedRelativePath,
  ReceivedPathError,
  ReceivedPathParseResult,
  parseReceivedPath,
  sanitizeReceivedPath
} from '../../model/transfer/ReceivedPath';
import { getAppContext } from './AppCore';
import { MAX_BATCH_FILES } from '../../model/TransferLimits';
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

// 与最终路径对应的临时路径：sessionId → (fileId → 临时路径)。
// 未完成字节只写临时区；成功提交后临时文件已改名，最终路径不在此清理。
let recvTargetTempPaths: Map<string, Record<string, string>> = new Map<string, Record<string, string>>();

/**
 * 删除空目录；非空目录保留。
 * 注意：OHOS `fs.rmdirSync` 会递归删除目录及全部内容，不能直接用于“尝试移除空目录”，
 * 否则会误删同目录其他会话/协议的临时文件。
 */
export function removeDirectoryIfEmpty(path: string): void {
  try {
    if (!fs.accessSync(path)) {
      return;
    }
    if (fs.listFileSync(path).length > 0) {
      return;
    }
    fs.rmdirSync(path);
  } catch (_e) {
  }
}

function fileExistsAtPath(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (e) {
    // 任何异常（如权限被拒 13900012）均视为不存在（保守策略：不覆盖）
    return false;
  }
}

/**
 * 目标目录中该文件名是否已被临时文件占用。
 * 接收临时区按协议分子目录；临时文件存在即代表对应最终文件名已被预留，
 * 避免并发的同名接收在传输完成前选中同一最终路径。
 */
function tempNameReserved(dir: string, fileName: string): boolean {
  for (let i = 0; i < TEMP_SUBDIRS.length; i++) {
    let candidate: string = dir + '/' + TEMP_DIR_NAME + '/' + TEMP_SUBDIRS[i] + '/' + fileName;
    if (fileExistsAtPath(candidate)) {
      return true;
    }
  }
  // 旧版协议子目录中的残留同样视为占用，避免覆盖尚未清理的半成品
  for (let i = 0; i < LEGACY_TEMP_SUBDIRS.length; i++) {
    let candidate: string = dir + '/' + TEMP_DIR_NAME + '/' + LEGACY_TEMP_SUBDIRS[i] + '/' + fileName;
    if (fileExistsAtPath(candidate)) {
      return true;
    }
  }
  // 旧版临时目录中的残留同样视为占用，避免覆盖尚未清理的半成品
  for (let i = 0; i < LEGACY_TEMP_DIR_NAMES.length; i++) {
    let candidate: string = dir + '/' + LEGACY_TEMP_DIR_NAMES[i] + '/' + fileName;
    if (fileExistsAtPath(candidate)) {
      return true;
    }
  }
  return false;
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
  if (!fileExistsAtPath(candidatePath) && !tempNameReserved(dir, fileName)) {
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
  while (fileExistsAtPath(candidatePath) || tempNameReserved(dir, renamed)) {
    n++;
    renamed = stem + ' (' + n + ')' + ext;
    candidatePath = dir + '/' + renamed;
  }
  return renamed;
}

/**
 * 返回不冲突的目录名：目标位置已有同名文件/目录，或其他协议已在临时区预留同名文件时，
 * 在完整名称后追加 " (N)"。目录名不拆分扩展名（点号属于目录名本身）；
 * isReserved 供调用方避开本批次已占用的路径。
 * 接收文件夹时根目录整体改名，避免新内容与已有同名文件夹混在一起。
 */
export function uniqueDirectoryName(dir: string, name: string,
  isReserved: (path: string) => boolean): string {
  let candidate: string = name;
  let n: number = 1;
  while (fileExistsAtPath(dir + '/' + candidate) || tempNameReserved(dir, candidate) ||
    isReserved(dir + '/' + candidate)) {
    candidate = name + ' (' + n + ')';
    n++;
  }
  return candidate;
}

/** 确保接收文本目录存在并返回其路径；应用上下文缺失时返回空串。 */
export function ensureRecvTextDir(): string {
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

/** 本次待接收集合中是否含普通文件条目（需接收目录）。 */
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

// 同一批内同名文件（来自不同目录）各自落盘：在 uniquePath 的基础上再避开本批
// 已占用的路径与已规划的目录，避免两遍式准备中临时文件尚未创建时选中同一最终路径，
// 或与同批次新建的目录（含根目录改名后的路径）重名。
function uniqueBatchPath(dir: string, fileName: string,
  reserved: Record<string, boolean>, plannedDirs: Record<string, boolean>): string {
  let candidate: string = uniquePath(dir, fileName);
  let serial: number = 1;
  while (reserved[dir + '/' + candidate] === true || plannedDirs[dir + '/' + candidate] === true) {
    let dot: number = fileName.lastIndexOf('.');
    let stem: string = dot > 0 ? fileName.substring(0, dot) : fileName;
    let ext: string = dot > 0 ? fileName.substring(dot) : '';
    candidate = uniquePath(dir, stem + ' (' + serial + ')' + ext);
    serial++;
  }
  return candidate;
}

/** 单次 LocalSend 接收的文件数硬上限：与发送共用同一批量上限。 */
export const MAX_RECV_FILES: number = MAX_BATCH_FILES;

/** 接收目标准备失败原因（供调用方映射本地化文案）。 */
export enum RecvPrepareError {
  none = 'none',
  empty = 'empty',
  tooMany = 'tooMany',
  invalidPath = 'invalidPath',
  reservedName = 'reservedName',
  io = 'io'
}

/** 目标准备结果：paths 为空时 error 给出原因。 */
export class RecvPrepareOutcome {
  paths: Record<string, string> | undefined = undefined
  error: RecvPrepareError = RecvPrepareError.none

  constructor(paths: Record<string, string> | undefined, error: RecvPrepareError) {
    this.paths = paths;
    this.error = error;
  }
}

// 会话 → 本次新建的最终目录（取消/失败时只删除空的、本次新建的目录，
// 不碰用户原有目录，也不删除已有文件的目录）。
let recvTargetCreatedDirs: Map<string, Array<string>> = new Map<string, Array<string>>();

/** 路径解析错误 → 接收准备错误。 */
function mapReceivedPathError(error: ReceivedPathError): RecvPrepareError {
  return error === ReceivedPathError.reserved ? RecvPrepareError.reservedName :
    RecvPrepareError.invalidPath;
}

/** 逐级创建相对目录；只记录本次新建的目录，供回滚时移除空目录。 */
function ensureRelativeDirs(baseDir: string, dirs: Array<string>,
  created: Array<string>): string {
  let current: string = baseDir;
  for (let i = 0; i < dirs.length; i++) {
    let next: string = current + '/' + dirs[i];
    if (!fs.accessSync(next)) {
      fs.mkdirSync(next);
      created.push(next);
    }
    current = next;
  }
  return current;
}

/** 自底向上移除空的新建目录（非空目录保留）。 */
function removeCreatedDirs(created: Array<string>): void {
  for (let i = created.length - 1; i >= 0; i--) {
    removeDirectoryIfEmpty(created[i]);
  }
}

/** 让出主线程：大批量目标创建时避免卡住 UI/事件处理。 */
async function yieldToUi(): Promise<void> {
  await new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, 0);
  });
}

interface RecvTargetPlan {
  fileId: string
  destPath: string
  tempPath: string
  baseDir: string
  dirs: Array<string>
}

// 预注册某会话待接收文件的落盘目标：解析/净化相对路径 → 根目录同名整体改名 →
// 每个目录内唯一命名 → 先把路径写回条目并由调用方落草稿 → 创建最终目录与空临时文件
// → 注册路径目标。
//
// 路径目标模式：临时文件创建后立即关闭，不保留 fd；Rust 在对应文件上传到达时
// 用 O_NOFOLLOW 打开临时路径，拿到 fd 后仍走 FileUploadTarget::Fd。
// 文本消息条目落应用私有接收文本目录（filesDir/text_recv/），普通文件落用户设置的
// 接收目录（默认 Download/<包名>/）；任一文件准备失败 → 回滚并返回错误原因。
export async function prepareRecvTargets(sessionId: string, fileIds: Array<string>,
  entries: Array<ReceivedFileEntry> | undefined,
  beforeCreate?: () => void): Promise<RecvPrepareOutcome> {
  if (entries === undefined || entries.length === 0 || fileIds.length === 0) {
    return new RecvPrepareOutcome(undefined, RecvPrepareError.empty);
  }
  if (fileIds.length > MAX_RECV_FILES) {
    return new RecvPrepareOutcome(undefined, RecvPrepareError.tooMany);
  }
  // 按条目是否文本消息决定目标目录：文本目录为应用沙箱（mkdir 直建），
  // 普通文件目录由 ReceiveDirectory 统一解析；任一所需目录不可得即整体拒绝
  let needDownload: boolean = needsDownloadDir(entries, fileIds);
  let needText: boolean = needsTextDir(entries, fileIds);
  let downloadDir: string = needDownload ? await ensureReceiveDirectory() : '';
  let textDir: string = needText ? ensureRecvTextDir() : '';
  if (needDownload && downloadDir.length === 0) {
    return new RecvPrepareOutcome(undefined, RecvPrepareError.io);
  }
  if (needText && textDir.length === 0) {
    return new RecvPrepareOutcome(undefined, RecvPrepareError.io);
  }
  let plans: Array<RecvTargetPlan> = [];
  let perFile: Record<string, string> = {};
  let reserved: Record<string, boolean> = {};
  let plannedDirs: Record<string, boolean> = {};
  let plannedFinals: Record<string, boolean> = {};
  // 本批次根目录映射：<目标基目录>/<原始根名> → 实际根名。
  // 目标中已有同名文件/目录时整体改名（如 Photos → Photos (1)），避免把新文件夹的
  // 内容并入已有目录；同批次同根名的条目共用同一映射，不逐个文件改名。
  let rootDirs: Record<string, string> = {};
  let reservedRootDirs: Record<string, boolean> = {};
  // 第一遍：只计算路径，不创建目录/临时文件；先把路径写回条目，
  // 使调用方能在任何字节写入前把最终/临时路径落进草稿。
  for (let i = 0; i < fileIds.length; i++) {
    let fileId: string = fileIds[i];
    let entryIdx: number = findEntryIndex(entries, fileId);
    if (entryIdx < 0) {
      return new RecvPrepareOutcome(undefined, RecvPrepareError.invalidPath);
    }
    let entry: ReceivedFileEntry = entries[entryIdx];
    let parsed: ReceivedPathParseResult = parseReceivedPath(entry.fileName);
    if (parsed.path === undefined) {
      return new RecvPrepareOutcome(undefined, mapReceivedPathError(parsed.error));
    }
    let sanitized: ReceivedPathParseResult =
      sanitizeReceivedPath(parsed.path, (name: string): string => nativeSanitizeFileName(name));
    if (sanitized.path === undefined) {
      return new RecvPrepareOutcome(undefined, mapReceivedPathError(sanitized.error));
    }
    let relative: ParsedRelativePath = sanitized.path;
    let baseDir: string = isRecvTextEntry(entry) ? textDir : downloadDir;
    // 根目录整体消歧：目标中已有同名文件/目录时整体改名，避免两个文件夹的内容混在一起。
    let dirs: Array<string> = relative.dirs.slice();
    if (dirs.length > 0) {
      let rootKey: string = baseDir + '/' + dirs[0];
      let mappedRoot: string | undefined = rootDirs[rootKey];
      if (mappedRoot === undefined) {
        mappedRoot = uniqueDirectoryName(baseDir, dirs[0], (path: string): boolean => {
          return reservedRootDirs[path] === true || plannedFinals[path] === true;
        });
        rootDirs[rootKey] = mappedRoot;
        reservedRootDirs[baseDir + '/' + mappedRoot] = true;
      }
      dirs[0] = mappedRoot;
    }
    // 逐级登记目录，并检测“某个最终文件恰好是另一个文件的目录”这种恶意/异常构造。
    let dirPath: string = baseDir;
    for (let d = 0; d < dirs.length; d++) {
      dirPath = dirPath + '/' + dirs[d];
      if (plannedFinals[dirPath] === true) {
        return new RecvPrepareOutcome(undefined, RecvPrepareError.invalidPath);
      }
      plannedDirs[dirPath] = true;
    }
    let uniqueName: string = uniqueBatchPath(dirPath, relative.name, reserved, plannedDirs);
    let destPath: string = dirPath + '/' + uniqueName;
    let nameParts: Array<string> = dirs.slice();
    nameParts.push(uniqueName);
    let relativeName: string = nameParts.join('/');
    plans.push({
      fileId: fileId,
      destPath: destPath,
      tempPath: tempPathForFinal(destPath, TEMP_SUBDIR_LOCAL_SEND),
      baseDir: baseDir,
      dirs: dirs
    });
    reserved[destPath] = true;
    plannedFinals[destPath] = true;
    // 回写最终路径/相对名：历史、相册、详情名称均以此为准
    entry.filePath = destPath;
    entry.fileName = relativeName;
    perFile[fileId] = destPath;
    if (i % 100 === 99) {
      await yieldToUi();
    }
  }
  // 路径确定、目录/临时文件尚未创建：调用方在此落草稿，强杀后仍可按草稿清理。
  if (beforeCreate !== undefined) {
    beforeCreate();
  }
  // 第二遍：创建最终目录 + 空临时文件，并注册路径目标（不保留 fd）。
  let createdDirs: Array<string> = [];
  let perTempFile: Record<string, string> = {};
  let allOk: boolean = true;
  for (let i = 0; i < plans.length; i++) {
    let plan: RecvTargetPlan = plans[i];
    let tempFile: fs.File | undefined = undefined;
    try {
      ensureRelativeDirs(plan.baseDir, plan.dirs, createdDirs);
      let tempDir: string = dirNameOf(plan.tempPath);
      if (tempDir.length > 0 && !fs.accessSync(tempDir)) {
        fs.mkdirSync(tempDir, true);
      }
      // 预创建空临时文件：保留“临时文件存在即预留名字”的语义，并让 Rust
      // 上传时可以直接按路径打开；创建后立即关闭，不占用 fd。
      tempFile = fs.openSync(plan.tempPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE |
        fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW);
      fs.closeSync(tempFile);
      tempFile = undefined;
      nativeRegisterRecvFileFd(sessionId, plan.fileId, -1, plan.destPath);
      perTempFile[plan.fileId] = plan.tempPath;
    } catch (e) {
      allOk = false;
      if (tempFile !== undefined) {
        try {
          fs.closeSync(tempFile);
        } catch (_closeErr) {
        }
        tempFile = undefined;
      }
      try {
        fs.unlinkSync(plan.tempPath);
      } catch (_unlinkErr) {
      }
      // 回滚后尝试移除已空的协议子目录与临时区根目录
      let tempDir: string = dirNameOf(plan.tempPath);
      removeDirectoryIfEmpty(tempDir);
      let tempRoot: string = dirNameOf(tempDir);
      if (tempRoot.length > 0) {
        removeDirectoryIfEmpty(tempRoot);
      }
      logger.warn('准备接收目标失败 fileId=' + plan.fileId + '：' + e);
      break;
    }
    if (i % 50 === 49) {
      await yieldToUi();
    }
  }
  if (!allOk) {
    // 回滚：丢弃已注册路径 + 删除已创建的临时半成品 + 移除本次新建的空目录
    nativeDiscardRecvFileFds(sessionId);
    let keys: Array<string> = Object.keys(perTempFile);
    for (let k = 0; k < keys.length; k++) {
      try {
        fs.unlinkSync(perTempFile[keys[k]]);
      } catch (_e) {
      }
      let tempDir: string = dirNameOf(perTempFile[keys[k]]);
      removeDirectoryIfEmpty(tempDir);
      let tempRoot: string = dirNameOf(tempDir);
      if (tempRoot.length > 0) {
        removeDirectoryIfEmpty(tempRoot);
      }
    }
    removeCreatedDirs(createdDirs);
    return new RecvPrepareOutcome(undefined, RecvPrepareError.io);
  }
  recvTargetTempPaths.set(sessionId, perTempFile);
  recvTargetCreatedDirs.set(sessionId, createdDirs);
  return new RecvPrepareOutcome(perFile, RecvPrepareError.none);
}

// 删除某会话预创建的临时文件（会话取消/失败时调用；成功会话的文件即交付物不删除）。
// 列于 keepFileIds 的文件已完成写入并改名到最终路径，临时文件已不存在；
// 未提供时删除全部登记临时文件（拒绝/超时等尚未产生完成文件的路径）。
// 只操作临时区，避免把最终路径上的部分交付物误删。
export function removeRecvTargetFiles(sessionId: string, keepFileIds?: Record<string, boolean>): void {
  let perTempFile: Record<string, string> | undefined = recvTargetTempPaths.get(sessionId);
  if (perTempFile !== undefined) {
    removeRecvTargetPaths(perTempFile, keepFileIds);
    recvTargetTempPaths.delete(sessionId);
  }
  // 取消/失败：本次新建且已空的最终目录一并移除；已完成文件所在的非空目录保留
  let created: Array<string> | undefined = recvTargetCreatedDirs.get(sessionId);
  if (created !== undefined) {
    removeCreatedDirs(created);
    recvTargetCreatedDirs.delete(sessionId);
  }
}

/**
 * 按临时路径登记表删除未完成文件，并尝试移除空的协议子目录与临时区根目录。
 * 只操作临时区，不触碰最终路径；keepFileIds 中的文件已完成提交，保留登记路径。
 * 单独导出以便设备端用例直接覆盖清理策略（登记表由 prepareRecvTargets 维护）。
 */
export function removeRecvTargetPaths(perTempFile: Record<string, string>,
  keepFileIds?: Record<string, boolean>): void {
  let keys: Array<string> = Object.keys(perTempFile);
  let tempDirs: Record<string, boolean> = {};
  for (let k = 0; k < keys.length; k++) {
    tempDirs[dirNameOf(perTempFile[keys[k]])] = true;
    if (keepFileIds !== undefined && keepFileIds[keys[k]] === true) {
      continue;
    }
    try {
      fs.unlinkSync(perTempFile[keys[k]]);
    } catch (_e) {
      // 文件可能已被提交改名或不存在——忽略
    }
  }
  let dirKeys: Array<string> = Object.keys(tempDirs);
  for (let k = 0; k < dirKeys.length; k++) {
    removeDirectoryIfEmpty(dirKeys[k]);
    // 协议子目录清空后尝试移除空的临时区根目录，避免任务结束后残留 .handysend-temp
    let tempRoot: string = dirNameOf(dirKeys[k]);
    if (tempRoot.length > 0) {
      removeDirectoryIfEmpty(tempRoot);
    }
  }
}

// 仅清空某会话的登记表（成功会话收尾调用：目标文件即交付物不删除，只回收登记表内存）。
export function clearRecvTargets(sessionId: string): void {
  recvTargetTempPaths.delete(sessionId);
  recvTargetCreatedDirs.delete(sessionId);
}

/**
 * 当前进程内已登记的接收临时文件路径（全部会话）。
 * 供启动清扫构造保留集：进程存活、仅 Ability 重建时，这些文件仍在写入，
 * 不能被当作遗留半成品删除。
 */
export function getRegisteredRecvTempPaths(): Array<string> {
  let result: Array<string> = [];
  recvTargetTempPaths.forEach((perFile: Record<string, string>) => {
    let fileIds: Array<string> = Object.keys(perFile);
    for (let i = 0; i < fileIds.length; i++) {
      let path: string = perFile[fileIds[i]];
      if (path.length > 0) {
        result.push(path);
      }
    }
  });
  return result;
}
