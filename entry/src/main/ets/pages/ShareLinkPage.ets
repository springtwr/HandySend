import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { stopShareLink, getShareLink } from '../service/AppService';

interface ShareLinkParams {
  shareUrl: string;
}

@Entry
@Component
struct ShareLinkPage {
  @State shareUrl: string = ''

  aboutToAppear(): void {
    const params = router.getParams() as ShareLinkParams;
    if (params !== undefined && params.shareUrl !== undefined) {
      this.shareUrl = params.shareUrl;
    } else {
      this.shareUrl = getShareLink();
    }
  }

  build() {
    Column() {
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor('#182431')
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.share_link_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
          .margin({ left: 12 })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Column() {
        Text($r('app.string.share_link_address_label'))
          .fontSize(14)
          .fontColor('#666666')
          .margin({ bottom: 8 })

        Text(this.shareUrl)
          .fontSize(16)
          .fontColor('#6c5ce7')
          .fontWeight(FontWeight.Medium)
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .backgroundColor('#F5F5FF')
          .borderRadius(8)
          .onClick(() => {
            let systemPasteboard = pasteboard.getSystemPasteboard();
            let data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.shareUrl);
            systemPasteboard.setData(data);
          })
      }
      .margin({ top: 32 })
      .alignItems(HorizontalAlign.Center)

      Column() {
        QRCode(this.shareUrl)
          .width(200)
          .height(200)
          .margin({ top: 24 })

        Text($r('app.string.share_link_qr_hint'))
          .fontSize(12)
          .fontColor('#999999')
          .margin({ top: 12 })
      }
      .margin({ top: 24 })
      .alignItems(HorizontalAlign.Center)

      Button($r('app.string.stop_share'))
        .width('80%')
        .height(44)
        .fontSize(16)
        .fontColor('#FFFFFF')
        .backgroundColor('#FF4444')
        .borderRadius(22)
        .margin({ top: 40 })
        .onClick(() => {
          stopShareLink();
          router.back();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }
}
