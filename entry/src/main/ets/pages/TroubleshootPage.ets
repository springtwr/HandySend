import { router } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';

@Entry
@Component
struct TroubleshootPage {
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

        Text($r('app.string.troubleshoot_title'))
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
        Column({ space: DesignTokens.space.md }) {
          // Firewall issues
          Column() {
            Text($r('app.string.troubleshoot_firewall_title'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            Text($r('app.string.troubleshoot_firewall_desc'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: DesignTokens.space.xs })
              .width('100%')
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })

          // Cannot discover devices
          Column() {
            Text($r('app.string.troubleshoot_discovery_title'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            Text($r('app.string.troubleshoot_discovery_desc'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: DesignTokens.space.xs })
              .width('100%')
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })

          // Cannot connect
          Column() {
            Text($r('app.string.troubleshoot_connection_title'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            Text($r('app.string.troubleshoot_connection_desc'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: DesignTokens.space.xs })
              .width('100%')
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })

          // Protocol (encryption) mismatch
          Column() {
            Text($r('app.string.troubleshoot_protocol_title'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            Text($r('app.string.troubleshoot_protocol_desc'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: DesignTokens.space.xs })
              .width('100%')
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })

          // Debug tools navigation
          Column() {
            // Security Info — links to DebugPage which has app info + cert reset
            Row() {
              Text($r('app.string.service_info_title'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              Text('>')
                .fontSize(DesignTokens.font.subtitleM)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .onClick(() => {
              router.pushUrl({ url: 'pages/DebugPage' });
            })

            Divider().color($r('app.color.border_light'))

            // HTTP Logs
            Row() {
              Text($r('app.string.http_logs_title'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              Text('>')
                .fontSize(DesignTokens.font.subtitleM)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .onClick(() => {
              router.pushUrl({ url: 'pages/HttpLogsPage' });
            })

            Divider().color($r('app.color.border_light'))

            // Discovery Debug
            Row() {
              Text($r('app.string.discovery_debug_title'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              Text('>')
                .fontSize(DesignTokens.font.subtitleM)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .onClick(() => {
              router.pushUrl({ url: 'pages/DiscoveryDebugPage' });
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
