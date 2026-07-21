import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { getDiscoveredDevices, rescanDevices, subscribe, unsubscribe,
  prepareSendFiles, sendToDevice, createShareLink, stopShareLink,
  getShareLink, getActiveProgress } from '../service/AppService';
import { DiscoveredDevice, SendFileItem, TransferProgress } from '../model/Types';

@Component
export struct SendContent {
  @State selectedFiles: Array<string> = []
  @State clipboardText: string = ''
  @State scaleFile: number = 1
  @State scaleImage: number = 1
  @State scaleClipboard: number = 1
  @State scaleJustify: number = 1
  @State discoveredDevices: Array<DiscoveredDevice> = []
  @State refreshAngle: number = 0
  @StorageLink('hideShareByLink') hideShareByLink: boolean = false
  @StorageLink('favoriteDevices') favoriteDevicesJson: string = '[]'
  @StorageLink('serverReady') serverReady: boolean = false
  @State shareUrl: string = ''
  @State progressItems: Array<TransferProgress> = []
  private refreshCallback: () => void = () => {}

  aboutToAppear(): void {
    this.refreshCallback = () => {
      this.discoveredDevices = getDiscoveredDevices();
      this.shareUrl = getShareLink();
      this.progressItems = getActiveProgress();
    };
    subscribe(this.refreshCallback);
    this.discoveredDevices = getDiscoveredDevices();
  }

  aboutToDisappear(): void {
    unsubscribe(this.refreshCallback);
  }

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
    await this.readClipboard();
    if (this.clipboardText.length === 0) {
      AlertDialog.show({
        title: 'Share Text',
        message: 'Please copy text to clipboard first, then tap this button',
        confirm: {
          value: 'OK',
          action: () => {}
        }
      });
      return;
    }
    let context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    let sendDir: string = context.filesDir + '/send/';
    try {
      fs.mkdirSync(sendDir);
    } catch (_e) {}
    let fileName: string = 'justify_' + Date.now() + '.txt';
    let filePath: string = sendDir + fileName;
    let file: fs.File = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    fs.writeSync(file.fd, this.clipboardText);
    fs.closeSync(file);
    this.selectedFiles.push(filePath);
  }

  refreshDevices(): void {
    this.getUIContext().animateTo({ duration: 800, curve: Curve.EaseInOut }, () => {
      this.refreshAngle = this.refreshAngle + 360;
    });
    if (this.serverReady) {
      rescanDevices();
    }
  }

  async shareByLink(): Promise<void> {
    if (this.selectedFiles.length === 0) {
      await this.pickFiles();
    }
    if (this.selectedFiles.length === 0) {
      return;
    }
    let items: Array<SendFileItem> = await prepareSendFiles(this.selectedFiles);
    if (items.length > 0) {
      await createShareLink(items);
      this.shareUrl = getShareLink();
    }
  }

  async sendToSelectedDevice(device: DiscoveredDevice): Promise<void> {
    if (this.selectedFiles.length === 0) {
      AlertDialog.show({
        title: 'No files selected',
        message: 'Please select files first using the buttons above',
        confirm: {
          value: 'OK',
          action: () => {}
        }
      });
      return;
    }
    let items: Array<SendFileItem> = await prepareSendFiles(this.selectedFiles);
    if (items.length > 0) {
      AlertDialog.show({
        title: 'Send to ' + device.alias,
        message: items.length + ' file(s) selected',
        primaryButton: {
          value: 'Send',
          action: () => {
            sendToDevice(device, items);
          }
        },
        secondaryButton: {
          value: 'Cancel',
          action: () => {}
        }
      });
    }
  }

  isDeviceFavorite(fingerprint: string): boolean {
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
      if (parsed[i] === fingerprint) {
        return true;
      }
    }
    return false;
  }

  toggleFavorite(fingerprint: string): void {
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
      if (parsed[i] === fingerprint) {
        found = true;
      } else {
        updated.push(parsed[i]);
      }
    }
    if (!found) {
      updated.push(fingerprint);
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
            ForEach(this.discoveredDevices, (device: DiscoveredDevice) => {
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

                Image(this.isDeviceFavorite(device.fingerprint) ? $r('app.media.ic_heart_fill') : $r('app.media.ic_heart'))
                  .width(22)
                  .height(22)
                  .responseRegion({ x: -10, y: -10, width: 42, height: 42 })
                  .fillColor(this.isDeviceFavorite(device.fingerprint) ? '#FF4D4F' : '#999999')
                  .onClick(() => {
                    this.toggleFavorite(device.fingerprint);
                  })
              }
              .width('100%')
              .padding(16)
              .backgroundColor('#F2F3F5')
              .borderRadius(12)
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.sendToSelectedDevice(device);
              })
            }, (device: DiscoveredDevice) => device.fingerprint)
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E8E8E8' })
        .margin({ top: 16, left: 16, right: 16, bottom: 24 })

        if (this.shareUrl.length > 0) {
          Column() {
            Row() {
              Text('Share Link')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#182431')
                .layoutWeight(1)

              Button('Stop')
                .fontSize(12)
                .onClick(() => {
                  stopShareLink();
                  this.shareUrl = '';
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Text(this.shareUrl)
              .fontSize(12)
              .fontColor('#6c5ce7')
              .width('100%')
              .margin({ top: 8 })
          }
          .padding(16)
          .borderRadius(16)
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#E8E8E8' })
          .margin({ top: 16, left: 16, right: 16 })
        }

        if (this.progressItems.length > 0) {
          Column() {
            Text('Transfer Progress')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#182431')

            ForEach(this.progressItems, (p: TransferProgress) => {
              Row() {
                Text(p.fileId.substring(0, 8) + '...')
                  .fontSize(12)
                  .fontColor('#333333')
                  .layoutWeight(1)

                Text((p.bytesSent * 100 /
                  (p.totalBytes > 0 ? p.totalBytes : 1)).toFixed(0) + '%')
                  .fontSize(12)
                  .fontColor('#2B8C2B')
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })
            }, (p: TransferProgress) => p.fileId + p.bytesSent)
          }
          .padding(16)
          .borderRadius(16)
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#E8E8E8' })
          .margin({ top: 16, left: 16, right: 16, bottom: 24 })
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
  }
}
