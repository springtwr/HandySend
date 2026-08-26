import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { getLogger } from './Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:VideoThumbnail');

// 通过 AVImageGenerator 从视频文件/URI 生成指定尺寸的缩略图 PixelMap。
// 供历史记录页与发送页文件选择列表复用；
// 文件不可用/解码失败时返回 undefined（调用方回退类型图标）。
// 文件大小通过已打开的文件描述符获取（fd 方式兼容性最广，
// 不依赖系统版本对"按 URI stat"的支持）。
export async function generateVideoThumbnail(source: string, width: number,
  height: number): Promise<image.PixelMap | undefined> {
  try {
    let file: fs.File = fs.openSync(source, fs.OpenMode.READ_ONLY);
    try {
      let stat = fs.statSync(file.fd);
      // 为生成器独占打开文件描述符（文档要求传递 fd 后不可与其他读写共用）
      let generator: media.AVImageGenerator = await media.createAVImageGenerator();
      try {
        generator.fdSrc = { fd: file.fd, offset: 0, length: stat.size };
        return await generator.fetchFrameByTime(0,
          media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC,
          { width: width, height: height });
      } finally {
        try {
          await generator.release();
        } catch (_releaseErr) {
        }
      }
    } finally {
      fs.closeSync(file);
    }
  } catch (e) {
    logger.error('thumbnail failed: ' + e + ', src=' + source);
    return undefined;
  }
}
