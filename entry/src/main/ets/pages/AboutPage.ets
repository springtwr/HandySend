import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';

@Entry
@Component
struct AboutPage {
  private readonly projectUrl: string = 'https://gitcode.com/loar/NekoShare'
  private readonly localsendUrl: string = 'https://github.com/localsend/localsend'

  private copyToClipboard(text: string): void {
    let data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data);
    promptAction.showToast({ message: $r('app.string.copy_success'), duration: 2000 });
  }

  build() {
    Column() {
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.about_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Row() {
          Column() {
            Text($r('app.string.about_description'))
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .lineHeight(22)
              .width('100%')

            Column() {
              Text($r('app.string.about_project_url_title'))
                .fontSize(14)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ bottom: 8 })

              Text(this.projectUrl)
                .fontSize(14)
                .fontColor($r('app.color.ip_blue_text'))
                .fontWeight(FontWeight.Medium)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .backgroundColor($r('app.color.accent_blue_bg'))
                .borderRadius(8)
                .onClick(() => {
                  this.copyToClipboard(this.projectUrl);
                })
            }
            .width('100%')
            .margin({ top: 24 })

            Column() {
              Text($r('app.string.about_localsend_url_title'))
                .fontSize(14)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ bottom: 8 })

              Text(this.localsendUrl)
                .fontSize(14)
                .fontColor($r('app.color.ip_blue_text'))
                .fontWeight(FontWeight.Medium)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .backgroundColor($r('app.color.accent_blue_bg'))
                .borderRadius(8)
                .onClick(() => {
                  this.copyToClipboard(this.localsendUrl);
                })
            }
            .width('100%')
            .margin({ top: 16 })
          }
          .width('100%')
          .constraintSize({ maxWidth: 800 })
          .padding(20)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .border({ width: 1, color: $r('app.color.border_light') })
          .margin({ top: 8, bottom: 24 })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height('100%')
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
