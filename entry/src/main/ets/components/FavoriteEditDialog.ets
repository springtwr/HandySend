import { DesignTokens } from '../common/DesignTokens';

@CustomDialog
export struct FavoriteEditDialog {
  controller?: CustomDialogController
  deviceAlias: string = ''
  deviceFingerprint: string = ''
  onConfirm?: (newAlias: string) => void
  onCancel?: () => void
  @State editAlias: string = ''

  aboutToAppear(): void {
    this.editAlias = this.deviceAlias;
  }

  build() {
    Column() {
      Text($r('app.string.edit_favorite_title'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: DesignTokens.space.md })

      Text($r('app.string.current_alias_label') + this.deviceAlias)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: DesignTokens.space.xs })

      TextInput({ placeholder: $r('app.string.custom_alias_placeholder'), text: this.editAlias })
        .width('100%')
        .height(44)
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(DesignTokens.radius.md)
        .padding({ left: DesignTokens.space.sm, right: DesignTokens.space.sm })
        .onChange((value: string) => {
          this.editAlias = value;
        })

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

        Button($r('app.string.dialog_confirm'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.accent_blue'))
          .fontColor($r('app.color.text_on_color'))
          .borderRadius(DesignTokens.radius.md)
          .onClick(() => {
            if (this.onConfirm !== undefined) {
              this.onConfirm(this.editAlias);
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
