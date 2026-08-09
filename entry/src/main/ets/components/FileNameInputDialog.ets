import { DesignTokens } from '../common/DesignTokens';

@CustomDialog
export struct FileNameInputDialog {
  controller?: CustomDialogController
  currentFileName: string = ''
  onConfirm?: (newName: string) => void
  onCancel?: () => void
  @State editName: string = ''

  aboutToAppear(): void {
    this.editName = this.currentFileName;
  }

  build() {
    Column() {
      Text($r('app.string.rename_file_title'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: DesignTokens.space.md })

      TextInput({ placeholder: $r('app.string.rename_file_placeholder'), text: this.editName })
        .width('100%')
        .height(44)
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(DesignTokens.radius.md)
        .padding({ left: DesignTokens.space.sm, right: DesignTokens.space.sm })
        .onChange((value: string) => {
          this.editName = value;
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
              this.onConfirm(this.editName);
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
