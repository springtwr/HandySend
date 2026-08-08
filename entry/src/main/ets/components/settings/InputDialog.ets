@CustomDialog
export struct InputDialog {
  controller?: CustomDialogController
  title: ResourceStr = ''
  placeholder: ResourceStr = ''
  initialValue: string = ''
  confirmText: ResourceStr = $r('app.string.dialog_confirm')
  cancelText: ResourceStr = $r('app.string.dialog_cancel')
  onConfirm?: (value: string) => void
  onCancel?: () => void

  @State inputValue: string = ''

  aboutToAppear(): void {
    this.inputValue = this.initialValue;
  }

  build() {
    Column() {
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 16 })

      TextInput({ placeholder: this.placeholder, text: this.inputValue })
        .width('100%')
        .height(44)
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(8)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.inputValue = value;
        })

      Row({ space: 12 }) {
        Button(this.cancelText)
          .layoutWeight(1)
          .backgroundColor($r('app.color.input_bg'))
          .fontColor($r('app.color.text_tertiary'))
          .borderRadius(8)
          .onClick(() => {
            if (this.onCancel !== undefined) {
              this.onCancel();
            }
          })

        Button(this.confirmText)
          .layoutWeight(1)
          .backgroundColor($r('app.color.accent_blue'))
          .fontColor($r('app.color.text_on_color'))
          .borderRadius(8)
          .onClick(() => {
            if (this.onConfirm !== undefined) {
              this.onConfirm(this.inputValue);
            }
          })
      }
      .width('100%')
      .margin({ top: 20 })
    }
    .padding(24)
    .width('100%')
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(16)
  }
}
