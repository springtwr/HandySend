@CustomDialog
export struct InputDialog {
  controller?: CustomDialogController
  title: string = ''
  placeholder: string = ''
  initialValue: string = ''
  confirmText: string = '确定'
  cancelText: string = '取消'
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
        .fontColor('#182431')
        .margin({ bottom: 16 })

      TextInput({ placeholder: this.placeholder, text: this.inputValue })
        .width('100%')
        .height(44)
        .backgroundColor('#F2F3F5')
        .borderRadius(8)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.inputValue = value;
        })

      Row({ space: 12 }) {
        Button(this.cancelText)
          .layoutWeight(1)
          .backgroundColor('#F2F3F5')
          .fontColor('#666666')
          .borderRadius(8)
          .onClick(() => {
            if (this.onCancel !== undefined) {
              this.onCancel();
            }
          })

        Button(this.confirmText)
          .layoutWeight(1)
          .backgroundColor('#007DFF')
          .fontColor('#FFFFFF')
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
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
  }
}
