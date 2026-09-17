// 文件类型图标映射：将 MIME 类型 / 文件名扩展名映射到彩色 PNG 图标资源。
// 发送页暂存列表与接收历史列表共用同一映射，保证同一文件两处图标一致。

import { getMimeForFileName } from './MimeUtils';

// MIME 精确匹配表：键为 MIME 字符串，值为对应分类的图标资源
const MIME_ICON_MAP: Record<string, Resource> = {
  'application/pdf': $r('app.media.ic_file_pdf'),
  'application/msword': $r('app.media.ic_file_word'),
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': $r('app.media.ic_file_word'),
  'application/kswps': $r('app.media.ic_file_word'),
  'application/vnd.ms-excel': $r('app.media.ic_file_excel'),
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': $r('app.media.ic_file_excel'),
  'application/kset': $r('app.media.ic_file_excel'),
  'application/vnd.ms-powerpoint': $r('app.media.ic_file_ppt'),
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': $r('app.media.ic_file_ppt'),
  'application/ksdps': $r('app.media.ic_file_ppt'),
  'application/ofd': $r('app.media.ic_file_ofd'),
  'application/x-pom': $r('app.media.ic_file_flow'),
  'application/vnd.visio': $r('app.media.ic_file_flow'),
  'application/vnd.ms-visio.drawing': $r('app.media.ic_file_flow'),
  'application/x-drawio': $r('app.media.ic_file_flow'),
  'application/x-eddx': $r('app.media.ic_file_flow'),
  'application/x-pos': $r('app.media.ic_file_flow'),
  'application/x-xmind': $r('app.media.ic_file_mindmap'),
  'application/x-freemind': $r('app.media.ic_file_mindmap'),
  'text/x-opml': $r('app.media.ic_file_mindmap'),
  'application/zip': $r('app.media.ic_file_archive'),
  'application/vnd.rar': $r('app.media.ic_file_archive'),
  'application/x-7z-compressed': $r('app.media.ic_file_archive'),
  'application/x-tar': $r('app.media.ic_file_archive'),
  'application/gzip': $r('app.media.ic_file_archive'),
  'application/x-bzip2': $r('app.media.ic_file_archive'),
  'application/x-xz': $r('app.media.ic_file_archive'),
  'text/plain': $r('app.media.ic_file_txt'),
  'text/html': $r('app.media.ic_file_code'),
  'text/css': $r('app.media.ic_file_code'),
  'application/javascript': $r('app.media.ic_file_code'),
  'text/javascript': $r('app.media.ic_file_code'),
  'application/json': $r('app.media.ic_file_code'),
  'application/xml': $r('app.media.ic_file_code'),
  'text/xml': $r('app.media.ic_file_code'),
  'application/vnd.android.package-archive': $r('app.media.ic_file_apk'),
  'application/x-msdownload': $r('app.media.ic_file_exe')
};

// 按 MIME 判定图标：先匹配 image/video/audio 前缀，再查精确匹配表；未命中返回 undefined
function matchIconByMime(mime: string): Resource | undefined {
  if (mime.startsWith('image/')) {
    return $r('app.media.ic_file_image');
  }
  if (mime.startsWith('video/')) {
    return $r('app.media.ic_file_video');
  }
  if (mime.startsWith('audio/')) {
    return $r('app.media.ic_file_audio');
  }
  return MIME_ICON_MAP[mime];
}

export function getFileTypeIconResource(isMessage: boolean, fileName: string, fileType: string): Resource {
  if (isMessage) {
    return $r('app.media.ic_file_message');
  }
  let icon = matchIconByMime(fileType);
  if (icon !== undefined) {
    return icon;
  }
  // MIME 缺失或为 octet-stream 等未命中情况：按文件名扩展名推断后重试
  icon = matchIconByMime(getMimeForFileName(fileName));
  if (icon !== undefined) {
    return icon;
  }
  return $r('app.media.ic_file_unknown');
}
