import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { ReceiveHistoryEntry } from '../model/Types';
import { formatTime, formatSize } from '../utils/FormatUtil';

// 包装单个接收历史条目的条目级 ViewModel。
// 依据基于场景的列表策略（方案 B）选择：条目为
// 可修改（可删除），因此每个条目被包装而不是暴露
// 将原始 DTO 暴露给视图。
@ObservedV2
export class ReceiveHistoryItemViewModel {
  @Trace public id: string = ''
  @Trace public fileName: string = ''
  @Trace public fileType: string = ''
  @Trace public senderAlias: string = ''
  @Trace public fileSize: number = 0
  @Trace public savedToGallery: boolean = false
  @Trace public isMessage: boolean = false
  @Trace public timestamp: number = 0
  @Trace public path: string = ''
  // 视频缩略图（异步懒加载生成）；未生成/失败时为 undefined（回退类型图标）
  @Trace public previewPixelMap: image.PixelMap | undefined = undefined
  // 防重复加载标记
  private videoPreviewRequested: boolean = false

  constructor(entry: ReceiveHistoryEntry) {
    this.id = entry.id;
    this.fileName = entry.fileName;
    this.fileType = entry.fileType;
    this.senderAlias = entry.senderAlias;
    this.fileSize = entry.fileSize;
    this.savedToGallery = entry.savedToGallery;
    this.isMessage = entry.isMessage;
    this.timestamp = entry.timestamp;
    this.path = entry.path;
  }

  get formattedTime(): string {
    return formatTime(this.timestamp);
  }

  get formattedSize(): string {
    return formatSize(this.fileSize);
  }

  // 图片类型且文件真实存在时的缩略图 URI（file://），
  // 供列表左侧图标区直接渲染预览；非图片/文件缺失时返回空串（回退类型图标）。
  get previewUri(): string {
    if (this.isMessage || this.path.length === 0 || !this.fileType.startsWith('image/')) {
      return '';
    }
    try {
      let stat = fs.statSync(this.path);
      if (!stat.isFile()) {
        return '';
      }
      return fileUri.getUriFromPath(this.path);
    } catch (_e) {
      // 文件已移动/删除等异常——返回空串回退类型图标
      return '';
    }
  }

  // 视频类型且文件真实存在时，通过 AVImageGenerator 异步生成缩略图 PixelMap。
  // 列表行出现时调用（fire-and-forget）；生成成功前 previewPixelMap 保持
  // undefined（显示类型图标），失败静默回退。内部已捕获全部异常。
  async loadVideoPreview(): Promise<void> {
    if (this.isMessage || this.videoPreviewRequested || this.previewPixelMap !== undefined) {
      return;
    }
    if (this.path.length === 0 || !this.fileType.startsWith('video/')) {
      return;
    }
    this.videoPreviewRequested = true;
    try {
      let stat = fs.statSync(this.path);
      if (!stat.isFile()) {
        return;
      }
      let file = fs.openSync(this.path, fs.OpenMode.READ_ONLY);
      try {
        let generator: media.AVImageGenerator = await media.createAVImageGenerator();
        try {
          generator.fdSrc = { fd: file.fd, offset: 0, length: stat.size };
          let pixelMap: image.PixelMap = await generator.fetchFrameByTime(0,
            media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC,
            { width: 96, height: 96 });
          this.previewPixelMap = pixelMap;
        } finally {
          try {
            await generator.release();
          } catch (_releaseErr) {
          }
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (_e) {
      // 视频文件不可用或解码失败——保持 undefined 回退类型图标
    }
  }
}
