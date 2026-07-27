@CustomDialog
export struct TextSendDialog {
  controller?: CustomDialogController
  onConfirm?: (text: string) => void
  onCancel?: () => void

  @State inputText: string = ''

  build() {
    Column() {
      Text($r('app.string.send_text_input_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 16 })

      TextArea({ placeholder: $r('app.string.send_text_input_placeholder'), text: this.inputText })
        .width('100%')
        .height(160)
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(8)
        .padding(12)
        .onChange((value: string) => {
          this.inputText = value;
        })

      Row({ space: 12 }) {
        Button($r('app.string.dialog_cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.input_bg'))
          .fontColor($r('app.color.text_tertiary'))
          .borderRadius(8)
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
          .borderRadius(8)
          .onClick(() => {
            if (this.onConfirm !== undefined) {
              this.onConfirm(this.inputText);
            }
            this.controller?.close();
          })
      }
      .width('100%')
      .margin({ top: 20 })
    }
    .padding(24)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(16)
  }
}
