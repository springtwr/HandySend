import { DesignTokens } from '../common/DesignTokens';
import { TransferViewModel, TransferState } from '../viewmodel/TransferViewModel';

// 传输完成/失败状态视图（从 TransferPage build 中拆出）。
// 数据经 @Param 绑定父组件 VM。
@ComponentV2
export struct TransferProgressView {
  @Require @Param viewModel: TransferViewModel

  build() {
    Column() {
      // 总进度以 TransferFileList 的逐文件进度列表呈现，
      // 此处仅处理完成/失败状态分支。
      if (this.viewModel.transferState === TransferState.Completed) {
        Text($r('app.string.transfer_complete'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.success_green'))
          .margin({ top: DesignTokens.space.mini })
          .id('transfer_complete')
      } else if (this.viewModel.transferState === TransferState.Failed) {
        Column() {
          if (this.viewModel.errorMessage.length > 0) {
            Text(this.viewModel.errorMessage)
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.danger_red'))
              .id('transfer_error_message')
          } else {
            Text($r('app.string.transfer_failed'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.danger_red'))
              .id('transfer_failed_text')
          }
        }
        .margin({ top: DesignTokens.space.mini })
      }
    }
    .alignItems(HorizontalAlign.Center)
    .margin({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.mini })
  }
}
