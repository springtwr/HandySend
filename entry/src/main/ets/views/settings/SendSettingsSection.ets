import {
  DesignTokens
} from '../../common/DesignTokens';
import {
  SettingsViewModel
} from '../../viewmodel/SettingsViewModel';

// 发送设置分组（自动确认下载请求/创建校验和，从接收卡片与网络高级设置迁出）。
// 数据经 @Param 绑定父组件 VM，命令直调 VM（View → ViewModel）。
@ComponentV2
export struct SendSettingsSection {
  @Require @Param viewModel: SettingsViewModel

  build() {
    Column() {
      Text($r('app.string.send_settings'))
        .fontSize(DesignTokens.font.subtitleM)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .alignSelf(ItemAlign.Start)

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
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
      .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.auto_accept_download_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: DesignTokens.space.xs })

      // 创建校验和（创建与校验联动，单一开关）
      Row() {
        Text($r('app.string.create_checksums_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.createChecksums })
          .onChange((isOn: boolean) => {
            this.viewModel.setChecksumsEnabled(isOn);
          })
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
      .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.checksum_create_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: DesignTokens.space.xs })
    }
    .width('100%')
    .padding(DesignTokens.space.lg)
    .borderRadius(DesignTokens.radius.lg)
    .backgroundColor($r('app.color.card_background'))
    .border({ width: 1, color: $r('app.color.border_light') })
    .margin({ top: DesignTokens.space.md })
  }
}
