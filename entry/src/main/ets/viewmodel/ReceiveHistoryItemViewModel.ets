import { ReceiveHistoryEntry } from '../model/Types';
import { formatTime, formatSizeDetailed } from '../utils/FormatUtil';
import { isTextFile } from '../utils/MimeUtils';
import { readTextOfLocation, readTextOfLocationAsync } from '../utils/FileTextUtil';
import {
  TextPreviewVerdict,
  TEXT_PREVIEW_READ_MAX_BYTES,
  decideTextPreview,
  isTextPreviewable
} from '../utils/FilePreviewPolicy';
import { sendTextDir } from '../service/repository/SendRepository';
import { recvTextDir } from '../service/repository/ReceiveTargets';

/**
 * 列表行缩略预览的读取上限（字节）：行内只展示两行，无需读取完整的 128KB 预览；
 * 按 UTF-8 单字符最多 4 字节估算，留足 512 个字符的余量。
 */
export const RECEIVE_HISTORY_PREVIEW_READ_MAX_BYTES: number = 4 * 1024;

/**
 * 列表行缩略预览参与文本排版的字符上限：超出部分行内不会显示，但长字符串仍会参与
 * 文本测量与排版；按宽屏两行可容纳的字符数截断，避免多个大文本文件滚动时卡顿。
 */
export const RECEIVE_HISTORY_PREVIEW_MAX_CHARS: number = 512;

// 包装单个接收历史条目的条目级 ViewModel。
// 条目可变（可删除），因此对每个条目单独包装，
// 不把原始 DTO 直接暴露给视图。
// 文本预览策略（可预览性判定、全文读取上限）与会话详情页共用同一套公共能力，
// 两页口径不分叉；列表行缩略预览另行按两行展示需要裁剪读取量与排版字符数。
// 类型图标与媒体缩略由公共组件 FileEntryThumb 承载。
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
  // 文件夹摘要条目：一条记录代表一个接收会话；逐文件操作交给系统文件管理器
  @Trace public isFolder: boolean = false
  @Trace public fileCount: number = 1
  @Trace public failedCount: number = 0
  // 多选模式下的勾选状态：长按条目进入多选时勾选，逐条点击切换
  @Trace public selected: boolean = false
  // 文本缩略预览片段：文本类条目按需异步读取文件头部并截取到行内展示所需长度；
  // 未加载/路径为空/文件缺失/非文本类/读取失败时为空串
  @Trace public previewText: string = ''
  // 预览加载时记录文件是否超文本预览阈值（超阈值时全文预览按前 128KB 截断）；
  // 行内缩略预览固定只取文件头部片段，不使用该标记
  @Trace public previewTruncated: boolean = false
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
    this.isFolder = entry.isFolder === true;
    this.fileCount = entry.fileCount !== undefined && entry.fileCount > 0 ? entry.fileCount : 1;
    this.failedCount = entry.failedCount !== undefined ? entry.failedCount : 0;
  }

  get formattedTime(): string {
    return formatTime(this.timestamp);
  }

  get formattedSize(): string {
    return formatSizeDetailed(this.fileSize);
  }

  /** 是否为文本类条目（可读取内容按文本处理）；文件夹摘要不参与文本预览。 */
  get isTextEntry(): boolean {
    return !this.isFolder && isTextFile(this.fileType, this.fileName);
  }

  /** 是否可查看完整文本：文本类 + 定位非空 + 未超预览阈值（公共判定，与详情页同口径）。 */
  get canViewFullText(): boolean {
    return isTextPreviewable(this.isTextEntry, this.path, this.fileSize);
  }

  /** 是否可查看截断文本：文本类 + 定位非空（超阈值时读前 128KB 并挂截断说明）。 */
  get canViewTruncatedText(): boolean {
    return this.isTextEntry && this.path.length > 0;
  }

  /** 文本类条目是否超过预览阈值：超限时截断预览前 128KB 并挂截断说明（与「内容不可用」区分）。 */
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

  /**
   * 是否为应用私有文本（收发文本落盘目录内的文件）：私有目录无文件管理器可导航位置，
   * 故「打开所在位置」无合理语义，由菜单层置灰；「用其他应用打开」走应用文件分享机制（隐式 Want +
   * 只读 URI 授权，沙箱自有文件属可分享目录），不受影响。
   */
  get isSandboxText(): boolean {
    if (this.path.length === 0) {
      return false;
    }
    let sendDir: string = sendTextDir();
    if (sendDir.length > 0 && this.path.startsWith(sendDir)) {
      return true;
    }
    let recvDir: string = recvTextDir();
    return recvDir.length > 0 && this.path.startsWith(recvDir);
  }

  // 文本类条目（含文本消息条目）按需读取内容缩略预览。
  // 列表行出现时调用（fire-and-forget，异步读取不阻塞滚动）；行内只展示两行，
  // 故读取量与参与排版的字符数都按展示需要裁剪，避免多个超大文本文件在滚动时反复付出
  // 大文件读取与长文本排版开销。读取失败或文件缺失时保持空串静默降级。
  async loadTextPreview(): Promise<void> {
    if (this.textPreviewRequested || this.previewText.length > 0) {
      return;
    }
    if (!this.canViewTruncatedText) {
      return;
    }
    this.textPreviewRequested = true;
    let content = await readTextOfLocationAsync(this.path, RECEIVE_HISTORY_PREVIEW_READ_MAX_BYTES);
    if (content !== undefined) {
      this.previewText = content.length > RECEIVE_HISTORY_PREVIEW_MAX_CHARS ?
        content.substring(0, RECEIVE_HISTORY_PREVIEW_MAX_CHARS) : content;
      this.previewTruncated = this.isPreviewOverLimit;
    }
  }

  // 读取完整文本内容（查看全文弹窗）：读取上限与预览阈值同源；失败返回 undefined 表示不可用。
  readFullText(): string | undefined {
    return readTextOfLocation(this.path, TEXT_PREVIEW_READ_MAX_BYTES);
  }
}
