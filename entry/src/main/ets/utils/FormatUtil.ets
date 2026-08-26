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

// 文件大小展示唯一实现：1000 进制，含 B/KB/MB/GB 档。
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
