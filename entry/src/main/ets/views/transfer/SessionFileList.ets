/**
 * SessionFileList.ets — 详情页文件清单
 *
 * 逐文件条目：左侧类型图标 / 图片与视频缩略区 + 文件名 + 大小 + 独立进度条 + 百分比 + 状态徽标；
 * 校验和可得时以公共单行值行展示（单行中间省略、点击弹窗、长按复制）。
 * 条目直接排布于外层文件卡片容器内（不套独立色块），相邻条目之间以分隔线区隔。
 * 直接读取可观测视图模型的实时清单（进度 / 阶段随 `@Trace` 字段刷新）。
 * 无字节进度的会话（如单条文本消息的仅预览送达）不渲染进度条与百分比，仅列文件与状态。
 * 条目点击弹出统一操作菜单（预览全文 / 打开所在位置 / 用其他应用打开），
 * 不再按文件类型隐式绑定点击行为。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { SessionFile } from '../../model/transfer/TransferSession';
import { SessionDetailViewModel } from '../../viewmodel/SessionDetailViewModel';
import { formatSizeDetailed } from '../../utils/FormatUtil';
import { isTextFile } from '../../utils/MimeUtils';
import { isTextPreviewable, needsOverLimitHint } from '../../utils/FilePreviewPolicy';
import { FileEntryMenuItems, FileEntryMenuOptions } from '../../components/FileEntryActions';
import { FileEntryThumb } from '../../components/FileEntryThumb';
import { SingleLineValueRow } from '../../components/SingleLineValueRow';
import { sessionFileStageBgColor, sessionFileStageColor, sessionFileStageLabel } from './SessionStatusBadge';

@ComponentV2
export struct SessionFileList {
  // 可观测视图模型：渲染中直接读取实时文件清单（实时态与历史态同一入口）
  @Require @Param viewModel: SessionDetailViewModel
  // 条目操作菜单的执行回调（由详情页消费：全文预览 / 打开所在位置 / 用其他应用打开）
  @Event onPreviewFile: (file: SessionFile) => void = (_file: SessionFile) => {
  }
  @Event onOpenLocation: (file: SessionFile) => void = (_file: SessionFile) => {
  }
  @Event onOpenWithApp: (file: SessionFile) => void = (_file: SessionFile) => {
  }

  private percentOf(file: SessionFile): number {
    if (file.totalBytes <= 0) {
      return 0;
    }
    let pct: number = (file.bytesSent * 100) / file.totalBytes;
    return pct > 100 ? 100 : pct;
  }

  /** 条目操作菜单选项：由「类型 + 定位 + 大小」判定三项可用性，并给出超限说明。 */
  private menuOptionsFor(file: SessionFile): FileEntryMenuOptions {
    let isText: boolean = isTextFile(file.fileType, file.fileName);
    let hasLocation: boolean = file.path.length > 0;
    return {
      showPreviewItem: isText,
      canPreviewText: isTextPreviewable(isText, file.path, file.totalBytes),
      canOpenLocation: hasLocation,
      canOpenWithApp: hasLocation,
      overLimitHint: needsOverLimitHint(isText, file.path, file.totalBytes),
      onPreviewText: (): void => {
        this.onPreviewFile(file);
      },
      onOpenLocation: (): void => {
        this.onOpenLocation(file);
      },
      onOpenWithApp: (): void => {
        this.onOpenWithApp(file);
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
      Repeat(this.viewModel.detailFiles())
        .each((ri: RepeatItem<SessionFile>) => {
          Column() {
            // 相邻条目之间的分隔线（首条不加；粗细与卡片边框一致）
            if (ri.index > 0) {
              Divider()
                .color($r('app.color.border_light'))
                .strokeWidth(DesignTokens.component.borderSlim)
                .margin({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
            }

            Row({ space: DesignTokens.space.sm }) {
              // 左侧类型图标 / 图片与视频缩略区（按需懒加载，失败回退类型图标）
              FileEntryThumb({
                path: ri.item.path.length > 0 ? ri.item.path : this.thumbPathOf(ri),
                fileType: ri.item.fileType,
                fileName: ri.item.fileName
              })

              Column() {
                Row() {
                  Text(ri.item.fileName)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text(formatSizeDetailed(ri.item.totalBytes))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ left: DesignTokens.space.sm })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                Row({ space: DesignTokens.space.sm }) {
                  if (this.viewModel.hasByteProgress()) {
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
                  } else {
                    Blank()
                  }

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
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .margin({ top: DesignTokens.space.tiny })

                // 校验和：协议 / 链路提供时以公共单行值行展示（单行中间省略、点击弹窗、长按复制）；不可得不渲染该行
                SingleLineValueRow({
                  label: $r('app.string.session_detail_checksum_label'),
                  value: ri.item.checksum,
                  valueAlignEnd: false
                })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }
          .width('100%')
          // 条目点击弹出统一操作菜单（不再按文件类型隐式绑定点击行为）
          .bindMenu(this.entryMenu(ri.item))
          .id('session_detail_file_item')
        })
        .key((item: SessionFile) => item.fileId + '#' + item.occurrence)
    }
    .width('100%')
    .id('session_detail_file_list')
  }
}
