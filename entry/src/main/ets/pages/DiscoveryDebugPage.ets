import { SymbolGlyphModifier } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';
import { DiscoveryDebugViewModel } from '../viewmodel/DiscoveryDebugViewModel';

@ComponentV2
export struct DiscoveryDebugPage {
  @Local viewModel: DiscoveryDebugViewModel = new DiscoveryDebugViewModel();
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()

  aboutToAppear(): void {
    this.viewModel.loadInitial();
  }

  aboutToDisappear(): void {
    this.viewModel.destroy();
  }

  build() {
    NavDestination() {
      Column() {
        // 状态信息区
        Column() {
          // 设备数量
          Row() {
            Text($r('app.string.discovered_devices_count'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_secondary'))
            Text(' ' + this.viewModel.discoveredCount)
              .fontSize(DesignTokens.font.bodyM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')
          .padding({
            left: DesignTokens.space.md,
            right: DesignTokens.space.md,
            top: 8,
            bottom: 4
          })

          // 组播错误
          if (this.viewModel.multicastError.length > 0) {
            Row() {
              Text($r('app.string.multicast_error_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.danger_red'))
              Text(' ' + this.viewModel.multicastError)
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.danger_red'))
                .layoutWeight(1)
            }
            .width('100%')
            .padding({
              left: DesignTokens.space.md,
              right: DesignTokens.space.md,
              top: 4,
              bottom: 4
            })
          }

          // 扫描状态
          if (this.viewModel.isScanning) {
            Row() {
              LoadingProgress()
                .width(DesignTokens.size.iconXs)
                .height(DesignTokens.size.iconXs)
                .margin({ right: 6 })
              Text($r('app.string.scanning_status'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.accent_blue'))
            }
            .width('100%')
            .padding({
              left: DesignTokens.space.md,
              right: DesignTokens.space.md,
              top: 4,
              bottom: 4
            })
          }
        }
        .width('100%')

        // 日志列表
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
          .width('100%')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .title($r('app.string.discovery_debug_title'), { backgroundColor: $r('app.color.page_background') })
    .menus([
      {
        value: $r('app.string.announce_now_button'),
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.dot_radiowaves')),
        action: () => { this.viewModel.triggerAnnounce(); }
      },
      {
        value: $r('app.string.clear_logs_button'),
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.trash')),
        action: () => { this.viewModel.clearLogs(); }
      }
    ])
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}

// 路由表引用：DiscoveryDebugPageBuilder(name, param)
@Builder
export function DiscoveryDebugPageBuilder(_name: string, _param: Object) {
  DiscoveryDebugPage()
}
