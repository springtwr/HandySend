import { pasteboard } from '@kit.BasicServicesKit';
import { getShareLink, stopShareLink, getSharePort } from '../service/AppService';
import { preferencesUtil, KEY_PORT } from '../utils/PreferencesUtil';
import { DesignTokens } from '../common/DesignTokens';

@Entry
@Component
struct ShareLinkPage {
  @State private isNavigatingBack: boolean = false

  onBackPress(): boolean {
    if (this.isNavigatingBack) {
      return true;
    }
    this.isNavigatingBack = true;
    this.getUIContext().getRouter().back();
    return true;
  }

  @State shareUrl: string = ''
  private effectivePort: number = 0  // resolved port (falls back to settings port if native returns 0)

  aboutToAppear(): void {
    let params = this.getUIContext().getRouter().getParams() as Record<string, string>;
    if (params !== undefined && params['shareUrl'] !== undefined) {
      this.shareUrl = params['shareUrl'] as string;
    } else {
      this.shareUrl = getShareLink();
    }

    // Resolve port from native
    let nativePort = getSharePort();
    if (nativePort > 0) {
      this.effectivePort = nativePort;
    } else {
      this.effectivePort = preferencesUtil.getNumber(KEY_PORT, 53317);
    }

    // URL is now provided directly by Rust with actual IP and port — no fallback construction needed
  }

  aboutToDisappear(): void {
    stopShareLink();
  }

  private copyToClipboard(text: string): void {
    try {
      let systemPasteboard = pasteboard.getSystemPasteboard();
      let data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      systemPasteboard.setData(data);
    } catch (_e) {
      // Clipboard may be locked or unavailable
    }
  }

  build() {
    Column() {
      // Header
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(DesignTokens.layout.iconSize)
          .height(DesignTokens.layout.iconSize)
          .fillColor($r('app.color.text_primary'))
          .responseRegion({ x: -(DesignTokens.hotspot.minSize - DesignTokens.layout.iconSize) / 2, y: -(DesignTokens.hotspot.minSize - DesignTokens.layout.iconSize) / 2, width: DesignTokens.hotspot.minSize, height: DesignTokens.hotspot.minSize })
          .onClick(() => {
            if (this.isNavigatingBack) {
              return;
            }
            this.isNavigatingBack = true;
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.share_link_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)
      }
      .width('100%')
      .height(DesignTokens.layout.headerHeight)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          // URL display
          Column() {
            Text($r('app.string.share_link_address_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ bottom: DesignTokens.space.xs })

            Text(this.shareUrl)
              .fontSize(DesignTokens.font.subtitleM)
              .fontColor($r('app.color.purple_text'))
              .fontWeight(FontWeight.Medium)
              .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
              .backgroundColor($r('app.color.purple_bg'))
              .borderRadius(DesignTokens.radius.md)
              .onClick(() => {
                this.copyToClipboard(this.shareUrl);
                this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copy_success'), duration: 1500 });
              })
          }
          .alignItems(HorizontalAlign.Center)

          // QR Code
          Column() {
            Column() {
              QRCode(this.shareUrl)
                .width(DesignTokens.layout.qrCodeSize)
                .height(DesignTokens.layout.qrCodeSize)
                .backgroundColor($r('app.color.qr_code_background'))
            }
            .width(DesignTokens.layout.qrCodeSize + DesignTokens.space.md * 2)
            .height(DesignTokens.layout.qrCodeSize + DesignTokens.space.md * 2)
            .backgroundColor($r('app.color.qr_code_background'))
            .borderRadius(DesignTokens.radius.md)
            .justifyContent(FlexAlign.Center)

            Text($r('app.string.share_link_qr_hint'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: DesignTokens.space.sm })
          }
          .margin({ top: DesignTokens.space.lg })
          .alignItems(HorizontalAlign.Center)
        }
        .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      }
      .layoutWeight(1)

      // Stop sharing button
      Button($r('app.string.stop_share'))
        .width('80%')
        .height(DesignTokens.hotspot.minSize)
        .fontSize(DesignTokens.font.subtitleM)
        .fontColor($r('app.color.text_on_color'))
        .backgroundColor($r('app.color.stop_red'))
        .borderRadius(DesignTokens.radius.max)
        .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.lg })
        .onClick(async () => {
          if (this.isNavigatingBack) {
            return;
          }
          this.isNavigatingBack = true;
          await stopShareLink();
          this.getUIContext().getRouter().back();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
    PageTransitionEnter({ type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }
}
