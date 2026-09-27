import { fileIo as fs } from '@kit.CoreFileKit';
import { SendFileItem } from '../../model/Types';
import {
  nativeCreateCancelToken, nativeHashFileStreamFd
} from '../NativeBridge';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { isCreateChecksums } from './SettingsRepository';
import { notifyChange } from './AppCore';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ChecksumRepository', '校验');

// ── 校验和状态 ──

let checksumProgress: number = 0;
let checksumTotal: number = 0;

export function getChecksumProgress(): number {
  return checksumProgress;
}

export function getChecksumTotal(): number {
  return checksumTotal;
}

/**
 * 单次校验和运行的进度/取消钩子（可选注入）。
 * - onAggregate：汇聚后的进度回调（aggregateHashedBytes 含已完成文件字节，totalBytes 为本次待哈希字节总量）；
 * - shouldContinue：批次是否继续，返回 false 时中止剩余文件（全部参与会话终态）；
 * - onCancelIdChanged：当前文件取消令牌变更通知（空串表示无在途），供适配器登记准备期取消。
 */
export interface ChecksumRunOptions {
  onAggregate: (aggregateHashedBytes: number, totalBytes: number) => void
  shouldContinue: () => boolean
  onCancelIdChanged: (cancelId: string) => void
}

// 单次文件哈希的运行态：进度事件按 cancelId 归属到运行态后汇聚回调。
interface ChecksumRunState {
  runTotalBytes: number
  completedBytes: number
  onAggregate: (aggregateHashedBytes: number, totalBytes: number) => void
  lastAggregate: number
  lastPercent: number
  lastNotifyMs: number
}

// 在途运行态（cancelId → 运行态）：进度事件据此汇聚为字节进度。
let activeRuns: Map<string, ChecksumRunState> = new Map();

// 进度写回最小间隔（毫秒）：百分比变化不足 1% 且间隔不足该值时合并，抑制高频刷新。
export const CHECKSUM_NOTIFY_MIN_INTERVAL_MS: number = 200;

/**
 * 进度写回节流判定（纯函数，无副作用）：
 * 同值不重复写；百分比变化不足 1% 且距上次写入不足最小间隔时合并（返回 false）。
 */
export function shouldEmitChecksumAggregate(aggregateBytes: number, totalBytes: number,
  lastAggregateBytes: number, lastPercentValue: number, nowMs: number,
  lastNotifyMs: number): boolean {
  if (aggregateBytes === lastAggregateBytes) {
    return false;
  }
  if (totalBytes <= 0) {
    return true;
  }
  let percent: number = (aggregateBytes * 100) / totalBytes;
  if (percent - lastPercentValue < 1 && nowMs - lastNotifyMs < CHECKSUM_NOTIFY_MIN_INTERVAL_MS) {
    return false;
  }
  return true;
}

export async function calculateChecksumsForFiles(files: Array<SendFileItem>,
  options?: ChecksumRunOptions): Promise<void> {
  if (!isCreateChecksums()) {
    return;
  }
  // 过滤出需要计算 hash 的文件（跳过已有 hash 的），并累计本次待哈希字节总量
  let needHash: Array<number> = [];
  let pendingTotalBytes: number = 0;
  for (let i = 0; i < files.length; i++) {
    let existingHash: string | undefined = files[i].hash;
    if (existingHash === undefined || existingHash.length === 0) {
      needHash.push(i);
      pendingTotalBytes = pendingTotalBytes + files[i].size;
    }
  }
  if (needHash.length === 0) {
    return;
  }
  checksumTotal = files.length;
  checksumProgress = files.length - needHash.length;
  notifyChange();
  if (options !== undefined) {
    // 起始进度：0 / 本次待哈希字节总量
    options.onAggregate(0, pendingTotalBytes);
  }
  let completedBytes: number = 0;
  for (let idx = 0; idx < needHash.length; idx++) {
    // 批次中止判定：全部参与会话终态时不再继续剩余文件
    if (options !== undefined && !options.shouldContinue()) {
      break;
    }
    let i = needHash[idx];
    let cancelId: string = '';
    try {
      // fd-direct：源文件为 picker URI/沙箱路径，先 openSync 拿到 fd 再交给 Rust 流式哈希
      // （fd 所有权移交 Rust，计算完成或取消后由 Rust 关闭，本层不 close）
      let file = fs.openSync(files[i].filePath, fs.OpenMode.READ_ONLY);
      let token = nativeCreateCancelToken();
      cancelId = token.id;
      if (options !== undefined) {
        activeRuns.set(cancelId, {
          runTotalBytes: pendingTotalBytes,
          completedBytes: completedBytes,
          onAggregate: options.onAggregate,
          lastAggregate: 0,
          lastPercent: 0,
          lastNotifyMs: 0
        });
        options.onCancelIdChanged(cancelId);
      }
      let hash = await nativeHashFileStreamFd(file.fd, token.id);
      files[i].hash = hash;
      logger.debug('checksum[' + i + ']: path=' + files[i].filePath + ' sha256=' +
        (hash.length > 0 ? hash.substring(0, 16) + '...' : '(empty)'),
        { fileId: files[i].fileId });
    } catch (e) {
      // 打开/哈希失败置空哈希并继续，但须留痕以区分"未计算"与"计算失败"
      files[i].hash = '';
      logger.warn('checksum[' + i + '] 失败: path=' + files[i].filePath + ' error=' + String(e),
        { fileId: files[i].fileId });
    } finally {
      // 该文件运行态结束：注销并清空适配器的准备取消登记
      if (cancelId.length > 0) {
        activeRuns.delete(cancelId);
        if (options !== undefined) {
          options.onCancelIdChanged('');
        }
      }
    }
    // 失败文件同样计入已完成字节（按声明大小），保证进度不因单文件失败而停滞
    completedBytes = completedBytes + files[i].size;
    checksumProgress = checksumProgress + 1;
    if (options !== undefined) {
      // 文件边界进度直接写回（不经节流），确保每个文件的完成可见
      options.onAggregate(completedBytes, pendingTotalBytes);
    }
    notifyChange();
  }
  // 清空在途运行态，避免批次结束后残留
  activeRuns.clear();
  checksumTotal = 0;
  checksumProgress = 0;
  notifyChange();
}

/**
 * 校验和进度事件汇聚入口（由事件订阅入口调用）：
 * 按 cancelId 查在途运行态，aggregate = 已完成文件字节 + hashedBytes 后回调（含节流）。
 */
export function handleChecksumProgress(cancelId: string, hashedBytes: number): void {
  let run = activeRuns.get(cancelId);
  if (run === undefined) {
    return;
  }
  let aggregate: number = run.completedBytes + hashedBytes;
  let now: number = Date.now();
  if (!shouldEmitChecksumAggregate(aggregate, run.runTotalBytes, run.lastAggregate,
    run.lastPercent, now, run.lastNotifyMs)) {
    return;
  }
  run.lastAggregate = aggregate;
  run.lastPercent = run.runTotalBytes > 0 ? (aggregate * 100) / run.runTotalBytes : 0;
  run.lastNotifyMs = now;
  run.onAggregate(aggregate, run.runTotalBytes);
}
