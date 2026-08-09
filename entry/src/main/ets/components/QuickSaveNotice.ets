import { DesignTokens } from '../common/DesignTokens';

@CustomDialog
export struct QuickSaveNotice {
  controller?: CustomDialogController
  onConfirm?: () => void

  build() {
    Column() {
      Text($r('app.string.quicksave_notice_title'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: DesignTokens.space.sm })

      Text($r('app.string.quicksave_notice_message'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(22)
        .margin({ bottom: DesignTokens.space.lg })

      Button($r('app.string.dialog_confirm'))
        .width('100%')
        .backgroundColor($r('app.color.accent_blue'))
        .fontColor($r('app.color.text_on_color'))
        .borderRadius(DesignTokens.radius.md)
        .onClick(() => {
          if (this.onConfirm !== undefined) {
            this.onConfirm();
          }
          this.controller?.close();
        })
    }
    .padding(DesignTokens.space.lg)
    .constraintSize({ maxWidth: '85%' })
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
  }
}
