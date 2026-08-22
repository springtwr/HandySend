import { DesignTokens } from '../common/DesignTokens';
import { DiscoveryDebugViewModel } from '../viewmodel/DiscoveryDebugViewModel';

@Entry
@ComponentV2
struct DiscoveryDebugPage {
  @Local viewModel: DiscoveryDebugViewModel = new DiscoveryDebugViewModel();

  aboutToAppear(): void {
    this.viewModel.loadInitial();
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_backward'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontColor([$r('app.color.text_primary')])
          .responseRegion({
            x: -12,
            y: -12,
            width: 48,
            height: 48
          })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.discovery_debug_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)

        // 手动广播按钮
        Text($r('app.string.announce_now_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.accent_blue'))
          .margin({ right: DesignTokens.space.md })
          .responseRegion({
            x: -8,
            y: -8,
            width: 40,
            height: 40
          })
          .onClick(() => {
            this.viewModel.triggerAnnounce();
          })

        // 清空按钮
        Text($r('app.string.clear_logs_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.danger_red'))
          .responseRegion({
            x: -8,
            y: -8,
            width: 40,
            height: 40
          })
          .onClick(() => {
            this.viewModel.clearLogs();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      // 设备数量
      Text($r('app.string.discovered_devices_count', this.viewModel.discoveredCount))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .padding(DesignTokens.space.md)

      if (this.viewModel.discoveryLog.length === 0) {
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
          Repeat(this.viewModel.discoveryLog).each((ri: RepeatItem<string>) => {
            ListItem() {
              Text(ri.item)
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding({
                  left: DesignTokens.space.md,
                  right: DesignTokens.space.md,
                  top: 6,
                  bottom: 6
                })
            }
          }).key((item: string, index: number) => index.toString())
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
    PageTransitionEnter(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
    PageTransitionEnter(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }
}
