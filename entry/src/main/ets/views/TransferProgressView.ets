import { DesignTokens } from '../common/DesignTokens';
import { TransferViewModel, TransferState } from '../viewmodel/TransferViewModel';

// 传输进度/完成/失败状态视图（从 TransferPage build 中拆出）。
// 数据经 @Param 绑定父组件 VM；返回/复制经回调上抛（UIContext 边界）。
@ComponentV2
export struct TransferProgressView {
  @Require @Param viewModel: TransferViewModel
  @Event onBack: () => void = () => {
  }
  @Event onCopy: (text: string) => void = (_text: string) => {
  }

  private isUrl(text: string): boolean {
    return /^https?:\/\/\S+/.test(text.trim());
  }

  build() {
    Column() {
      // 单一 Capsule 总进度条已由 TransferFileList 的逐文件进度列表替代，
      // 此处仅保留完成/失败/文本状态分支。
      if (this.viewModel.transferState === TransferState.Completed) {
        if (this.viewModel.isTextMessage) {
          Column() {
            Text($r('app.string.transfer_complete'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.success_green'))
              .margin({ top: DesignTokens.space.mini, bottom: DesignTokens.space.sm })

            Column() {
              Text(this.viewModel.textMessageContent)
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .lineHeight(20)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .maxLines(12)
                .width('100%')
            }
            .width('88%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })

            if (this.isUrl(this.viewModel.textMessageContent)) {
              Text($r('app.string.open_link'))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.accent_blue'))
                .decoration({ type: TextDecorationType.Underline })
                .margin({ top: DesignTokens.space.sm })
                .onClick(() => {
                  this.viewModel.openUrl(this.viewModel.textMessageContent.trim());
                })
            }
          }
          .alignItems(HorizontalAlign.Center)

          Row({ space: DesignTokens.space.md }) {
            Button() {
              Row({ space: DesignTokens.space.tiny }) {
                Text($r('app.string.close'))
                  .fontSize(DesignTokens.font.subtitleM)
                  .fontColor($r('app.color.text_secondary'))
              }
              .justifyContent(FlexAlign.Center)
            }
            .layoutWeight(1)
            .height(DesignTokens.size.thumbSm)
            .backgroundColor($r('app.color.card_background'))
            .border({
              width: DesignTokens.component.borderSlim,
              color: $r('app.color.border_medium'),
              style: BorderStyle.Solid
            })
            .borderRadius(DesignTokens.radius.max)
            .onClick(() => {
              this.onBack();
            })

            Button() {
              Row({ space: DesignTokens.space.tiny }) {
                Text($r('app.string.copy'))
                  .fontSize(DesignTokens.font.subtitleM)
                  .fontColor($r('app.color.text_on_color'))
              }
              .justifyContent(FlexAlign.Center)
            }
            .layoutWeight(1)
            .height(DesignTokens.size.thumbSm)
            .backgroundColor($r('app.color.accent_blue'))
            .borderRadius(DesignTokens.radius.max)
            .onClick(() => {
              this.onCopy(this.viewModel.textMessageContent);
            })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: DesignTokens.space.lg })
        } else {
          Text($r('app.string.transfer_complete'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.success_green'))
            .margin({ top: DesignTokens.space.mini })
        }
      } else if (this.viewModel.transferState === TransferState.Failed) {
        Column() {
          if (this.viewModel.errorMessage.length > 0) {
            Text(this.viewModel.errorMessage)
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.danger_red'))
          } else {
            Text($r('app.string.transfer_failed'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.danger_red'))
          }
        }
        .margin({ top: DesignTokens.space.mini })
      }
    }
    .alignItems(HorizontalAlign.Center)
    .margin({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.mini })
  }
}
