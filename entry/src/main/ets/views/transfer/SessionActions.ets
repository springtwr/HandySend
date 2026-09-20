/**
 * SessionActions.ets — 详情页底部动作区
 *
 * 对齐旧传输页的动作布局（同一时刻只呈现一组动作，不堆叠多行）：
 * - 待确认：两键「拒绝」+「确认」（文本消息会话以「复制」替代确认）
 * - 进行中：单键「取消传输」（红色，约 60% 宽）
 * - 终态：单键「返回」，发送方向可重试时为「重试」（约 60% 宽）
 * 指纹验证与保存到相册不在此常驻，分别经详情页标题栏菜单与弹窗入口提供。
 */

import { DesignTokens } from '../../common/DesignTokens';

@ComponentV2
export struct SessionActions {
  @Param canConfirm: boolean = false
  @Param canDecline: boolean = false
  @Param canCancel: boolean = false
  @Param canRetry: boolean = false
  // 文本消息会话：正向动作为「复制文本」
  @Param canCopyText: boolean = false
  @Event onConfirm: () => void = () => {
  }
  @Event onDecline: () => void = () => {
  }
  @Event onCancel: () => void = () => {
  }
  @Event onRetry: () => void = () => {
  }
  @Event onCopyText: () => void = () => {
  }
  @Event onBack: () => void = () => {
  }

  /** 待确认：拒绝键（次要样式，红色描边）。 */
  @Builder
  declineButton() {
    Button() {
      Row({ space: DesignTokens.space.tiny }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontColor([$r('app.color.danger_red')])
        Text($r('app.string.session_detail_decline'))
          .fontSize(DesignTokens.font.subtitleM)
          .fontColor($r('app.color.danger_red'))
      }
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .height(DesignTokens.size.thumbSm)
    .backgroundColor($r('app.color.card_background'))
    .border({
      width: DesignTokens.component.borderSlim,
      color: $r('app.color.danger_red'),
      style: BorderStyle.Solid
    })
    .borderRadius(DesignTokens.radius.max)
    .onClick(() => {
      this.onDecline();
    })
    .id('session_detail_decline_btn')
  }

  /** 待确认：正向键（确认 / 文本会话为复制，主样式）。 */
  @Builder
  positiveButton() {
    Button() {
      Row({ space: DesignTokens.space.tiny }) {
        if (!this.canCopyText) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(DesignTokens.font.subtitleL)
            .fontColor([$r('app.color.text_on_color')])
        }
        Text(this.canCopyText ? $r('app.string.copy') : $r('app.string.session_detail_confirm'))
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
      if (this.canCopyText) {
        this.onCopyText();
      } else {
        this.onConfirm();
      }
    })
    .id('session_detail_positive_btn')
  }

  build() {
    Column() {
      if (this.canDecline) {
        // ── 待确认：两键「拒绝」+「确认」/「复制」 ──
        Row({ space: DesignTokens.space.md }) {
          this.declineButton()
          if (this.canCopyText || this.canConfirm) {
            this.positiveButton()
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.canCancel) {
        // ── 进行中：单键「取消传输」（红色，约 60% 宽） ──
        Button() {
          Row({ space: DesignTokens.space.tiny }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor([$r('app.color.text_on_color')])
            Text($r('app.string.session_detail_cancel'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontColor($r('app.color.text_on_color'))
          }
          .justifyContent(FlexAlign.Center)
        }
        .width('60%')
        .height(DesignTokens.size.thumbSm)
        .backgroundColor($r('app.color.danger_red'))
        .borderRadius(DesignTokens.radius.max)
        .onClick(() => {
          this.onCancel();
        })
        .id('session_detail_cancel_btn')
      } else if (this.canRetry) {
        // ── 终态（发送失败可重试）：单键「重试」 ──
        Button($r('app.string.session_detail_retry'))
          .width('60%')
          .height(DesignTokens.size.thumbSm)
          .backgroundColor($r('app.color.accent_blue'))
          .fontColor($r('app.color.text_on_color'))
          .borderRadius(DesignTokens.radius.max)
          .onClick(() => {
            this.onRetry();
          })
          .id('session_detail_retry_btn')
      } else {
        // ── 终态：单键「返回」 ──
        Button($r('app.string.back'))
          .width('60%')
          .height(DesignTokens.size.thumbSm)
          .backgroundColor($r('app.color.accent_blue'))
          .fontColor($r('app.color.text_on_color'))
          .borderRadius(DesignTokens.radius.max)
          .onClick(() => {
            this.onBack();
          })
          .id('session_detail_back_btn')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .id('session_detail_actions')
  }
}
