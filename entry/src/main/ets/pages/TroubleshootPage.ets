import { DesignTokens } from '../common/DesignTokens';

@Entry
@ComponentV2
struct TroubleshootPage {
  build() {
    Column() {
      // 标题栏
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
          .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
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
          // 防火墙问题
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

          // 无法发现设备
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

            Text($r('app.string.troubleshoot_discovery_service_hint'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.warning_orange'))
              .margin({ top: DesignTokens.space.xs })
              .width('100%')
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })

          // 无法连接
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

          // 协议（加密）不匹配
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

          // 调试工具导航
          Column() {
            // 安全信息——链接到含应用信息 + 证书重置的 DebugPage
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
              this.getUIContext().getRouter().pushUrl({ url: 'pages/DebugPage' });
            })

            Divider().color($r('app.color.border_light'))

            // HTTP 日志
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
              this.getUIContext().getRouter().pushUrl({ url: 'pages/HttpLogsPage' });
            })

            Divider().color($r('app.color.border_light'))

            // 发现调试
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
              this.getUIContext().getRouter().pushUrl({ url: 'pages/DiscoveryDebugPage' });
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
