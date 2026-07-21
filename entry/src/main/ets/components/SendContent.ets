import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { preferencesUtil } from '../utils/PreferencesUtil';

interface NearbyDevice {
  id: string
  name: string
  tags: Array<string>
}

@Component
export struct SendContent {
  @State selectedFiles: Array<string> = []
  @State clipboardText: string = ''
  @State scaleFile: number = 1
  @State scaleImage: number = 1
  @State scaleClipboard: number = 1
  @State scaleJustify: number = 1
  @State nearbyDevices: Array<NearbyDevice> = [
    { id: '1', name: '祈的电脑', tags: ['#10', 'Windows'] },
    { id: '2', name: '我的手机', tags: ['#20', 'Android'] }
  ]
  @State refreshAngle: number = 0
  @StorageLink('hideShareByLink') hideShareByLink: boolean = false
  @StorageLink('favoriteDevices') favoriteDevicesJson: string = '[]'

  async pickFiles(): Promise<void> {
    let context = getContext() as common.UIAbilityContext;
    let documentPicker = new picker.DocumentViewPicker(context);
    let options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 10;
    try {
      let uris: Array<string> = await documentPicker.select(options);
      this.selectedFiles = uris;
    } catch (e) {
      console.error('pickFiles error:', JSON.stringify(e));
    }
  }

  async pickImages(): Promise<void> {
    let context = getContext() as common.UIAbilityContext;
    let photoPicker = new picker.PhotoViewPicker(context);
    let options = new picker.PhotoSelectOptions();
    options.maxSelectNumber = 10;
    try {
      let result = await photoPicker.select(options);
      this.selectedFiles = result.photoUris;
    } catch (e) {
      console.error('pickImages error:', JSON.stringify(e));
    }
  }

  async readClipboard(): Promise<void> {
    try {
      let systemPasteboard = pasteboard.getSystemPasteboard();
      let data = await systemPasteboard.getData();
      let text: string = data.getPrimaryText();
      this.clipboardText = text;
    } catch (e) {
      let err = e as BusinessError;
      console.error('readClipboard error:', JSON.stringify(err));
    }
  }

  async pickJustify(): Promise<void> {
    console.info('pickJustify clicked');
  }

  refreshDevices(): void {
    this.getUIContext().animateTo({ duration: 800, curve: Curve.EaseInOut }, () => {
      this.refreshAngle = this.refreshAngle + 360;
    });
    console.info('refresh devices');
  }

  shareByLink(): void {
    console.info('share by link clicked');
  }

  isDeviceFavorite(id: string): boolean {
    let parsed: Array<string> = [];
    try {
      let arr: Object = JSON.parse(this.favoriteDevicesJson);
      if (Array.isArray(arr)) {
        parsed = arr as Array<string>;
      }
    } catch (_e) {
      return false;
    }
    for (let i = 0; i < parsed.length; i++) {
      if (parsed[i] === id) {
        return true;
      }
    }
    return false;
  }

  toggleFavorite(id: string): void {
    let parsed: Array<string> = [];
    try {
      let arr: Object = JSON.parse(this.favoriteDevicesJson);
      if (Array.isArray(arr)) {
        parsed = arr as Array<string>;
      }
    } catch (_e) {
      return;
    }
    let found = false;
    let updated: Array<string> = [];
    for (let i = 0; i < parsed.length; i++) {
      if (parsed[i] === id) {
        found = true;
      } else {
        updated.push(parsed[i]);
      }
    }
    if (!found) {
      updated.push(id);
    }
    this.favoriteDevicesJson = JSON.stringify(updated);
    preferencesUtil.setString('favoriteDevices', this.favoriteDevicesJson);
  }

  build() {
    Scroll() {
      Column() {
        Column() {
          Text($r('app.string.send_select_title'))
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#182431')

          Text($r('app.string.send_select_subtitle'))
            .fontSize(13)
            .fontColor('#999999')
            .margin({ top: 6 })

          Scroll() {
            Row({ space: 10 }) {
              Column() {
                Image($r('app.media.ic_public_file_filled'))
                  .width(20)
                  .height(20)
                  .fillColor('#182431')
                Text($r('app.string.send_file'))
                  .fontSize(12)
                  .fontColor('#182431')
                  .margin({ top: 6 })
              }
              .width(80)
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 20, bottom: 20 })
              .borderRadius(12)
              .backgroundColor('#F2F3F5')
              .scale({ x: this.scaleFile, y: this.scaleFile })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
                    this.scaleFile = 0.95;
                  });
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
                    this.scaleFile = 1;
                  });
                }
              })
              .onClick(() => {
                this.pickFiles();
              })

              Column() {
                Image($r('app.media.ic_public_picture_filled'))
                  .width(20)
                  .height(20)
                  .fillColor('#182431')
                Text($r('app.string.send_image'))
                  .fontSize(12)
                  .fontColor('#182431')
                  .margin({ top: 6 })
              }
              .width(80)
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 20, bottom: 20 })
              .borderRadius(12)
              .backgroundColor('#F2F3F5')
              .scale({ x: this.scaleImage, y: this.scaleImage })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
                    this.scaleImage = 0.95;
                  });
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
                    this.scaleImage = 1;
                  });
                }
              })
              .onClick(() => {
                this.pickImages();
              })

              Column() {
                Image($r('app.media.ic_clipboard'))
                  .width(20)
                  .height(20)
                  .fillColor('#182431')
                Text($r('app.string.send_clipboard'))
                  .fontSize(12)
                  .fontColor('#182431')
                  .margin({ top: 6 })
              }
              .width(80)
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 20, bottom: 20 })
              .borderRadius(12)
              .backgroundColor('#F2F3F5')
              .scale({ x: this.scaleClipboard, y: this.scaleClipboard })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
                    this.scaleClipboard = 0.95;
                  });
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
                    this.scaleClipboard = 1;
                  });
                }
              })
              .onClick(() => {
                this.readClipboard();
              })

              Column() {
                Image($r('app.media.ic_justify'))
                  .width(20)
                  .height(20)
                  .fillColor('#182431')
                Text($r('app.string.send_justify'))
                  .fontSize(12)
                  .fontColor('#182431')
                  .margin({ top: 6 })
              }
              .width(80)
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 20, bottom: 20 })
              .borderRadius(12)
              .backgroundColor('#F2F3F5')
              .scale({ x: this.scaleJustify, y: this.scaleJustify })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
                    this.scaleJustify = 0.95;
                  });
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
                    this.scaleJustify = 1;
                  });
                }
              })
              .onClick(() => {
                this.pickJustify();
              })
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .margin({ top: 16 })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E8E8E8' })
        .margin({ top: 24, left: 16, right: 16 })

        Column() {
          Row() {
            Column() {
              Text($r('app.string.nearby_devices_title'))
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor('#182431')

              Text($r('app.string.nearby_devices_subtitle'))
                .fontSize(13)
                .fontColor('#999999')
                .margin({ top: 6 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Image($r('app.media.ic_public_refresh'))
              .width(24)
              .height(24)
              .fillColor('#182431')
              .rotate({ angle: this.refreshAngle })
              .onClick(() => {
                this.refreshDevices();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (!this.hideShareByLink) {
            Row() {
              Text($r('app.string.share_via_link'))
                .fontSize(14)
                .fontColor('#182431')
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding(12)
            .backgroundColor('#F2F3F5')
            .borderRadius(8)
            .margin({ top: 12 })
            .onClick(() => {
              this.shareByLink();
            })
          }

          Column({ space: 10 }) {
            ForEach(this.nearbyDevices, (device: NearbyDevice) => {
              Row({ space: 12 }) {
                Image($r('app.media.ic_public_devices_phone'))
                  .width(40)
                  .height(40)
                  .fillColor('#182431')

                Column() {
                  Text(device.name)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#182431')

                  Row({ space: 8 }) {
                    ForEach(device.tags, (tag: string) => {
                      Text(tag)
                        .fontSize(12)
                        .fontColor('#36D')
                        .backgroundColor('#E8F0FE')
                        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                        .borderRadius(4)
                    }, (tag: string) => tag)
                  }
                  .margin({ top: 6 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Image(this.isDeviceFavorite(device.id) ? $r('app.media.ic_heart_fill') : $r('app.media.ic_heart'))
                  .width(22)
                  .height(22)
                  .responseRegion({ x: -10, y: -10, width: 42, height: 42 })
                  .fillColor(this.isDeviceFavorite(device.id) ? '#FF4D4F' : '#999999')
                  .onClick(() => {
                    this.toggleFavorite(device.id);
                  })
              }
              .width('100%')
              .padding(16)
              .backgroundColor('#F2F3F5')
              .borderRadius(12)
              .alignItems(VerticalAlign.Center)
            }, (device: NearbyDevice) => device.id)
          }
          .width('100%')
          .margin({ top: 16 })
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
