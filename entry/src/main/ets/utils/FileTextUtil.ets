/**
 * FileTextUtil.ets — 文本内容读取共用工具
 *
 * 详情页与接收历史页共用同一读取能力：按沙箱路径或文件选择器 URI 读取文本内容。
 * 失败（文件不存在/权限不足/编码异常等）一律返回 undefined 表示「不可用」，
 * 不向界面抛异常，由调用方给出明确提示。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { getLogger } from './Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:FileTextUtil', '文本读取');

/** 缺省单次读取上限（字节）：避免超长文件一次性读入造成内存压力（超出部分不读取） */
const TEXT_READ_MAX_BYTES: number = 200000;

/** 归一读取上限：非正值或不可得时回退到缺省上限。 */
function effectiveLimit(maxBytes: number | undefined): number {
  return maxBytes !== undefined && maxBytes > 0 ? maxBytes : TEXT_READ_MAX_BYTES;
}

/** 按文件描述符读取文本内容（供仅有 fd 的场景）；失败返回 undefined。 */
function readTextByFd(fd: number, limit: number): string | undefined {
  try {
    let buf: ArrayBuffer = new ArrayBuffer(limit);
    let n: number = fs.readSync(fd, buf);
    if (n <= 0) {
      return '';
    }
    return new util.TextDecoder().decodeToString(new Uint8Array(buf, 0, n));
  } catch (e) {
    logger.warn('按文件描述符读取文本失败 fd=' + fd + ' 原因=' + String(e));
    return undefined;
  }
}

/** 按沙箱路径读取文本内容；失败返回 undefined。 */
function readTextByPath(path: string, limit: number): string | undefined {
  if (path.length === 0) {
    return undefined;
  }
  try {
    return fs.readTextSync(path, { length: limit });
  } catch (e) {
    logger.warn('按路径读取文本失败 path=' + path + ' 原因=' + String(e));
    return undefined;
  }
}

/**
 * 按「文件位置」读取文本内容：沙箱路径直接读；文件选择器 URI（file:// 开头）
 * 经文件描述符读取（其沙箱路径不可直接读）。失败返回 undefined 表示不可用。
 *
 * @param maxBytes 可选读取上限（字节）：预览场景传入预览阈值，使判定与读取同源；
 *                 缺省或非正值时沿用缺省上限
 */
export function readTextOfLocation(location: string, maxBytes?: number): string | undefined {
  if (location.length === 0) {
    return undefined;
  }
  let limit: number = effectiveLimit(maxBytes);
  if (!location.startsWith('file://')) {
    return readTextByPath(location, limit);
  }
  let file: fs.File | undefined = undefined;
  try {
    file = fs.openSync(location, fs.OpenMode.READ_ONLY);
    return readTextByFd(file.fd, limit);
  } catch (e) {
    logger.warn('按 URI 读取文本失败 uri=' + location + ' 原因=' + String(e));
    return undefined;
  } finally {
    if (file !== undefined) {
      try {
        fs.closeSync(file);
      } catch (_e) {
      }
    }
  }
}
