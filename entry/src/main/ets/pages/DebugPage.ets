import { router } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';
import { getLocalDeviceInfo, isServerRunning, getHttpsEnabled, getServerFingerprint } from '../service/AppService';
import { preferencesUtil } from '../utils/PreferencesUtil';

@Entry
@Component
struct DebugPage {
  @State appVersion: string = '1.0.0'
  @State deviceModelInfo: string = ''
  @State localIp: string = ''
  @State localAlias: string = ''
  @State localFingerprint: string = ''
  @State serverRunning: boolean = false
  @State serverPort: number = 53317
  @State httpsEnabled: boolean = true
  @State serverFingerprint: string = ''

  aboutToAppear(): void {
    this.deviceModelInfo = deviceInfo.manufacture + ' ' + deviceInfo.productModel;
    let localInfo = getLocalDeviceInfo();
    this.localIp = localInfo.ip;
    this.localAlias = localInfo.alias;
    this.localFingerprint = localInfo.fingerprint;
    this.serverRunning = isServerRunning();
    this.serverPort = preferencesUtil.getNumber('port', 53317);
    this.httpsEnabled = getHttpsEnabled();
    this.serverFingerprint = getServerFingerprint();
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

        Text($r('app.string.security_info_title'))
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
        Column({ space: DesignTokens.space.sm }) {
          // Device info
          Column() {
            Text($r('app.string.debug_device_info'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ bottom: DesignTokens.space.xs })

            this.debugInfoRow($r('app.string.debug_app_version'), this.appVersion)
            this.debugInfoRow($r('app.string.debug_device_info'), this.deviceModelInfo)
            this.debugInfoRow($r('app.string.device_alias_label'), this.localAlias)
            this.debugInfoRow($r('app.string.debug_ip_address'), this.localIp)
            this.debugInfoRow($r('app.string.device_fingerprint_label'), this.localFingerprint.length > 24 ? this.localFingerprint.substring(0, 24) + '...' : this.localFingerprint)
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })

          // Server info
          Column() {
            Text($r('app.string.settings_network'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ bottom: DesignTokens.space.xs })

            this.debugInfoRow($r('app.string.server_status_label'), this.serverRunning ? 'Running' : 'Stopped')
            this.debugInfoRow($r('app.string.port_label'), String(this.serverPort))
            this.debugInfoRow($r('app.string.encrypted_transfer'), this.httpsEnabled ? 'HTTPS' : 'HTTP')
            this.debugInfoRow($r('app.string.device_fingerprint_label'), this.serverFingerprint.length > 24 ? this.serverFingerprint.substring(0, 24) + '...' : this.serverFingerprint)
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })

          // Security info
          Column() {
            Text($r('app.string.security_info_title'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })

            Button($r('app.string.reset_certificate_button'))
              .width('90%')
              .height(DesignTokens.hotspot.minSize)
              .backgroundColor($r('app.color.danger_red'))
              .fontColor($r('app.color.text_on_color'))
              .borderRadius(DesignTokens.radius.md)
              .margin({ bottom: DesignTokens.space.sm })
              .onClick(() => {
                // TODO: Reset TLS certificate via NativeBridge
              })
          }
          .width('100%')
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })
        }
        .padding(DesignTokens.space.md)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  debugInfoRow(label: ResourceStr, value: string): void {
    Row() {
      Text(label)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .width('40%')

      Text(value)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
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
