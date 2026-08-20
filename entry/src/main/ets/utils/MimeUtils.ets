// MimeUtils：从 AppService 抽出的 MIME 类型工具函数

export function isImage(mime: string): boolean {
  return mime.startsWith('image/');
}

export function isVideo(mime: string): boolean {
  return mime.startsWith('video/');
}

export function hasDirectoryPath(fileName: string): boolean {
  return fileName.indexOf('/') >= 0;
}

export function getMimeForExt(ext: string): string {
  let map: Record<string, string> = {
    'jpg': 'image/jpeg', 'jpeg': 'image/jpeg',
    'png': 'image/png', 'gif': 'image/gif', 'bmp': 'image/bmp',
    'webp': 'image/webp', 'svg': 'image/svg+xml', 'heic': 'image/heic',
    'mp4': 'video/mp4', 'avi': 'video/x-msvideo',
    'mkv': 'video/x-matroska', 'mov': 'video/quicktime', 'webm': 'video/webm',
    'mp3': 'audio/mpeg', 'wav': 'audio/wav', 'ogg': 'audio/ogg',
    'flac': 'audio/flac', 'aac': 'audio/aac', 'm4a': 'audio/mp4',
    'pdf': 'application/pdf',
    'doc': 'application/msword', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel', 'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint', 'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'zip': 'application/zip', 'rar': 'application/vnd.rar', '7z': 'application/x-7z-compressed',
    'tar': 'application/x-tar', 'gz': 'application/gzip',
    'txt': 'text/plain', 'html': 'text/html', 'css': 'text/css',
    'js': 'application/javascript', 'json': 'application/json', 'xml': 'application/xml',
    'apk': 'application/vnd.android.package-archive', 'exe': 'application/x-msdownload'
  };
  let mime = map[ext];
  if (mime !== undefined) {
    return mime;
  }
  return 'application/octet-stream';
}

export function getMimeForFileName(fileName: string): string {
  let dot = fileName.lastIndexOf('.');
  if (dot < 0) {
    return 'application/octet-stream';
  }
  let ext = fileName.substring(dot + 1).toLowerCase();
  return getMimeForExt(ext);
}

const IMAGE_EXTENSIONS: Array<string> = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'svg'];

export function isImageExtension(ext: string): boolean {
  return IMAGE_EXTENSIONS.indexOf(ext.toLowerCase()) >= 0;
}
