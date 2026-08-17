import { rescanDevices, getDiscoveredDevices } from '../service/AppService';
import { DesignTokens } from '../common/DesignTokens';

@Entry
@Component
struct DiscoveryDebugPage {
  @State discoveryLog: Array<string> = []
  @State discoveredCount: number = 0

  aboutToAppear(): void {
    let devices = getDiscoveredDevices();
    this.discoveredCount = devices.length;
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
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.discovery_debug_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)

        // Manual announce button
        Text($r('app.string.announce_now_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.accent_blue'))
          .margin({ right: DesignTokens.space.md })
          .responseRegion({ x: -8, y: -8, width: 40, height: 40 })
          .onClick(() => {
            rescanDevices();
            let devices = getDiscoveredDevices();
            this.discoveredCount = devices.length;
            this.discoveryLog.push(new Date().toLocaleTimeString() + ' Manual announce triggered');
          })

        // Clear button
        Text($r('app.string.clear_logs_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.danger_red'))
          .responseRegion({ x: -8, y: -8, width: 40, height: 40 })
          .onClick(() => {
            this.discoveryLog = [];
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      // Device count
      Text($r('app.string.discovered_devices_count', this.discoveredCount))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .padding(DesignTokens.space.md)

      if (this.discoveryLog.length === 0) {
        Column() {
          Text($r('app.string.no_discovery_logs'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List() {
          ForEach(this.discoveryLog, (log: string, index: number) => {
            ListItem() {
              Text(log)
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: 6, bottom: 6 })
            }
          }, (log: string, index: number) => index.toString())
        }
        .width('100%')
        .layoutWeight(1)
      }
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
