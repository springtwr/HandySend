/**
 * SettingsPendingChip.ets — 壳层设置待生效提示
 *
 * 仅昵称待生效时显示“重启服务”；多项待生效时只引导去设置，
 * 避免在非设置页直接重启并中断传输。
 */

import { DesignTokens } from '../../common/DesignTokens';

@ComponentV2
export struct SettingsPendingChip {
  @Param aliasOnly: boolean = false
  @Param reasonCount: number = 0
  @Param busy: boolean = false
  @Param restarting: boolean = false
  @Param onRestart: () => void = (): void => {
  }
  @Param onOpenSettings: () => void = (): void => {
  }

  build() {
    Row({ space: DesignTokens.space.sm }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(DesignTokens.font.iconInline)
        .fontColor([$r('app.color.warning_orange')])
        .accessibilityLevel('no')

      Column({ space: DesignTokens.space.mini }) {
        Text(this.aliasOnly ? $r('app.string.nickname_pending_title') :
          $r('app.string.settings_pending_title', this.reasonCount))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.warning_orange'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (this.aliasOnly && this.busy) {
          Text($r('app.string.nickname_pending_busy'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.aliasOnly && !this.busy && this.restarting) {
        LoadingProgress()
          .width(DesignTokens.font.iconInline)
          .height(DesignTokens.font.iconInline)
          .color($r('app.color.accent_blue'))
          .id('settings_pending_restarting')
      } else if (this.aliasOnly && !this.busy) {
        Button($r('app.string.restart_server'))
          .fontSize(DesignTokens.font.bodyS)
          .height(DesignTokens.size.inlineButton)
          .fontColor($r('app.color.text_on_color'))
          .backgroundColor($r('app.color.accent_blue'))
          .borderRadius(DesignTokens.radius.max)
          .onClick(() => {
            this.onRestart();
          })
          .id('settings_pending_restart_btn')
      } else if (!this.aliasOnly) {
        Button($r('app.string.settings_pending_action_settings'))
          .fontSize(DesignTokens.font.bodyS)
          .height(DesignTokens.size.inlineButton)
          .fontColor($r('app.color.text_on_color'))
          .backgroundColor($r('app.color.accent_blue'))
          .borderRadius(DesignTokens.radius.max)
          .onClick(() => {
            this.onOpenSettings();
          })
          .id('settings_pending_open_btn')
      }
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.warning_bg'))
    // 与页面内提示卡一致：使用 16vp 圆角，不做全圆角胶囊
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.warning_orange') })
    .shadow({ radius: 12, color: '#33000000', offsetY: 4 })
    .alignItems(VerticalAlign.Center)
    .accessibilityText(this.aliasOnly ? $r('app.string.nickname_pending_title') :
      $r('app.string.settings_pending_title', this.reasonCount))
    .id('settings_pending_chip')
  }
}
