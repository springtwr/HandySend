import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { ReceiveHistoryEntry } from '../model/Types';
import { formatTime, formatSizeDetailed } from '../utils/FormatUtil';
import { isTextFile } from '../utils/MimeUtils';
import { readTextOfLocation } from '../utils/FileTextUtil';
import { generateVideoThumbnail } from '../utils/VideoThumbnailUtil';

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
  // 图片缩略图 URI（file://）：构造后异步解析缓存，渲染期不读盘；
  // 未解析完成/非图片/文件缺失时为空串（回退类型图标）
  @Trace private previewUriResolved: string = ''
  // 文本缩略预览内容：文本类条目按需读取文件本身；未加载/路径为空/文件缺失/非文本类时为空串
  @Trace public previewText: string = ''
  // 防重复加载标记
  private videoPreviewRequested: boolean = false
  private textPreviewRequested: boolean = false

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
    this.resolvePreviewUri();
  }

  get formattedTime(): string {
    return formatTime(this.timestamp);
  }

  get formattedSize(): string {
    return formatSizeDetailed(this.fileSize);
  }

  // 是否可查看完整文本：文本类文件且有真实路径（内容改为按路径读取文件本身）。
  // 旧数据里遗留的正文字段一律忽略；空路径记录为 false。
  get canViewFullText(): boolean {
    return this.path.length > 0 && isTextFile(this.fileType, this.fileName);
  }

  // 是否可打开所在目录：只要条目持有非空路径（即对应磁盘上的真实文件）即为真。
  // 文本类条目（含文本消息语义条目）已落盘为真实文件，不再按「消息」语义禁用。
  get canOpenContainingFolder(): boolean {
    return this.path.length > 0;
  }

  // 图片类型且文件真实存在时的缩略图 URI（file://），
  // 供列表左侧图标区直接渲染预览；取构造后异步解析的缓存，
  // 非图片/文件缺失时为空串（回退类型图标）。
  get previewUri(): string {
    return this.previewUriResolved;
  }

  // 异步解析图片缩略图 URI：文件存在性检查经异步 stat 完成，不阻塞构造/渲染；
  // 文件缺失/异常时保持空串回退类型图标
  private resolvePreviewUri(): void {
    if (this.isMessage || this.path.length === 0 || !this.fileType.startsWith('image/')) {
      return;
    }
    fs.stat(this.path).then((stat: fs.Stat): void => {
      if (stat.isFile()) {
        this.previewUriResolved = fileUri.getUriFromPath(this.path);
      }
    }).catch((_e: Object): void => {
      // 文件已移动/删除等异常——保持空串回退类型图标
    });
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
    this.previewPixelMap = await generateVideoThumbnail(this.path, 96, 96);
  }

  // 文本类条目（含文本消息条目）按需读取内容缩略预览。
  // 列表行出现时调用（fire-and-forget，不阻塞滚动）；判定与「查看全文」同源
  // （文本类 + 路径非空），读取失败或文件缺失时保持空串静默降级。
  async loadTextPreview(): Promise<void> {
    if (this.textPreviewRequested || this.previewText.length > 0) {
      return;
    }
    if (!this.canViewFullText) {
      return;
    }
    this.textPreviewRequested = true;
    let content = readTextOfLocation(this.path);
    if (content !== undefined) {
      this.previewText = content;
    }
  }
}
