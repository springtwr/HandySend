import { DesignTokens } from '../common/DesignTokens';

@CustomDialog
export struct PinDialog {
  controller?: CustomDialogController
  onConfirm?: (pin: string) => void
  onCancel?: () => void
  title?: ResourceStr
  errorHint?: ResourceStr
  @State pinInput: string = ''
  @State errorMessage: string = ''
  @StorageLink('receivePin') receivePin: string = ''

  build() {
    Column() {
      Text(this.title !== undefined ? this.title : $r('app.string.pin_dialog_title'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: DesignTokens.space.md })

      if (this.errorHint !== undefined && this.errorHint !== '') {
        Text(this.errorHint)
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.danger_red'))
          .margin({ bottom: DesignTokens.space.xs })
      }

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.danger_red'))
          .margin({ bottom: DesignTokens.space.xs })
      }

      TextInput({ placeholder: $r('app.string.pin_dialog_placeholder'), text: this.pinInput })
        .width('100%')
        .height(44)
        .type(InputType.Number)
        .maxLength(8)
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(DesignTokens.radius.md)
        .padding({ left: DesignTokens.space.sm, right: DesignTokens.space.sm })
        .onChange((value: string) => {
          this.pinInput = value;
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
              this.onConfirm(this.pinInput);
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
