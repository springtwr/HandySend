import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';

@Component
export struct SendContent {
  @State selectedFiles: Array<string> = []
  @State clipboardText: string = ''
  @State scaleFile: number = 1
  @State scaleImage: number = 1
  @State scaleClipboard: number = 1
  @State scaleJustify: number = 1

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

  build() {
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
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor('#FFFFFF')
      .border({ width: 1, color: '#E8E8E8' })
      .margin({ top: 24, left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }
}
