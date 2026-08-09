import { DeviceTypeOption } from './SettingsTypes';
import { DesignTokens } from '../../common/DesignTokens';

@CustomDialog
export struct DeviceTypePickerDialog {
  controller?: CustomDialogController
  options: Array<DeviceTypeOption> = []
  currentType: string = ''
  onSelect?: (value: string) => void

  build() {
    Column() {
      Text($r('app.string.select_device_type_title'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: DesignTokens.space.md })

      ForEach(this.options, (option: DeviceTypeOption) => {
        Row({ space: DesignTokens.space.sm }) {
          Image(option.icon)
            .width(22)
            .height(22)
            .fillColor($r('app.color.text_primary'))

          Text(option.label)
            .fontSize(DesignTokens.font.subtitleM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          if (this.currentType === option.value) {
            Text('\u2713')
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor($r('app.color.accent_blue'))
              .fontWeight(FontWeight.Bold)
          }
        }
        .width('100%')
        .padding(DesignTokens.space.md)
        .backgroundColor(this.currentType === option.value ? $r('app.color.accent_blue_bg') : $r('app.color.card_background'))
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.mini * 3 })
        .onClick(() => {
          if (this.onSelect !== undefined) {
            this.onSelect(option.value);
          }
        })
      }, (option: DeviceTypeOption) => option.value)
    }
    .padding(DesignTokens.space.lg)
    .constraintSize({ maxWidth: '85%' })
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
  }
}
