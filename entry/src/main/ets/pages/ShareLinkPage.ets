import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { getShareLink, stopShareLink, getSharePort,
  savePreWebShareState, restorePreWebShareState,
  setShareViaLinkAutoAccept, setReceiveViaLinkAutoAccept,
  getReceivePin, setReceivePin } from '../service/AppService';
import { DialogService } from '../service/DialogService';
import { preferencesUtil, KEY_SHARE_VIA_LINK_AUTO_ACCEPT } from '../utils/PreferencesUtil';
import { DesignTokens } from '../common/DesignTokens';

@Entry
@Component
struct ShareLinkPage {
  @State shareUrl: string = ''
  @State isReceiveMode: boolean = false
  @State webSslEnabled: boolean = false
  @State webPin: string = ''
  @State webAutoAccept: boolean = false
  @State uploadUrl: string = ''

  aboutToAppear(): void {
    let params = router.getParams() as Record<string, string>;
    if (params !== undefined && params['shareUrl'] !== undefined) {
      this.shareUrl = params['shareUrl'] as string;
    } else {
      this.shareUrl = getShareLink();
    }

    // Load web share settings
    this.webAutoAccept = preferencesUtil.getBoolean(KEY_SHARE_VIA_LINK_AUTO_ACCEPT, false);
    this.webPin = getReceivePin();

    // Save pre-Web-Share state for restoration on exit
    savePreWebShareState();
  }

  aboutToDisappear(): void {
    // Restore server to original state when leaving Web Share page
    restorePreWebShareState();
  }

  private copyToClipboard(text: string): void {
    let systemPasteboard = pasteboard.getSystemPasteboard();
    let data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    systemPasteboard.setData(data);
  }

  private toggleMode(): void {
    this.isReceiveMode = !this.isReceiveMode;
    if (this.isReceiveMode) {
      // Switch to receive (upload) mode
      let port = getSharePort();
      let protocol = this.webSslEnabled ? 'https' : 'http';
      this.uploadUrl = protocol + '://' + this.extractHostFromUrl(this.shareUrl) + ':' + port + '/upload';
    } else {
      // Switch back to send (download) mode
      this.uploadUrl = '';
    }
  }

  private toggleWebSsl(): void {
    this.webSslEnabled = !this.webSslEnabled;
    let port = getSharePort();
    let protocol = this.webSslEnabled ? 'https' : 'http';
    let host = this.extractHostFromUrl(this.shareUrl);
    if (this.isReceiveMode) {
      this.uploadUrl = protocol + '://' + host + ':' + port + '/upload';
    } else {
      this.shareUrl = protocol + '://' + host + ':' + port;
    }
  }

  private extractHostFromUrl(url: string): string {
    let hostPart = url;
    if (hostPart.indexOf('://') >= 0) {
      hostPart = hostPart.substring(hostPart.indexOf('://') + 3);
    }
    if (hostPart.indexOf(':') >= 0) {
      hostPart = hostPart.substring(0, hostPart.indexOf(':'));
    }
    if (hostPart.indexOf('/') >= 0) {
      hostPart = hostPart.substring(0, hostPart.indexOf('/'));
    }
    return hostPart;
  }

  build() {
    Column() {
      // Header
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
          .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.share_link_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          // Mode toggle: Send / Receive
          Row({ space: 0 }) {
            Row() {
              Text($r('app.string.web_share_send'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor(!this.isReceiveMode ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
                .fontWeight(!this.isReceiveMode ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .backgroundColor(!this.isReceiveMode ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
            .borderRadius({ topLeft: DesignTokens.radius.md, bottomLeft: DesignTokens.radius.md })
            .onClick(() => {
              if (this.isReceiveMode) {
                this.toggleMode();
              }
            })

            Row() {
              Text($r('app.string.web_share_receive'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor(this.isReceiveMode ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
                .fontWeight(this.isReceiveMode ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .backgroundColor(this.isReceiveMode ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
            .borderRadius({ topRight: DesignTokens.radius.md, bottomRight: DesignTokens.radius.md })
            .onClick(() => {
              if (!this.isReceiveMode) {
                this.toggleMode();
              }
            })
          }
          .width('100%')
          .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.md })

          // URL display
          Column() {
            Text(this.isReceiveMode ? $r('app.string.web_upload_url_hint') : $r('app.string.share_link_address_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ bottom: DesignTokens.space.xs })

            Text(this.isReceiveMode ? this.uploadUrl : this.shareUrl)
              .fontSize(DesignTokens.font.subtitleM)
              .fontColor($r('app.color.purple_text'))
              .fontWeight(FontWeight.Medium)
              .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
              .backgroundColor($r('app.color.purple_bg'))
              .borderRadius(DesignTokens.radius.md)
              .onClick(() => {
                this.copyToClipboard(this.isReceiveMode ? this.uploadUrl : this.shareUrl);
              })
          }
          .alignItems(HorizontalAlign.Center)

          // QR Code
          Column() {
            Column() {
              QRCode(this.isReceiveMode ? this.uploadUrl : this.shareUrl)
                .width(200)
                .height(200)
                .backgroundColor($r('app.color.qr_code_background'))
            }
            .width(232)
            .height(232)
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

          // Web Share Settings
          Column() {
            Text($r('app.string.settings_network'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: DesignTokens.space.sm })

            // Web SSL toggle
            Row() {
              Text($r('app.string.web_ssl_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.webSslEnabled })
                .onChange((isOn: boolean) => {
                  this.webSslEnabled = isOn;
                  this.toggleWebSsl();
                })
            }
            .width('100%')
            .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .alignItems(VerticalAlign.Center)

            // Web PIN
            Row() {
              Text($r('app.string.web_pin_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              if (this.webPin.length > 0) {
                Text('****')
                  .fontSize(DesignTokens.font.bodyM)
                  .fontColor($r('app.color.text_tertiary'))
              } else {
                Text($r('app.string.pin_set_label'))
                  .fontSize(DesignTokens.font.bodyM)
                  .fontColor($r('app.color.text_tertiary'))
              }
            }
            .width('100%')
            .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              DialogService.showInputDialog($r('app.string.web_pin_label'), this.webPin, (value: string) => {
                this.webPin = value;
                setReceivePin(value);
              });
            })

            Text($r('app.string.receive_pin_desc'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ bottom: DesignTokens.space.xs })

            // Auto-accept toggle
            Row() {
              Text($r('app.string.web_auto_accept_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.webAutoAccept })
                .onChange((isOn: boolean) => {
                  this.webAutoAccept = isOn;
                  if (this.isReceiveMode) {
                    setReceiveViaLinkAutoAccept(isOn);
                  } else {
                    setShareViaLinkAutoAccept(isOn);
                  }
                })
            }
            .width('100%')
            .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .borderRadius(DesignTokens.radius.lg)
          .backgroundColor($r('app.color.card_background'))
          .border({ width: 1, color: $r('app.color.border_light') })
          .margin({ top: DesignTokens.space.lg })

          // Download requests list (send mode)
          if (!this.isReceiveMode) {
            Column() {
              Text($r('app.string.web_request_list_title'))
                .fontSize(DesignTokens.font.subtitleM)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .alignSelf(ItemAlign.Start)
                .margin({ bottom: DesignTokens.space.sm })

              Text($r('app.string.no_logs'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_secondary'))
                .alignSelf(ItemAlign.Center)
                .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.md })
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .borderRadius(DesignTokens.radius.lg)
            .backgroundColor($r('app.color.card_background'))
            .border({ width: 1, color: $r('app.color.border_light') })
            .margin({ top: DesignTokens.space.md })
          }
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
        .onClick(() => {
          stopShareLink();
          router.back();
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
