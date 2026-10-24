import { DesignTokens } from '../../common/DesignTokens';
import { SettingsViewModel } from '../../viewmodel/SettingsViewModel';

/**
 * WebSettingsSection.ets — 浏览器传输设置分组：总开关。
 *
 * 浏览器传输服务与 LocalSend/MTA 同级，有独立总开关；加密传输等链路配置
 * 沿用全局设置（HTTPS 跟随全局加密传输开关），此处不再重复。
 * 数据经 @Param 绑定父组件 VM，命令直调 VM（View → ViewModel）。
 */
@ComponentV2
export struct WebSettingsSection {
  @Require @Param viewModel: SettingsViewModel

  build() {
    Column() {
      // 卡片（标题由设置分组统一渲染）
      Column() {
        // 网页总开关（卡片首行）：关闭时停用网页发送/接收入口（进行中传输先确认）
        Row() {
          Text($r('app.string.web_enabled_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.viewModel.webEnabled })
            .onChange((isOn: boolean) => {
              this.viewModel.setWebEnabledValue(isOn);
            })
            .id('settings_web_enabled_toggle')
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.web_enabled_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })
      }
      .width('100%')
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    }
    .width('100%')
  }
}
