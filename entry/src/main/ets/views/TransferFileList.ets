import { DesignTokens } from '../common/DesignTokens';
import { TransferViewModel, TransferFileProgress, TransferState } from '../viewmodel/TransferViewModel';
import { formatSizeDetailed, formatSpeed, formatDuration } from '../utils/FormatUtil';
import { fileStatusLabel, fileStatusColor, fileStatusBgColor } from '../utils/SessionStatusPresentation';
import { getStringSync } from '../utils/ResourceUtil';

// 传输页文件清单（发送/接收共用）：头部汇总 + 逐文件独立进度条。
// 经 @Param 绑定父组件 VM，数据来自 viewModel.fileProgressList。
@ComponentV2
export struct TransferFileList {
  @Require @Param viewModel: TransferViewModel

  // 单个文件百分比文案（小数字）。

  private percentText(p: TransferFileProgress): string {
    return Math.round(p.percent) + '%';
  }

  // 总体进度文案：标签 + 数字 + 单个 %（避免资源 %% 转义不折叠出现两个百分号）。
  private progressOverallText(): string {
    let label: string = getStringSync(this.getUIContext(), $r('app.string.transfer_progress_overall'));
    if (label.length === 0) {
      return Math.round(this.viewModel.progressPercent) + '%';
    }
    return label + ' ' + Math.round(this.viewModel.progressPercent) + '%';
  }

  // 汇总：文件数 + 总大小（从 fileInfos 累加）。
  private totalSize(): number {
    let total: number = 0;
    for (let i = 0; i < this.viewModel.fileInfos.length; i++) {
      total = total + this.viewModel.fileInfos[i].size;
    }
    return total;
  }

  build() {
    Column() {
      // 头部汇总：文件数 + 总大小 + 总体进度，同一行、同一字号（右侧总进度强调色）。
      Row({ space: DesignTokens.space.sm }) {
        Text($r('app.string.transfer_file_count', this.viewModel.fileInfos.length))
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        if (this.totalSize() > 0) {
          Text(formatSizeDetailed(this.totalSize()))
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
        }
        Blank().layoutWeight(1)
        Text(this.progressOverallText())
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent_blue'))
          .id('transfer_progress_overall')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })

      // 实时速度 + 预计剩余时间（仅传输中显示）
      if (this.viewModel.transferState === TransferState.Transferring) {
        Row({ space: DesignTokens.space.md }) {
          Blank().layoutWeight(1)
          Text(formatSpeed(this.viewModel.displaySpeed))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
          Text($r('app.string.transfer_eta_label'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_tertiary'))
          Text(formatDuration(this.viewModel.displayEta))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: DesignTokens.space.tiny })
      }

      // 逐文件进度列表（撑满剩余空间，文件较多时内部滚动）
      Scroll() {
        Column() {
          Repeat(this.viewModel.fileProgressList).each((ri: RepeatItem<TransferFileProgress>) => {
            Column() {
              Row() {
                Text(ri.item.fileName)
                  .fontSize(DesignTokens.font.bodyM)
                  .fontColor($r('app.color.text_primary'))
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .maxLines(1)
                  .layoutWeight(1)
                Text(formatSizeDetailed(ri.item.size))
                  .fontSize(DesignTokens.font.bodyS)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ left: DesignTokens.space.sm })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Row({ space: DesignTokens.space.sm }) {
                Progress({ value: ri.item.percent, total: 100, type: ProgressType.Linear })
                  .width('100%')
                  .height(4)
                  .color($r('app.color.accent_blue'))
                  .backgroundColor($r('app.color.border_light'))
                  .layoutWeight(1)
                Text(this.percentText(ri.item))
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_secondary'))
                  .width(DesignTokens.space.xl + 8)
                  .textAlign(TextAlign.End)

                Text(fileStatusLabel(ri.item.status))
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor(fileStatusColor(ri.item.status))
                  .backgroundColor(fileStatusBgColor(ri.item.status))
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
            }
            .width('100%')
            .padding(DesignTokens.space.sm)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.md)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
            .margin({ top: DesignTokens.space.tiny })
            .id('transfer_file_item')
          }).key((item: TransferFileProgress) =>
          item.fileId + '_' + Math.round(item.percent) + '_' + item.status)
        }
        .width('100%')
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
      .align(Alignment.Top)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .id('transfer_file_list')
  }
}
