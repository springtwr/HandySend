import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';

@Entry
@Component
struct AboutPage {
  private readonly projectUrl: string = 'https://gitcode.com/loar/NekoShare'
  private readonly localsendUrl: string = 'https://github.com/localsend/localsend'

  private copyToClipboard(text: string): void {
    let data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data);
    this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copy_success'), duration: 2000 });
  }

  build() {
    Column() {
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
          .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.about_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Row() {
          Column() {
            Text($r('app.string.about_description'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontColor($r('app.color.text_primary'))
              .lineHeight(22)
              .width('100%')

            Column() {
              Text($r('app.string.about_project_url_title'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ bottom: DesignTokens.space.xs })

              Text(this.projectUrl)
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.ip_blue_text'))
                .fontWeight(FontWeight.Medium)
                .padding({
                  left: DesignTokens.space.md,
                  right: DesignTokens.space.md,
                  top: DesignTokens.space.sm,
                  bottom: DesignTokens.space.sm
                })
                .width('100%')
                .backgroundColor($r('app.color.accent_blue_bg'))
                .borderRadius(DesignTokens.radius.md)
                .onClick(() => {
                  this.copyToClipboard(this.projectUrl);
                })
            }
            .width('100%')
            .margin({ top: DesignTokens.space.lg })

            Column() {
              Text($r('app.string.about_localsend_url_title'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ bottom: DesignTokens.space.xs })

              Text(this.localsendUrl)
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.ip_blue_text'))
                .fontWeight(FontWeight.Medium)
                .padding({
                  left: DesignTokens.space.md,
                  right: DesignTokens.space.md,
                  top: DesignTokens.space.sm,
                  bottom: DesignTokens.space.sm
                })
                .width('100%')
                .backgroundColor($r('app.color.accent_blue_bg'))
                .borderRadius(DesignTokens.radius.md)
                .onClick(() => {
                  this.copyToClipboard(this.localsendUrl);
                })
            }
            .width('100%')
            .margin({ top: DesignTokens.space.md })
          }
          .width('100%')
          .constraintSize({ maxWidth: 800 })
          .padding(DesignTokens.space.xl)
          .borderRadius(DesignTokens.radius.lg)
          .backgroundColor($r('app.color.card_background'))
          .border({ width: 1, color: $r('app.color.border_light') })
          .margin({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xl })
        }
        .width('100%')
        .height('100%')
        .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
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

  pageTransition() {
    PageTransitionEnter({
      type: RouteType.Push,
      duration: DesignTokens.animation.durationNormal,
      curve: Curve.FastOutSlowIn
    }).slide(SlideEffect.Right)
    PageTransitionEnter({
      type: RouteType.Pop,
      duration: DesignTokens.animation.durationNormal,
      curve: Curve.FastOutSlowIn
    }).slide(SlideEffect.Left)
    PageTransitionExit({
      type: RouteType.Push,
      duration: DesignTokens.animation.durationNormal,
      curve: Curve.FastOutSlowIn
    }).slide(SlideEffect.Left)
    PageTransitionExit({
      type: RouteType.Pop,
      duration: DesignTokens.animation.durationNormal,
      curve: Curve.FastOutSlowIn
    }).slide(SlideEffect.Right)
  }
}
