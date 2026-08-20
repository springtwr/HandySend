// FormatUtil：文件大小和时间戳的纯展示格式化辅助。

export function formatTime(timestamp: number): string {
  let date = new Date(timestamp);
  let y = date.getFullYear();
  let m = (date.getMonth() + 1).toString().padStart(2, '0');
  let d = date.getDate().toString().padStart(2, '0');
  let h = date.getHours().toString().padStart(2, '0');
  let min = date.getMinutes().toString().padStart(2, '0');
  return y + '-' + m + '-' + d + ' ' + h + ':' + min;
}

export function formatSize(size: number): string {
  let KB = 1000;
  let MB = KB * 1000;
  if (size >= MB) {
    return (size / MB).toFixed(1) + ' MB';
  }
  if (size >= KB) {
    return (size / KB).toFixed(1) + ' KB';
  }
  return size + ' B';
}

// 支持 GB 的扩展变体（用于文件选择列表）。
export function formatSizeDetailed(size: number): string {
  if (size < 1000) {
    return size + ' B';
  }
  if (size < 1000 * 1000) {
    return (size / 1000).toFixed(1) + ' KB';
  }
  if (size < 1000 * 1000 * 1000) {
    return (size / 1000 / 1000).toFixed(1) + ' MB';
  }
  return (size / 1000 / 1000 / 1000).toFixed(1) + ' GB';
}
