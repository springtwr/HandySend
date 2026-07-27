import { DeviceTypeOption } from './SettingsTypes';

@CustomDialog
export struct DeviceTypePickerDialog {
  controller?: CustomDialogController
  options: Array<DeviceTypeOption> = []
  currentType: string = ''
  onSelect?: (value: string) => void

  build() {
    Column() {
      Text('选择设备类型')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 16 })

      ForEach(this.options, (option: DeviceTypeOption) => {
        Row({ space: 12 }) {
          Image(option.icon)
            .width(22)
            .height(22)
            .fillColor($r('app.color.text_primary'))

          Text(option.label)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          if (this.currentType === option.value) {
            Text('\u2713')
              .fontSize(18)
              .fontColor($r('app.color.accent_blue'))
              .fontWeight(FontWeight.Bold)
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(this.currentType === option.value ? $r('app.color.accent_blue_bg') : $r('app.color.card_background'))
        .borderRadius(12)
        .margin({ top: 6 })
        .onClick(() => {
          if (this.onSelect !== undefined) {
            this.onSelect(option.value);
          }
        })
      }, (option: DeviceTypeOption) => option.value)
    }
    .padding(24)
    .width('100%')
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(16)
  }
}
