import { getLocalDeviceInfo, getDiscoveredDevices, subscribe, unsubscribe,
  getHttpsEnabled } from '../service/AppService';
import { DiscoveredDevice, LocalDeviceInfo } from '../model/Types';
import { preferencesUtil } from '../utils/PreferencesUtil';

@Component
export struct ReceiveContent {
  @State localDeviceInfo: LocalDeviceInfo = { alias: '', fingerprint: '', ip: '0.0.0.0' }
  @State refreshTick: number = 0
  @StorageLink('autoSaveMode') autoSaveMode: string = 'off'
  @StorageLink('favoriteDevices') favoriteDevicesJson: string = '[]'
  @StorageLink('encryptedTransfer') encryptedTransfer: boolean = true
  private refreshCallback: () => void = () => {}

  aboutToAppear(): void {
    this.refreshCallback = () => {
      this.refreshTick = this.refreshTick + 1;
    };
    subscribe(this.refreshCallback);

    this.localDeviceInfo = getLocalDeviceInfo();
    if (this.localDeviceInfo.alias === '') {
      this.localDeviceInfo = { alias: 'NekoShare', fingerprint: '', ip: '192.168.1.42' };
    }
    let savedMode: string = preferencesUtil.getString('autoSaveMode', 'off');
    if (savedMode === 'off' || savedMode === 'favorites' || savedMode === 'on') {
      this.autoSaveMode = savedMode;
    }
  }

  aboutToDisappear(): void {
    unsubscribe(this.refreshCallback);
  }

  getIpShortCode(ip: string): string {
    let parts: Array<string> = ip.split('.');
    let last: string = parts.length > 0 ? parts[parts.length - 1] : '0';
    return '#' + last;
  }

  getFavoriteDiscoveredDevices(): Array<DiscoveredDevice> {
    let devices: Array<DiscoveredDevice> = getDiscoveredDevices();
    let parsed: Array<string> = [];
    try {
      let arr: Object = JSON.parse(this.favoriteDevicesJson);
      if (Array.isArray(arr)) {
        parsed = arr as Array<string>;
      }
    } catch (_e) {
      return [];
    }
    let result: Array<DiscoveredDevice> = [];
    for (let i = 0; i < devices.length; i++) {
      let device = devices[i];
      for (let j = 0; j < parsed.length; j++) {
        if (device.fingerprint === parsed[j]) {
          result.push(device);
          break;
        }
      }
    }
    return result;
  }

  setAutoSaveMode(mode: string): void {
    this.autoSaveMode = mode;
    preferencesUtil.setString('autoSaveMode', mode);
  }

  removeFavorite(fingerprint: string): void {
    let parsed: Array<string> = [];
    try {
      let arr: Object = JSON.parse(this.favoriteDevicesJson);
      if (Array.isArray(arr)) {
        parsed = arr as Array<string>;
      }
    } catch (_e) {
      return;
    }
    let updated: Array<string> = [];
    for (let i = 0; i < parsed.length; i++) {
      if (parsed[i] !== fingerprint) {
        updated.push(parsed[i]);
      }
    }
    this.favoriteDevicesJson = JSON.stringify(updated);
    preferencesUtil.setString('favoriteDevices', this.favoriteDevicesJson);
  }



  build() {
    Scroll() {
      Column() {
        Column() {
          Text(this.localDeviceInfo.alias)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))

          Row({ space: 16 }) {
            Text(this.getIpShortCode(this.localDeviceInfo.ip))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))

            Text(this.localDeviceInfo.ip)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .margin({ top: 8 })

          Row({ space: 8 }) {
            Text(this.encryptedTransfer ? 'HTTPS' : 'HTTP')
              .fontSize(11)
              .fontColor(this.encryptedTransfer ? $r('app.color.success_green') : $r('app.color.warning_orange'))
              .backgroundColor(this.encryptedTransfer ? $r('app.color.success_bg') : $r('app.color.warning_bg'))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(4)
          }
          .width('100%')
          .margin({ top: 6 })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: 24, left: 16, right: 16 })

        Column() {
          Text($r('app.string.auto_save_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))

          Row({ space: 0 }) {
            Row() {
              Text($r('app.string.auto_save_off'))
                .fontSize(14)
                .fontColor(this.autoSaveMode === 'off' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
                .fontWeight(this.autoSaveMode === 'off' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 8, bottom: 8 })
            .backgroundColor(this.autoSaveMode === 'off' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
            .borderRadius({ topLeft: 8, bottomLeft: 8 })
            .onClick(() => {
              this.setAutoSaveMode('off');
            })

            Row() {
              Text($r('app.string.auto_save_favorites'))
                .fontSize(14)
                .fontColor(this.autoSaveMode === 'favorites' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
                .fontWeight(this.autoSaveMode === 'favorites' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 8, bottom: 8 })
            .backgroundColor(this.autoSaveMode === 'favorites' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
            .onClick(() => {
              this.setAutoSaveMode('favorites');
            })

            Row() {
              Text($r('app.string.auto_save_on'))
                .fontSize(14)
                .fontColor(this.autoSaveMode === 'on' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
                .fontWeight(this.autoSaveMode === 'on' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 8, bottom: 8 })
            .backgroundColor(this.autoSaveMode === 'on' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
            .borderRadius({ topRight: 8, bottomRight: 8 })
            .onClick(() => {
              this.setAutoSaveMode('on');
            })
          }
          .width('100%')
          .margin({ top: 12 })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: 16, left: 16, right: 16 })

        Column() {
          Text($r('app.string.favorite_devices_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))

          Column({ space: 10 }) {
            if (this.getFavoriteDiscoveredDevices().length === 0) {
              Text($r('app.string.no_favorite_devices'))
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 16 })
                .width('100%')
                .textAlign(TextAlign.Center)
            }
            ForEach(this.getFavoriteDiscoveredDevices(), (device: DiscoveredDevice) => {
              Row({ space: 12 }) {
                if (device.deviceType === 'mobile') {
                  Image($r('app.media.ic_public_devices_phone'))
                    .width(40)
                    .height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'desktop') {
                  Image($r('app.media.ic_device_matebook'))
                    .width(40)
                    .height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'web') {
                  Image($r('app.media.ic_browser'))
                    .width(40)
                    .height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'headless') {
                  Image($r('app.media.ic_terminal'))
                    .width(40)
                    .height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'server') {
                  Image($r('app.media.ic_server'))
                    .width(40)
                    .height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'tablet') {
                  Image($r('app.media.ic_device_pad'))
                    .width(40)
                    .height(40)
                    .fillColor($r('app.color.text_primary'))
                } else {
                  Image($r('app.media.ic_public_devices_phone'))
                    .width(40)
                    .height(40)
                    .fillColor($r('app.color.text_primary'))
                }

                Column() {
                  Text(device.alias)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))

                  Row({ space: 8 }) {
                    Text('#' + device.ip.split('.').pop())
                      .fontSize(12)
                      .fontColor($r('app.color.ip_blue_text'))
                      .backgroundColor($r('app.color.accent_blue_bg'))
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .borderRadius(4)

                    Text(device.deviceModel)
                      .fontSize(12)
                      .fontColor($r('app.color.ip_blue_text'))
                      .backgroundColor($r('app.color.accent_blue_bg'))
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .borderRadius(4)
                  }
                  .margin({ top: 6 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Image($r('app.media.ic_heart_fill'))
                  .width(22)
                  .height(22)
                  .responseRegion({ x: -10, y: -10, width: 42, height: 42 })
                  .fillColor($r('app.color.danger_red'))
                  .onClick(() => {
                    this.removeFavorite(device.fingerprint);
                  })
              }
              .width('100%')
              .padding(16)
              .backgroundColor($r('app.color.page_background'))
              .borderRadius(12)
              .alignItems(VerticalAlign.Center)
            }, (device: DiscoveredDevice) => device.fingerprint)
          }
          .width('100%')
          .margin({ top: 12 })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: 16, left: 16, right: 16, bottom: 24 })


      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }
}
