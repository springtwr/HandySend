import { DesignTokens } from '../../common/DesignTokens';
import { SettingsViewModel } from '../../viewmodel/SettingsViewModel';

// LocalSend 分区的下载请求选项：自动确认下载请求。
// 作为 LocalSend 单卡片的内容片段渲染，不提供卡片容器与外边距。
@ComponentV2
export struct SendSettingsSection {
  @Require @Param viewModel: SettingsViewModel

  build() {
    Column() {
      // 自动确认下载请求（仅 Web 分享下载生效）
      Row() {
        Text($r('app.string.auto_accept_download_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.autoAcceptWebDownload })
          .onChange((isOn: boolean) => {
            this.viewModel.setAutoAcceptWebDownloadEnabled(isOn);
          })
          .id('settings_auto_accept_toggle')
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.auto_accept_download_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: DesignTokens.space.tiny })
    }
    .width('100%')
  }
}
