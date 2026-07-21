import { getLocalDeviceInfo, getDiscoveredDevices, subscribe, unsubscribe } from '../service/AppService';
import { DiscoveredDevice, LocalDeviceInfo } from '../model/Types';
import { preferencesUtil } from '../utils/PreferencesUtil';

@Component
export struct ReceiveContent {
  @State localDeviceInfo: LocalDeviceInfo = { alias: '', fingerprint: '', ip: '0.0.0.0' }
  @State autoSaveMode: string = 'off'
  @State refreshTick: number = 0
  @StorageLink('favoriteDevices') favoriteDevicesJson: string = '[]'
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
            .fontColor('#182431')

          Row({ space: 16 }) {
            Text(this.getIpShortCode(this.localDeviceInfo.ip))
              .fontSize(13)
              .fontColor('#999999')

            Text(this.localDeviceInfo.ip)
              .fontSize(13)
              .fontColor('#999999')
          }
          .width('100%')
          .margin({ top: 8 })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E8E8E8' })
        .margin({ top: 24, left: 16, right: 16 })

        Column() {
          Text($r('app.string.auto_save_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#182431')

          Row({ space: 0 }) {
            Row() {
              Text($r('app.string.auto_save_off'))
                .fontSize(14)
                .fontColor(this.autoSaveMode === 'off' ? '#007DFF' : '#999999')
                .fontWeight(this.autoSaveMode === 'off' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 8, bottom: 8 })
            .backgroundColor(this.autoSaveMode === 'off' ? '#E8F0FE' : '#F2F3F5')
            .borderRadius({ topLeft: 8, bottomLeft: 8 })
            .onClick(() => {
              this.setAutoSaveMode('off');
            })

            Row() {
              Text($r('app.string.auto_save_favorites'))
                .fontSize(14)
                .fontColor(this.autoSaveMode === 'favorites' ? '#007DFF' : '#999999')
                .fontWeight(this.autoSaveMode === 'favorites' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 8, bottom: 8 })
            .backgroundColor(this.autoSaveMode === 'favorites' ? '#E8F0FE' : '#F2F3F5')
            .onClick(() => {
              this.setAutoSaveMode('favorites');
            })

            Row() {
              Text($r('app.string.auto_save_on'))
                .fontSize(14)
                .fontColor(this.autoSaveMode === 'on' ? '#007DFF' : '#999999')
                .fontWeight(this.autoSaveMode === 'on' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 8, bottom: 8 })
            .backgroundColor(this.autoSaveMode === 'on' ? '#E8F0FE' : '#F2F3F5')
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
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E8E8E8' })
        .margin({ top: 16, left: 16, right: 16 })

        Column() {
          Text($r('app.string.favorite_devices_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#182431')

          Column({ space: 10 }) {
            if (this.getFavoriteDiscoveredDevices().length === 0) {
              Text($r('app.string.no_favorite_devices'))
                .fontSize(14)
                .fontColor('#999999')
                .margin({ top: 16 })
                .width('100%')
                .textAlign(TextAlign.Center)
            }
            ForEach(this.getFavoriteDiscoveredDevices(), (device: DiscoveredDevice) => {
              Row({ space: 12 }) {
                Image($r('app.media.ic_public_devices_phone'))
                  .width(40)
                  .height(40)
                  .fillColor('#182431')

                Column() {
                  Text(device.alias)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#182431')

                  Row({ space: 8 }) {
                    Text('#' + device.ip.split('.').pop())
                      .fontSize(12)
                      .fontColor('#36D')
                      .backgroundColor('#E8F0FE')
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .borderRadius(4)

                    Text(device.deviceType)
                      .fontSize(12)
                      .fontColor('#36D')
                      .backgroundColor('#E8F0FE')
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
                  .fillColor('#FF4D4F')
                  .onClick(() => {
                    this.removeFavorite(device.fingerprint);
                  })
              }
              .width('100%')
              .padding(16)
              .backgroundColor('#F2F3F5')
              .borderRadius(12)
              .alignItems(VerticalAlign.Center)
            }, (device: DiscoveredDevice) => device.fingerprint)
          }
          .width('100%')
          .margin({ top: 12 })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E8E8E8' })
        .margin({ top: 16, left: 16, right: 16, bottom: 24 })
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
