/**
 * CacheCleanupService.ets — 应用缓存清理
 *
 * 「清除缓存」只清理应用私有缓存目录（cacheDir）中的临时产物，以及旧版本遗留在
 * 持久目录下的发送临时残留；设置、会话草稿、收发文本、接收目录内的文件、TLS 身份
 * 目录与持久诊断日志文件均不在清理范围。存在未终结传输时拒绝清理，避免删除仍在
 * 使用的缩略图或暂存文件。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { getAppContext } from './repository/AppCore';
import { cleanupSendDirWithContext, legacySendDirBytes } from './repository/SendRepository';
import { getAllSessions } from './transfer/TransferSessionRegistry';
import { isTerminalStage } from '../model/transfer/TransferSession';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:CacheCleanup', '缓存清理');

/** 清除结果：cleared 成功，busy 存在未终结传输，unavailable 应用上下文缺失 */
export type CacheClearStatus = 'busy' | 'cleared' | 'unavailable';

/** 清除结果：status 为结果状态，bytes 为实际释放的字节数 */
export interface CacheClearResult {
  status: CacheClearStatus;
  bytes: number;
}

/** 目录清除结果：entries 为删除的顶层条目数，bytes 为实际释放的字节数 */
export interface DirectoryClearResult {
  entries: number;
  bytes: number;
}

/** 是否存在未终结的传输会话（含待确认与进行中，覆盖全部协议及网页上传/下载）。 */
export function hasActiveTransferSessions(): boolean {
  let sessions = getAllSessions();
  for (let i = 0; i < sessions.length; i++) {
    if (!isTerminalStage(sessions[i].stage)) {
      return true;
    }
  }
  return false;
}

/** 统计目录内全部文件的字节数（不跟随符号链接）；目录不存在或不可读时返回 0。 */
export function directoryBytesOf(dirPath: string): number {
  let total: number = 0;
  try {
    let names: Array<string> = fs.listFileSync(dirPath);
    for (let i = 0; i < names.length; i++) {
      let child: string = dirPath + '/' + names[i];
      let isDirectory: boolean = false;
      try {
        isDirectory = fs.lstatSync(child).isDirectory();
      } catch (_e) {
        continue;
      }
      total += sizeOfEntry(child, isDirectory);
    }
  } catch (_e) {
    // 目录不存在或读取失败——按 0 处理
  }
  return total;
}

/** 当前缓存大小（cacheDir 与旧版发送临时目录），供设置页展示。 */
export function getAppCacheSize(): number {
  let context: common.UIAbilityContext | undefined = getAppContext();
  if (context === undefined) {
    return 0;
  }
  return directoryBytesOf(context.cacheDir) + legacySendDirBytes();
}

/**
 * 递归统计单个条目的字节数（目录按其全部文件累计，符号链接按链接本身计）。
 * 统计失败或不可读时按 0 处理，不影响随后的 best-effort 删除。
 */
function sizeOfEntry(path: string, isDirectory: boolean): number {
  if (!isDirectory) {
    try {
      return fs.lstatSync(path).size;
    } catch (_e) {
      return 0;
    }
  }
  let total: number = 0;
  try {
    let names: Array<string> = fs.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      let child: string = path + '/' + names[i];
      let childIsDirectory: boolean = false;
      try {
        childIsDirectory = fs.lstatSync(child).isDirectory();
      } catch (_e) {
        continue;
      }
      total += sizeOfEntry(child, childIsDirectory);
    }
  } catch (_e) {
    // 目录不可读——按已知部分返回
  }
  return total;
}

/**
 * 清空目录内的全部条目并保留目录本身，返回删除的顶层条目数与字节数。
 * 目录不存在或不可读时静默返回空结果；单个条目删除失败不阻断其余条目。
 * 使用 lstat 判断类型，符号链接按文件删除，避免顺链删除缓存目录之外的内容。
 * 注意：OHOS 的 fs.rmdirSync 会递归删除目录及全部内容。
 */
export function clearDirectoryContents(dirPath: string): DirectoryClearResult {
  let result: DirectoryClearResult = {
    entries: 0,
    bytes: 0
  };
  try {
    let names: Array<string> = fs.listFileSync(dirPath);
    for (let i = 0; i < names.length; i++) {
      let path: string = dirPath + '/' + names[i];
      try {
        let isDirectory: boolean = fs.lstatSync(path).isDirectory();
        let bytes: number = sizeOfEntry(path, isDirectory);
        if (isDirectory) {
          fs.rmdirSync(path);
        } else {
          fs.unlinkSync(path);
        }
        result.entries++;
        result.bytes += bytes;
      } catch (_e) {
        // 单条目删除失败——忽略，继续清理其余条目
      }
    }
  } catch (_e) {
    // 目录不存在或读取失败——忽略
  }
  return result;
}

/**
 * 清除应用缓存。
 * 缓存根目录整体清空可覆盖发送缩略图、接收回退、MTA 预览、网页上传暂存与
 * 诊断日志导出临时文件；旧版本遗留的发送临时目录复用冷启动清理函数一并回收。
 * 不触碰 filesDir/HandySend/（TLS 身份与旧版接收残留由冷启动清理统一处理）。
 */
export function clearAppCache(): CacheClearResult {
  let context: common.UIAbilityContext | undefined = getAppContext();
  if (context === undefined) {
    return { status: 'unavailable', bytes: 0 };
  }
  if (hasActiveTransferSessions()) {
    return { status: 'busy', bytes: 0 };
  }
  let cacheResult: DirectoryClearResult = clearDirectoryContents(context.cacheDir);
  let legacyBytes: number = cleanupSendDirWithContext(context);
  logger.info('清除应用缓存完成：删除条目数=' + cacheResult.entries.toString() +
    ' 释放字节=' + (cacheResult.bytes + legacyBytes).toString());
  return { status: 'cleared', bytes: cacheResult.bytes + legacyBytes };
}
