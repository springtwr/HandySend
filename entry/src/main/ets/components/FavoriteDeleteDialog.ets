import { DesignTokens } from '../common/DesignTokens';

@CustomDialog
export struct FavoriteDeleteDialog {
  controller?: CustomDialogController
  deviceAlias: string = ''
  onConfirm?: () => void
  onCancel?: () => void

  build() {
    Column() {
      Text($r('app.string.delete_favorite_title'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: DesignTokens.space.md })

      Text($r('app.string.delete_favorite_confirm'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: DesignTokens.space.mini })

      Text(this.deviceAlias)
        .fontSize(DesignTokens.font.subtitleM)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: DesignTokens.space.md })

      Row({ space: DesignTokens.space.sm }) {
        Button($r('app.string.dialog_cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.input_bg'))
          .fontColor($r('app.color.text_tertiary'))
          .borderRadius(DesignTokens.radius.md)
          .onClick(() => {
            if (this.onCancel !== undefined) {
              this.onCancel();
            }
            this.controller?.close();
          })

        Button($r('app.string.dialog_delete'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.danger_red'))
          .fontColor($r('app.color.text_on_color'))
          .borderRadius(DesignTokens.radius.md)
          .onClick(() => {
            if (this.onConfirm !== undefined) {
              this.onConfirm();
            }
            this.controller?.close();
          })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.lg })
    }
    .padding(DesignTokens.space.lg)
    .constraintSize({ maxWidth: '85%' })
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
  }
}
