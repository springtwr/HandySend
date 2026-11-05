/**
 * SessionFileList.ets — 详情页文件清单
 *
 * 逐文件条目：首行由类型图标 / 图片与视频缩略区、文件名（最多两行）、大小与状态列组成，
 * 首行内容在 48vp 最小行高内垂直居中（与发送页暂存列表一致，单行 / 两行文件名首行等高）；
 * 其下为通栏的独立进度条与百分比。
 * 条目直接排布于外层文件卡片容器内（不套独立色块），相邻条目之间以分隔线区隔。
 * 直接读取可观测视图模型的实时清单（进度 / 阶段随 `@Trace` 字段刷新）。
 * 无字节进度的会话（如单条文本消息的仅预览送达）不渲染进度条与百分比，仅列文件与状态。
 * 条目点击弹出统一操作菜单（预览全文 / 打开所在位置 / 用其他应用打开 / 保存到相册 / 校验和），
 * 校验和不再固定展示，仅在文件有校验和时作为菜单项提供完整值弹窗；不再按文件类型隐式绑定点击行为。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { SessionFile, SessionFileStage } from '../../model/transfer/TransferSession';
import { SessionDetailViewModel } from '../../viewmodel/SessionDetailViewModel';
import { formatSizeDetailed } from '../../utils/FormatUtil';
import { isTextFile } from '../../utils/MimeUtils';
import { isGalleryLocation } from '../../utils/FileLocationUtil';
import { isSaveToGalleryCandidate } from '../../utils/GallerySavePolicy';
import { isTextPreviewable, needsOverLimitHint } from '../../utils/FilePreviewPolicy';
import { FileEntryMenuItems, FileEntryMenuOptions } from '../../components/FileEntryActions';
import { FileEntryThumb } from '../../components/FileEntryThumb';
import { sessionFileStageBgColor, sessionFileStageColor, sessionFileStageLabel } from './SessionStatusBadge';

/** 首屏之后预加载缩略图的行数与错峰间隔：滚动时缩略图已就绪，不再逐张冒出 */
const THUMB_PRELOAD_ROWS: number = 12;
const THUMB_PRELOAD_STEP_MS: number = 90;

/**
 * 条目首行最小行高：与发送页暂存列表的 48vp 行高一致。
 * 缩略图、文件名（最多两行）、大小与状态列在该高度内垂直居中，单行与两行文件名首行保持等高。
 */
const ENTRY_FIRST_ROW_MIN_HEIGHT: number = 48;

@ComponentV2
export struct SessionFileList {
  // 可观测视图模型：渲染中直接读取实时文件清单（实时态与历史态同一入口）
  @Require @Param viewModel: SessionDetailViewModel
  // 条目操作菜单的执行回调（由详情页消费：全文预览 / 打开所在位置 / 用其他应用打开 / 复制文本）
  @Event onPreviewFile: (file: SessionFile) => void = (_file: SessionFile) => {
  }
  @Event onOpenLocation: (file: SessionFile) => void = (_file: SessionFile) => {
  }
  @Event onOpenWithApp: (file: SessionFile) => void = (_file: SessionFile) => {
  }
  @Event onCopyText: (file: SessionFile) => void = (_file: SessionFile) => {
  }
  // 保存到相册（仅接收方向的图片 / 视频条目提供）
  @Event onSaveToGallery: (file: SessionFile) => void = (_file: SessionFile) => {
  }
  // 查看校验和（由详情页统一弹出完整值弹窗，与页内其它弹窗同一层管理）
  @Event onShowChecksum: (file: SessionFile) => void = (_file: SessionFile) => {
  }

  private percentOf(file: SessionFile): number {
    if (file.totalBytes <= 0) {
      return 0;
    }
    let pct: number = (file.bytesSent * 100) / file.totalBytes;
    return pct > 100 ? 100 : pct;
  }

  /** 条目操作菜单选项：由「类型 + 定位 + 来源 + 大小」判定三项可用性，并给出超限说明。 */
  private menuOptionsFor(file: SessionFile): FileEntryMenuOptions {
    let isText: boolean = isTextFile(file.fileType, file.fileName);
    let hasLocation: boolean = file.path.length > 0;
    // 应用私有文本（沙箱落盘）无文件管理器可导航目录，「打开所在位置」置灰
    // （「用其他应用打开」走应用文件分享机制，不受影响；预览与复制不受影响）
    let sandboxText: boolean = this.viewModel.isSandboxTextFile(file);
    // 超阈值同样可截断预览（前 128KB 并挂截断说明），故预览可用性覆盖超限情形
    let overLimit: boolean = needsOverLimitHint(isText, file.path, file.totalBytes);
    // 保存到相册只对接收方向已落盘的媒体文件提供：发送方向的文件可能是用户自己的图库或
    // DCIM 文件，保存语义弱且易产生重复副本；未完成文件不提供，避免保存不完整内容
    let saveCandidate: boolean = !this.viewModel.isOutbound() &&
      file.stage === SessionFileStage.completed &&
      isSaveToGalleryCandidate(file.path, file.fileType, file.fileName);
    let savedToGallery: boolean = saveCandidate && this.viewModel.isSavedToGallery(file);
    return {
      showPreviewItem: isText,
      canPreviewText: isTextPreviewable(isText, file.path, file.totalBytes) || overLimit,
      // 图库来源条目（媒体库图片 / 视频标识）与应用私有文本均无文件管理器可导航目录，该项置灰；
      // 「用其他应用打开」走应用文件分享机制，沙箱自有文件属可分享目录，不受影响
      canOpenLocation: hasLocation && !isGalleryLocation(file.path) && !sandboxText,
      canOpenWithApp: hasLocation,
      // 复制为用户显式动作，不受预览阈值限制：超大文本同样可复制（读取上限截断，超限明确提示截断）
      showCopyItem: isText,
      canCopyText: isText && hasLocation,
      showSaveToGallery: saveCandidate,
      canSaveToGallery: saveCandidate && !savedToGallery,
      onPreviewText: (): void => {
        this.onPreviewFile(file);
      },
      onOpenLocation: (): void => {
        this.onOpenLocation(file);
      },
      onOpenWithApp: (): void => {
        this.onOpenWithApp(file);
      },
      onCopyText: (): void => {
        this.onCopyText(file);
      },
      onSaveToGallery: (): void => {
        this.onSaveToGallery(file);
      },
      // 校验和只在文件确有值时提供菜单项，不再占据条目内的固定展示位
      showChecksum: file.checksum.length > 0,
      onShowChecksum: (): void => {
        this.onShowChecksum(file);
      }
    };
  }

  /** 条目操作菜单：容器在本组件内包一层，菜单项集合由公共实现提供。 */
  @Builder
  entryMenu(file: SessionFile) {
    Menu() {
      FileEntryMenuItems(this.menuOptionsFor(file))
    }
  }

  /**
   * 条目缩略图定位：文件已落盘用其自身路径；尚未落盘（接收确认阶段）时，首条图片条目
   * 以发送端提供的预览图顶替——协议只提供一张缩略图，故只用于首条图片条目。
   */
  private thumbPathOf(ri: RepeatItem<SessionFile>): string {
    if (ri.item.path.length > 0 || ri.index !== 0 ||
      !ri.item.fileType.startsWith('image/')) {
      return '';
    }
    return this.viewModel.peerPreviewPath();
  }

  build() {
    Column() {
      Repeat(this.viewModel.detailFilesForDisplay())
        .each((ri: RepeatItem<SessionFile>) => {
          Column() {
            // 相邻条目之间的分隔线（首条不加；粗细与卡片边框一致）
            if (ri.index > 0) {
              Divider()
                .color($r('app.color.border_light'))
                .strokeWidth(DesignTokens.component.borderSlim)
                .margin({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
            }

            // 首行：缩略图 + 文件名 + 大小 / 状态列，内容整体在固定行高内垂直居中
            Row({ space: DesignTokens.space.sm }) {
              // 左侧类型图标 / 图片与视频缩略区（按需懒加载，失败回退类型图标）
              FileEntryThumb({
                path: ri.item.path.length > 0 ? ri.item.path : this.thumbPathOf(ri),
                // 首屏后若干行错峰预加载：滚动到时缩略图已就绪（其余行仍按可视区加载）
                preloadDelay: ri.index < THUMB_PRELOAD_ROWS ? ri.index * THUMB_PRELOAD_STEP_MS : -1,
                fileType: ri.item.fileType,
                fileName: ri.item.fileName
              })

              // 详情页以完整辨识文件为目标：文件名最多两行，超出省略；
              // 无空格长串按字符断行，避免整段被挤出可视区
              Text(ri.item.fileName)
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .wordBreak(WordBreak.BREAK_ALL)
                .layoutWeight(1)

              // 大小与状态列：同列右对齐，整体垂直居中（不要求与文件名首行对齐）
              Column({ space: DesignTokens.space.tiny }) {
                Text(formatSizeDetailed(ri.item.totalBytes))
                  .fontSize(DesignTokens.font.bodyS)
                  .fontColor($r('app.color.text_tertiary'))
                Text(sessionFileStageLabel(ri.item.stage))
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor(sessionFileStageColor(ri.item.stage))
                  .backgroundColor(sessionFileStageBgColor(ri.item.stage))
                  .padding({
                    left: DesignTokens.space.tiny,
                    right: DesignTokens.space.tiny,
                    top: DesignTokens.space.mini,
                    bottom: DesignTokens.space.mini
                  })
                  .borderRadius(DesignTokens.radius.sm)
              }
              .alignItems(HorizontalAlign.End)
            }
            .width('100%')
            .constraintSize({ minHeight: ENTRY_FIRST_ROW_MIN_HEIGHT })
            .alignItems(VerticalAlign.Center)

            // 传输进度：通栏展示，左右边缘与卡片内容区一致；无字节进度时不渲染
            if (this.viewModel.hasByteProgress()) {
              Row({ space: DesignTokens.space.sm }) {
                Progress({ value: this.percentOf(ri.item), total: 100, type: ProgressType.Linear })
                  .width('100%')
                  .height(DesignTokens.size.progressBarHeight)
                  .color($r('app.color.accent_blue'))
                  .backgroundColor($r('app.color.border_light'))
                  .layoutWeight(1)
                Text(Math.round(this.percentOf(ri.item)) + '%')
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_secondary'))
                  .width(DesignTokens.space.xl + 8)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .margin({ top: DesignTokens.space.xxs })
              .alignItems(VerticalAlign.Center)
            }
          }
          .width('100%')
          // 条目点击弹出统一操作菜单（不再按文件类型隐式绑定点击行为）
          .bindMenu(this.entryMenu(ri.item))
          .id('session_detail_file_item')
        })
        .key((item: SessionFile) => item.fileId + '#' + item.occurrence)

      // 「加载更多」：大文件数会话不再一次性建出全部行，只按需追加，
      // 控制建行与图片解码的瞬时开销（数百行全建会造成长时间卡顿与内存压力）
      if (this.viewModel.hasMoreDetailFiles()) {
        Row() {
          Text($r('app.string.session_detail_load_more', this.viewModel.remainingDetailFiles()))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.accent_blue'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .onClick(() => {
          this.viewModel.loadMoreDetailFiles();
        })
        .id('session_detail_load_more')
      }
    }
    .width('100%')
    .id('session_detail_file_list')
  }
}
