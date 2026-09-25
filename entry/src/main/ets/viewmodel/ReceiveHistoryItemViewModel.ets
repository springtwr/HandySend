import { ReceiveHistoryEntry } from '../model/Types';
import { formatTime, formatSizeDetailed } from '../utils/FormatUtil';
import { isTextFile } from '../utils/MimeUtils';
import { readTextOfLocation } from '../utils/FileTextUtil';
import {
  TextPreviewVerdict,
  TEXT_PREVIEW_READ_MAX_BYTES,
  decideTextPreview,
  isTextPreviewable
} from '../utils/FilePreviewPolicy';

// 包装单个接收历史条目的条目级 ViewModel。
// 依据基于场景的列表策略（方案 B）选择：条目为
// 可修改（可删除），因此每个条目被包装而不是暴露
// 将原始 DTO 暴露给视图。
// 文本预览策略（可预览性判定、读取上限）与会话详情页共用同一套公共能力，
// 两页口径不分叉；类型图标与媒体缩略由公共组件 FileEntryThumb 承载。
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
  // 文本缩略预览内容：文本类条目按需读取文件本身，且未超预览阈值；
  // 未加载/路径为空/文件缺失/非文本类/超阈值时为空串
  @Trace public previewText: string = ''
  // 防重复加载标记
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
  }

  get formattedTime(): string {
    return formatTime(this.timestamp);
  }

  get formattedSize(): string {
    return formatSizeDetailed(this.fileSize);
  }

  /** 是否为文本类条目（可读取内容按文本处理）。 */
  get isTextEntry(): boolean {
    return isTextFile(this.fileType, this.fileName);
  }

  /** 是否可查看完整文本：文本类 + 定位非空 + 未超预览阈值（公共判定，与详情页同口径）。 */
  get canViewFullText(): boolean {
    return isTextPreviewable(this.isTextEntry, this.path, this.fileSize);
  }

  /** 文本类条目是否超过预览阈值：不读取内容、不产缩略预览，查看全文时明确提示文件过大。 */
  get isPreviewOverLimit(): boolean {
    return decideTextPreview(this.isTextEntry, this.path, this.fileSize) === TextPreviewVerdict.overLimit;
  }

  /** 是否可复制文本内容：文本类且路径非空（复制为用户显式动作，不受预览阈值限制）。 */
  get canCopyText(): boolean {
    return this.path.length > 0 && this.isTextEntry;
  }

  // 是否可打开所在目录：只要条目持有非空路径（即对应磁盘上的真实文件）即为真。
  // 文本类条目（含文本消息语义条目）已落盘为真实文件，不再按「消息」语义禁用。
  get canOpenContainingFolder(): boolean {
    return this.path.length > 0;
  }

  // 文本类条目（含文本消息条目）按需读取内容缩略预览。
  // 列表行出现时调用（fire-and-forget，不阻塞滚动）；判定与「查看全文」同源
  // （文本类 + 路径非空 + 未超阈值），超阈值不读取内容，读取失败或文件缺失时保持空串静默降级。
  async loadTextPreview(): Promise<void> {
    if (this.textPreviewRequested || this.previewText.length > 0) {
      return;
    }
    if (!this.canViewFullText) {
      return;
    }
    this.textPreviewRequested = true;
    let content = readTextOfLocation(this.path, TEXT_PREVIEW_READ_MAX_BYTES);
    if (content !== undefined) {
      this.previewText = content;
    }
  }

  // 读取完整文本内容（查看全文弹窗）：读取上限与预览阈值同源；失败返回 undefined 表示不可用。
  readFullText(): string | undefined {
    return readTextOfLocation(this.path, TEXT_PREVIEW_READ_MAX_BYTES);
  }
}
