/**
 * SettingsPendingChip.ets — 壳层设置待生效提示
 *
 * 提供“重启服务”动作；存在 LocalSend 传输时不禁用，
 * 点击后先确认 LocalSend 传输将中断，确认后再重启。
 * 排版与发送失败浮卡一致：短标题 + 正文列 + 右侧按钮；
 * 长文案放正文，标题保持一行，避免标题列被按钮挤窄后截断。
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
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.warning_orange'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.aliasOnly ? $r('app.string.nickname_pending_effect') :
          $r('app.string.settings_pending_effect'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (this.busy && !this.restarting) {
          Text($r('app.string.settings_pending_interrupt_hint'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.restarting) {
        LoadingProgress()
          .width(DesignTokens.font.iconInline)
          .height(DesignTokens.font.iconInline)
          .color($r('app.color.accent_blue'))
          .id('settings_pending_restarting')
      } else {
        // 卡片内使用短文案，给标题/正文留出宽度；完整“重启服务”见确认弹窗与设置页状态行
        Button($r('app.string.restart_server_short'))
          .fontSize(DesignTokens.font.bodyS)
          .height(DesignTokens.size.inlineButton)
          .fontColor($r('app.color.text_on_color'))
          .backgroundColor($r('app.color.accent_blue'))
          .borderRadius(DesignTokens.radius.max)
          .onClick(() => {
            this.onRestart();
          })
          .id('settings_pending_restart_btn')
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
    .id('settings_pending_chip')
  }
}
