// 入站文件夹摘要：协议没有目录对象，任一条 fileName 含 '/' 即视为文件夹批次。
import { ReceiveHistoryEntry, SendFileItem } from '../Types';
import { SessionFileDescriptor, SessionFolderInfo } from './TransferSession';

/**
 * 由入站文件描述汇总文件夹信息；没有相对路径时返回 undefined（普通文件批次）。
 * 根目录名取第一段；多根时 name/path 留空，仅保留 rootCount。
 */
export function summarizeInboundFolder(files: Array<SessionFileDescriptor>): SessionFolderInfo | undefined {
  let names: Array<string> = [];
  let sizes: Array<number> = [];
  for (let i = 0; i < files.length; i++) {
    names.push(files[i].fileName);
    sizes.push(files[i].totalBytes);
  }
  return summarizeFolderNames(names, sizes);
}

/** 由文件名与大小汇总文件夹信息；供接收历史（已完成条目）复用。 */
export function summarizeFolderNames(names: Array<string>, sizes: Array<number>): SessionFolderInfo | undefined {
  let roots: Set<string> = new Set();
  let folderBytes: number = 0;
  let folderCount: number = 0;
  let looseBytes: number = 0;
  let looseCount: number = 0;
  let hasRelative: boolean = false;
  for (let i = 0; i < names.length; i++) {
    let fileName: string = names[i];
    let size: number = i < sizes.length ? sizes[i] : 0;
    let slash: number = fileName.indexOf('/');
    if (slash > 0) {
      hasRelative = true;
      roots.add(fileName.substring(0, slash));
      folderCount++;
      folderBytes += size;
    } else if (slash === 0) {
      // 绝对路径/空首段由接收目标解析拒绝；摘要只标记为相对批次
      hasRelative = true;
      folderCount++;
      folderBytes += size;
    } else {
      looseCount++;
      looseBytes += size;
    }
  }
  if (!hasRelative) {
    return undefined;
  }
  let firstName: string = '';
  roots.forEach((value: string): void => {
    if (firstName.length === 0) {
      firstName = value;
    }
  });
  let info: SessionFolderInfo = {
    name: roots.size === 1 ? firstName : '',
    path: '',
    rootCount: roots.size,
    fileCount: folderCount,
    totalBytes: folderBytes,
    looseFileCount: looseCount,
    looseBytes: looseBytes
  };
  return info;
}

/** 由出站发送条目汇总文件夹信息；文件名为相对路径即视为文件夹批次。 */
export function summarizeOutboundFolder(files: Array<SendFileItem>): SessionFolderInfo | undefined {
  let names: Array<string> = [];
  let sizes: Array<number> = [];
  for (let i = 0; i < files.length; i++) {
    names.push(files[i].fileName);
    sizes.push(files[i].size);
  }
  let folder: SessionFolderInfo | undefined = summarizeFolderNames(names, sizes);
  if (folder === undefined) {
    return undefined;
  }
  if (folder.rootCount === 1) {
    for (let i = 0; i < files.length; i++) {
      if (files[i].fileName.indexOf('/') > 0) {
        folder.path = folderRootPathOf(files[i].filePath, files[i].fileName);
        break;
      }
    }
  }
  return folder;
}

/** 构造文件夹接收历史摘要条目；普通文件批次返回 undefined。 */
export function buildFolderReceiveHistoryEntry(sessionId: string, names: Array<string>,
  sizes: Array<number>, firstPath: string, firstRelativeName: string,
  senderAlias: string, timestamp: number = Date.now()): ReceiveHistoryEntry | undefined {
  let folder: SessionFolderInfo | undefined = summarizeFolderNames(names, sizes);
  if (folder === undefined) {
    return undefined;
  }
  let rootPath: string = folder.rootCount === 1 ?
    folderRootPathOf(firstPath, firstRelativeName) : '';
  return {
    id: sessionId,
    fileName: folder.name,
    fileType: 'folder',
    path: rootPath,
    savedToGallery: false,
    isMessage: false,
    fileSize: folder.totalBytes,
    senderAlias: senderAlias,
    timestamp: timestamp,
    isFolder: true,
    fileCount: folder.fileCount,
    failedCount: 0
  };
}

/**
 * 由最终路径与相对名还原文件夹根路径：
 * `Photos/2024/a.jpg` + `/.../Download/Photos/2024/a.jpg` → `/.../Download/Photos`。
 * 相对名含 N 个目录段时，从最终路径末尾去掉 N 段。
 */
export function folderRootPathOf(finalPath: string, relativeName: string): string {
  if (finalPath.length === 0 || relativeName.length === 0) {
    return '';
  }
  let dirs: number = 0;
  for (let i = 0; i < relativeName.length; i++) {
    if (relativeName.charAt(i) === '/') {
      dirs++;
    }
  }
  let path: string = finalPath;
  for (let i = 0; i < dirs; i++) {
    let slash: number = path.lastIndexOf('/');
    if (slash <= 0) {
      return '';
    }
    path = path.substring(0, slash);
  }
  return path;
}
