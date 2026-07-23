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
        .fontColor('#182431')
        .margin({ bottom: 16 })

      ForEach(this.options, (option: DeviceTypeOption) => {
        Row({ space: 12 }) {
          Image(option.icon)
            .width(22)
            .height(22)
            .fillColor('#182431')

          Text(option.label)
            .fontSize(16)
            .fontColor('#182431')
            .layoutWeight(1)

          if (this.currentType === option.value) {
            Text('\u2713')
              .fontSize(18)
              .fontColor('#007DFF')
              .fontWeight(FontWeight.Bold)
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(this.currentType === option.value ? '#E8F0FE' : '#FFFFFF')
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
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
  }
}
