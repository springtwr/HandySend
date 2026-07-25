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
        .fontColor('#182431')
        .margin({ bottom: 16 })

      TextArea({ placeholder: $r('app.string.send_text_input_placeholder'), text: this.inputText })
        .width('100%')
        .height(160)
        .backgroundColor('#F2F3F5')
        .borderRadius(8)
        .padding(12)
        .onChange((value: string) => {
          this.inputText = value;
        })

      Row({ space: 12 }) {
        Button($r('app.string.dialog_cancel'))
          .layoutWeight(1)
          .backgroundColor('#F2F3F5')
          .fontColor('#666666')
          .borderRadius(8)
          .onClick(() => {
            if (this.onCancel !== undefined) {
              this.onCancel();
            }
            this.controller?.close();
          })

        Button($r('app.string.dialog_confirm'))
          .layoutWeight(1)
          .backgroundColor('#007DFF')
          .fontColor('#FFFFFF')
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
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
  }
}
