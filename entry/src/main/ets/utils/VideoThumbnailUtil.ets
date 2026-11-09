import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { getLogger } from './Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:VideoThumbnail', '缩略图');

// 解码串行化：AVImageGenerator 开销大，同进程同一时刻只允许一次解码；
// 并发懒加载请求在此排队依次执行（不丢弃），保证列表内多个视频都能拿到缩略图。
// 取消标记：暂存列表增删导致已发起的解码过期时，调用方置位后本模块丢弃过期结果。
let decodeQueueTail: Promise<void> = Promise.resolve();
let decodingSource: string = '';
let cancelRequested: boolean = false;

/** 请求取消当前解码：仅当在途解码属于给定来源时置位，避免误删其他条目的解码结果。 */
export function cancelVideoThumbnail(source?: string): void {
  if (source === undefined || source === decodingSource) {
    cancelRequested = true;
  }
}

// 通过 AVImageGenerator 从视频文件/URI 生成指定尺寸的缩略图 PixelMap。
// 供历史记录页与发送页文件选择列表复用；并发调用按到达顺序串行执行，
// 文件不可用/解码失败/被取消时返回 undefined（调用方回退类型图标）。
// 文件大小通过已打开的文件描述符获取（fd 方式兼容性最广，
// 不依赖系统版本对"按 URI stat"的支持）。
export async function generateVideoThumbnail(source: string, width: number,
  height: number): Promise<image.PixelMap | undefined> {
  // 排队等待前一个请求结束：无论其成败队列都会推进，单个文件失败不会卡住后续条目
  let previous: Promise<void> = decodeQueueTail;
  let finish: () => void = () => {
  };
  decodeQueueTail = new Promise<void>((resolve: () => void): void => {
    finish = resolve;
  });
  try {
    await previous;
    return await decodeVideoFrame(source, width, height);
  } finally {
    finish();
  }
}

// 实际解码一帧（同一时刻最多一个在途调用）
async function decodeVideoFrame(source: string, width: number,
  height: number): Promise<image.PixelMap | undefined> {
  decodingSource = source;
  cancelRequested = false;
  try {
    let file: fs.File = fs.openSync(source, fs.OpenMode.READ_ONLY);
    try {
      let stat = fs.statSync(file.fd);
      if (cancelRequested) {
        return undefined;
      }
      // 为生成器独占打开文件描述符（文档要求传递 fd 后不可与其他读写共用）
      let generator: media.AVImageGenerator = await media.createAVImageGenerator();
      try {
        if (cancelRequested) {
          return undefined;
        }
        generator.fdSrc = { fd: file.fd, offset: 0, length: stat.size };
        let frame = await generator.fetchFrameByTime(0,
          media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC,
          { width: width, height: height });
        if (cancelRequested) {
          try {
            frame.release();
          } catch (_releaseErr) {
          }
          return undefined;
        }
        return frame;
      } finally {
        try {
          await generator.release();
        } catch (_releaseErr) {
        }
      }
    } finally {
      // 关闭抛错不掩盖解码结果（外层已捕获转 undefined，仅损失缩略图）
      try {
        fs.closeSync(file);
      } catch (_closeErr) {
      }
    }
  } catch (e) {
    logger.warn('缩略图生成失败：' + e + ', src=' + source);
    return undefined;
  } finally {
    decodingSource = '';
  }
}
