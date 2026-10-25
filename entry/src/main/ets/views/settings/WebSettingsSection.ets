import { DesignTokens } from '../../common/DesignTokens';
import { SettingsViewModel } from '../../viewmodel/SettingsViewModel';

/**
 * WebSettingsSection.ets — 网页传输设置分组：发送 / 接收两个允许开关。
 *
 * 两方向可单独开关（与面板内停止/开启按钮、发送页菜单勾选双向同步）；
 * 加密传输等链路配置沿用全局设置（HTTPS 跟随全局加密传输开关），此处不再重复。
 * 数据经 @Param 绑定父组件 VM，命令直调 VM（View → ViewModel）。
 */
@ComponentV2
export struct WebSettingsSection {
  @Require @Param viewModel: SettingsViewModel

  build() {
    Column() {
      // 卡片（标题由设置分组统一渲染）
      Column() {
        // 网页发送允许开关：关闭时撤下已挂载的分享文件（进行中下载先确认）
        Row() {
          Text($r('app.string.web_send_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.viewModel.webSendAllowed })
            .onChange((isOn: boolean) => {
              this.viewModel.setWebSendAllowedValue(isOn);
            })
            .id('settings_web_send_toggle')
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.web_send_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })

        // 网页接收允许开关：关闭时关闭浏览器上传入口（进行中上传先确认）
        Row() {
          Text($r('app.string.web_receive_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.viewModel.webReceiveAllowed })
            .onChange((isOn: boolean) => {
              this.viewModel.setWebReceiveAllowedValue(isOn);
            })
            .id('settings_web_receive_toggle')
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.web_receive_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })
      }
      .width('100%')
      .padding({
        left: DesignTokens.space.lg,
        right: DesignTokens.space.lg,
        top: DesignTokens.space.md,
        bottom: DesignTokens.space.md
      })
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      .margin({ top: DesignTokens.space.sm })
    }
    .width('100%')
  }
}
