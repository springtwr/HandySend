import { preferencesUtil } from '../utils/PreferencesUtil';

@Component
export struct SettingsContent {
  @StorageLink('hideShareByLink') hideShareByLink: boolean = false
  @StorageLink('encryptedTransfer') encryptedTransfer: boolean = true

  build() {
    Scroll() {
      Column() {
        Column() {
          Text($r('app.string.settings_title'))
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#182431')

          Row() {
            Text($r('app.string.hide_share_by_link'))
              .fontSize(16)
              .fontColor('#182431')
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.hideShareByLink })
              .onChange((isOn: boolean) => {
                this.hideShareByLink = isOn;
                preferencesUtil.setBoolean('hideShareByLink', isOn);
              })
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#F2F3F5')
          .borderRadius(12)
          .margin({ top: 16 })

          Row() {
            Text($r('app.string.encrypted_transfer'))
              .fontSize(16)
              .fontColor('#182431')
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.encryptedTransfer })
              .onChange((isOn: boolean) => {
                this.encryptedTransfer = isOn;
                preferencesUtil.setBoolean('encryptedTransfer', isOn);
              })
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#F2F3F5')
          .borderRadius(12)
          .margin({ top: 12 })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E8E8E8' })
        .margin({ top: 24, left: 16, right: 16 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
  }
}
