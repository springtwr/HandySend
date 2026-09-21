/**
 * SessionActions.ets — 详情页底部动作区
 *
 * 同一时刻只呈现一组动作，不堆叠多行：
 * - 待确认文件会话：两键「拒绝」+「确认」
 * - 待确认文本消息会话：两键「关闭」+「复制」（关闭＝直接接受，复制＝写剪贴板后接受）
 * - 进行中：单键「取消传输」（红色，约 60% 宽）
 * - 终态：不渲染按钮（返回由系统手势与标题栏承担，不占用底部动作位）。
 * 指纹验证与保存到相册不在此常驻，分别经详情页标题栏菜单与弹窗入口提供。
 */

import { DesignTokens } from '../../common/DesignTokens';

@ComponentV2
export struct SessionActions {
  @Param canConfirm: boolean = false
  @Param canDecline: boolean = false
  @Param canCancel: boolean = false
  // 文本消息会话：动作为「关闭」+「复制」
  @Param isTextSession: boolean = false
  @Event onConfirm: () => void = () => {
  }
  @Event onDecline: () => void = () => {
  }
  @Event onCancel: () => void = () => {
  }
  @Event onCopyText: () => void = () => {
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

  /** 待确认：确认键（主样式）。 */
  @Builder
  confirmButton() {
    Button() {
      Row({ space: DesignTokens.space.tiny }) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontColor([$r('app.color.text_on_color')])
        Text($r('app.string.session_detail_confirm'))
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
      this.onConfirm();
    })
    .id('session_detail_positive_btn')
  }

  /** 文本消息：关闭键（次要样式，中性描边；直接按接受收尾）。 */
  @Builder
  closeButton() {
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
      color: $r('app.color.border_light'),
      style: BorderStyle.Solid
    })
    .borderRadius(DesignTokens.radius.max)
    .onClick(() => {
      this.onConfirm();
    })
    .id('session_detail_close_btn')
  }

  /** 文本消息：复制键（主样式；写剪贴板成功后按接受收尾）。 */
  @Builder
  copyButton() {
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
      this.onCopyText();
    })
    .id('session_detail_copy_btn')
  }

  build() {
    Column() {
      if (this.isTextSession) {
        // ── 待确认文本消息：两键「关闭」+「复制」 ──
        Row({ space: DesignTokens.space.md }) {
          this.closeButton()
          this.copyButton()
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.canDecline || this.canConfirm) {
        // ── 待确认文件会话：两键「拒绝」+「确认」 ──
        Row({ space: DesignTokens.space.md }) {
          if (this.canDecline) {
            this.declineButton()
          }
          if (this.canConfirm) {
            this.confirmButton()
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
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .id('session_detail_actions')
  }
}
