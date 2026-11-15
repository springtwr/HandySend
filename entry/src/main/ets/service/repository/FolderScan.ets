// 文件夹选择与递归扫描：选择目录、持久化授权、列目录、取元数据、构造相对名。
// 只产出扫描结果，不直接写暂存列表；发送页负责暂存/去重/上限提示。
import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker, ListFileOptions } from '@kit.CoreFileKit';
import { MAX_BATCH_FILES } from '../../model/TransferLimits';
import { buildSendRelativePath, SendPathResult } from '../../model/transfer/SendFolderPath';
import { nativeSanitizeFileName } from '../NativeBridge';
import { ensureUriAccess, persistPickedUris } from '../../utils/UriPermission';
import { isFolderSelectionSupported } from '../../utils/FolderSelection';
import { forEachConcurrently } from '../../utils/AsyncBatch';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:FolderScan', '文件夹扫描');

export enum FolderScanStatus {
  success = 'success',
  cancelled = 'cancelled',
  unsupported = 'unsupported',
  empty = 'empty',
  tooMany = 'tooMany',
  failed = 'failed'
}

/** 扫描到的单个文件。 */
export class FolderScanEntry {
  uri: string = ''
  path: string = ''
  relativeName: string = ''
  size: number = 0
  lastModified: number = 0

  constructor(uri: string, path: string, relativeName: string, size: number, lastModified: number) {
    this.uri = uri;
    this.path = path;
    this.relativeName = relativeName;
    this.size = size;
    this.lastModified = lastModified;
  }
}

/** 一次文件夹扫描的结果。 */
export class FolderScanResult {
  rootName: string = ''
  rootUri: string = ''
  rootPath: string = ''
  entries: Array<FolderScanEntry> = []
  totalBytes: number = 0
  skipped: number = 0
}

export class FolderScanPickResult {
  status: FolderScanStatus = FolderScanStatus.failed
  result: FolderScanResult | undefined = undefined

  constructor(status: FolderScanStatus, result: FolderScanResult | undefined) {
    this.status = status;
    this.result = result;
  }
}

function folderNameOf(folderPath: string): string {
  let normalized: string = folderPath;
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  let slash: number = normalized.lastIndexOf('/');
  let name: string = slash >= 0 ? normalized.substring(slash + 1) : normalized;
  return name.length > 0 ? name : 'folder';
}

/**
 * 拉起目录选择器并扫描；用户取消返回 cancelled，能力不支持返回 unsupported。
 */
export async function pickAndScanFolder(context: common.UIAbilityContext): Promise<FolderScanPickResult> {
  if (!isFolderSelectionSupported()) {
    return new FolderScanPickResult(FolderScanStatus.unsupported, undefined);
  }
  let options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
  options.selectMode = picker.DocumentSelectMode.FOLDER;
  options.maxSelectNumber = 1;
  let uris: Array<string> = [];
  try {
    let documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    uris = await documentPicker.select(options);
  } catch (e) {
    let errorText: string = String(e);
    if (errorText.includes('801') || errorText.includes('code: 0')) {
      return new FolderScanPickResult(FolderScanStatus.cancelled, undefined);
    }
    logger.warn('选择文件夹失败：' + errorText);
    return new FolderScanPickResult(FolderScanStatus.failed, undefined);
  }
  if (uris.length === 0) {
    return new FolderScanPickResult(FolderScanStatus.cancelled, undefined);
  }
  return scanFolderUri(uris[0]);
}

/**
 * 扫描一个已获得的目录 URI（发送页选择或系统分享）。
 * 扫描前持久化并激活目录授权，目录内子项沿用同一授权。
 */
export async function scanFolderUri(folderUri: string): Promise<FolderScanPickResult> {
  let rootPath: string = '';
  try {
    rootPath = new fileUri.FileUri(folderUri).path;
  } catch (e) {
    logger.warn('目录 URI 解析失败：' + String(e));
    return new FolderScanPickResult(FolderScanStatus.failed, undefined);
  }
  if (rootPath.length === 0) {
    return new FolderScanPickResult(FolderScanStatus.failed, undefined);
  }
  try {
    await persistPickedUris([folderUri]);
    await ensureUriAccess(folderUri);
  } catch (e) {
    logger.warn('目录授权处理失败：' + String(e));
  }

  let names: Array<string> = [];
  try {
    let listOptions: ListFileOptions = { recursion: true };
    names = await fs.listFile(rootPath, listOptions);
  } catch (e) {
    logger.warn('列出文件夹失败 path=' + rootPath + ' 原因=' + String(e));
    return new FolderScanPickResult(FolderScanStatus.failed, undefined);
  }
  if (names.length === 0) {
    return new FolderScanPickResult(FolderScanStatus.empty, undefined);
  }
  if (names.length > MAX_BATCH_FILES) {
    logger.warn('文件夹文件数超上限 count=' + names.length + ' limit=' + MAX_BATCH_FILES);
    return new FolderScanPickResult(FolderScanStatus.tooMany, undefined);
  }

  let rootName: string = folderNameOf(rootPath);
  let entries: Array<FolderScanEntry | undefined> = [];
  for (let i = 0; i < names.length; i++) {
    entries.push(undefined);
  }
  let skipped: number = 0;
  try {
    await forEachConcurrently(names.length, async (index: number): Promise<void> => {
      let rawName: string = names[index];
      let relative: string = rawName.startsWith('/') ? rawName.substring(1) : rawName;
      if (relative.length === 0 || relative.endsWith('/')) {
        skipped++;
        return;
      }
      let sendPath: SendPathResult =
        buildSendRelativePath(rootName, relative, (name: string): string => nativeSanitizeFileName(name));
      if (!sendPath.ok) {
        skipped++;
        return;
      }
      let filePath: string = rootPath + '/' + relative;
      let stat: fs.Stat | undefined = undefined;
      try {
        stat = await fs.stat(filePath);
      } catch (_e) {
        skipped++;
        return;
      }
      if (stat === undefined || !stat.isFile()) {
        skipped++;
        return;
      }
      let childUri: string = '';
      try {
        childUri = fileUri.getUriFromPath(filePath);
      } catch (_e) {
        skipped++;
        return;
      }
      entries[index] = new FolderScanEntry(childUri, filePath, sendPath.relativeName,
        stat.size, Math.floor(stat.mtime * 1000));
    });
  } catch (e) {
    logger.warn('扫描文件夹子项失败：' + String(e));
    return new FolderScanPickResult(FolderScanStatus.failed, undefined);
  }

  let result: FolderScanResult = new FolderScanResult();
  result.rootName = rootName;
  result.rootUri = folderUri;
  result.rootPath = rootPath;
  result.skipped = skipped;
  for (let i = 0; i < entries.length; i++) {
    let entry: FolderScanEntry | undefined = entries[i];
    if (entry === undefined) {
      continue;
    }
    result.entries.push(entry);
    result.totalBytes += entry.size;
  }
  if (result.entries.length === 0) {
    return new FolderScanPickResult(FolderScanStatus.empty, undefined);
  }
  result.entries.sort((a: FolderScanEntry, b: FolderScanEntry): number => {
    return a.relativeName.localeCompare(b.relativeName);
  });
  logger.debug('文件夹扫描完成 根=' + rootName + ' 文件数=' + result.entries.length +
    ' 跳过=' + skipped + ' 字节=' + result.totalBytes);
  return new FolderScanPickResult(FolderScanStatus.success, result);
}
