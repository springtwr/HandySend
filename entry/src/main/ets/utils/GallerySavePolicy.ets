/**
 * GallerySavePolicy.ets — 「保存到相册」的可用性与已保存状态判定
 *
 * 判定口径：图片 / 视频、可解析出本机路径、且非图库来源（图库资源本身已在相册中）。
 * 已保存状态读取文件接收历史的 savedToGallery 标记，按路径与当前条目匹配。
 * 不做相册副本存在性检测：应用未申请相册读取权限，无法可靠查询用户是否已从图库删除。
 */

import { getMimeForFileName, isImage, isMediaMime } from './MimeUtils';
import { FileLocation, normalizeFileLocation } from './FileLocationUtil';
import { getHistory } from '../service/repository/ReceiveHistoryService';
import { ReceiveHistoryEntry } from '../model/Types';

/** 取媒体类型：真实媒体类型优先；缺失或通用二进制时按文件名扩展名兜底。 */
function mediaMimeOf(fileType: string, fileName: string): string {
  if (isMediaMime(fileType)) {
    return fileType;
  }
  if (fileType.length === 0 || fileType === 'application/octet-stream') {
    return getMimeForFileName(fileName);
  }
  return fileType;
}

/** 是否为可保存到相册的媒体文件（图片 / 视频、定位可解析出本机路径、非图库来源）。 */
export function isSaveToGalleryCandidate(path: string, fileType: string, fileName: string): boolean {
  if (path.length === 0) {
    return false;
  }
  if (!isMediaMime(mediaMimeOf(fileType, fileName))) {
    return false;
  }
  let location: FileLocation = normalizeFileLocation(path);
  return location.locatable && location.localPath.length > 0 && !location.isGalleryResource;
}

/** 是否为图片（供 MediaFileInfo.isImage 使用；类型缺失时按文件名扩展名兜底）。 */
export function isGalleryImage(fileType: string, fileName: string): boolean {
  return isImage(mediaMimeOf(fileType, fileName));
}

/** 取可保存到相册的本机路径（候选判定通过时非空；图库来源返回空串）。 */
export function gallerySaveLocalPath(path: string): string {
  return normalizeFileLocation(path).localPath;
}

/** 某个本机路径是否已在文件接收历史中标记为已保存到相册。 */
export function isPathSavedToGallery(path: string): boolean {
  if (path.length === 0) {
    return false;
  }
  let target: string = normalizeFileLocation(path).localPath;
  if (target.length === 0) {
    return false;
  }
  let history: Array<ReceiveHistoryEntry> = getHistory();
  for (let i = 0; i < history.length; i++) {
    let entry: ReceiveHistoryEntry = history[i];
    if (!entry.savedToGallery || entry.path.length === 0) {
      continue;
    }
    if (entry.path === path) {
      return true;
    }
    let entryPath: string = normalizeFileLocation(entry.path).localPath;
    if (entryPath.length > 0 && entryPath === target) {
      return true;
    }
  }
  return false;
}
