/**
 * SessionFileList.ets — 详情页文件清单
 *
 * 逐文件条目：文件名 + 大小 + 独立进度条 + 百分比 + 状态徽标。
 * 条目直接排布于外层文件卡片容器内（不再套独立的条目色块），
 * 相邻条目之间以分隔线区隔，避免多套一层容器压缩左右可用宽度。
 * 无字节进度的会话（如单条文本消息的仅预览送达）不渲染进度条与百分比，
 * 仅列文件与状态，避免误导性的 0%。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { SessionFile } from '../../model/transfer/TransferSession';
import { formatSizeDetailed } from '../../utils/FormatUtil';
import { isTextFile } from '../../utils/MimeUtils';
import { sessionFileStageBgColor, sessionFileStageColor, sessionFileStageLabel } from './SessionStatusBadge';

@ComponentV2
export struct SessionFileList {
  @Require @Param files: Array<SessionFile>
  // 是否展示字节进度（无字节进度协议的会话只列文件与状态，不渲染误导性的 0% 进度条）
  @Param showByteProgress: boolean = true
  // 文本类条目的「点击预览」入口回调（多文件时由详情页消费）
  @Event onPreviewFile: (file: SessionFile) => void = (_file: SessionFile) => {
  }

  private percentOf(file: SessionFile): number {
    if (file.totalBytes <= 0) {
      return 0;
    }
    let pct: number = (file.bytesSent * 100) / file.totalBytes;
    return pct > 100 ? 100 : pct;
  }

  build() {
    Column() {
      Repeat(this.files)
        .each((ri: RepeatItem<SessionFile>) => {
          Column() {
            // 相邻条目之间的分隔线（首条不加；粗细与卡片边框一致）
            if (ri.index > 0) {
              Divider()
                .color($r('app.color.border_light'))
                .strokeWidth(DesignTokens.component.borderSlim)
                .margin({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
            }

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
              // 文本类条目：提供「预览」入口（点击即查看全文；多文件时不内联，避免清单臃肿）
              if (isTextFile(ri.item.fileType, ri.item.fileName)) {
                Text($r('app.string.session_file_preview'))
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.accent_blue'))
                  .margin({ left: DesignTokens.space.sm })
                  .onClick(() => {
                    this.onPreviewFile(ri.item);
                  })
                  .id('session_detail_file_preview')
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Row({ space: DesignTokens.space.sm }) {
              if (this.showByteProgress) {
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

            // 校验和：协议/链路提供时展示，不可得不显示该行
            if (ri.item.checksum.length > 0) {
              Row({ space: DesignTokens.space.tiny }) {
                Text($r('app.string.session_detail_checksum_label'))
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_tertiary'))
                Text(ri.item.checksum)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_secondary'))
                  .wordBreak(WordBreak.BREAK_ALL)
                  .layoutWeight(1)
              }
              .width('100%')
              .margin({ top: DesignTokens.space.mini })
              .alignItems(VerticalAlign.Center)
            }
          }
          .width('100%')
          .id('session_detail_file_item')
        })
        .key((item: SessionFile) => item.fileId + '#' + item.occurrence)
    }
    .width('100%')
    .id('session_detail_file_list')
  }
}
