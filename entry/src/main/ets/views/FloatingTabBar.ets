import { DesignTokens } from '../common/DesignTokens';

// 浮动 Tab 栏（API ≤23 手机布局，从 MainTabFloating.customFloatingTabBar 拆出）。
// 纯展示 + Tab 切换回调上抛（父组件持有 TabsController）。
@Component
export struct FloatingTabBar {
  @Prop currentIndex: number = 0
  @Prop offsetY: number = 0
  @Prop tabBarOpacity: number = 1
  onTabChange?: (index: number) => void

  private readonly TAB_BAR_HEIGHT: number = 56

  build() {
    Row() {
      Column() {
        Image($r('app.media.ic_public_send_filled'))
          .width(24)
          .height(24)
          .fillColor(this.currentIndex === 0 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
        Text($r('app.string.tab_send'))
          .fontSize(DesignTokens.font.captionM)
          .fontColor(this.currentIndex === 0 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .height('100%')
      .onClick(() => {
        if (this.onTabChange !== undefined) {
          this.onTabChange(0);
        }
      })

      Column() {
        Image($r('app.media.ic_public_connection_filled'))
          .width(24)
          .height(24)
          .fillColor(this.currentIndex === 1 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
        Text($r('app.string.tab_receive'))
          .fontSize(DesignTokens.font.captionM)
          .fontColor(this.currentIndex === 1 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .height('100%')
      .onClick(() => {
        if (this.onTabChange !== undefined) {
          this.onTabChange(1);
        }
      })

      Column() {
        Image($r('app.media.ic_public_settings_filled'))
          .width(24)
          .height(24)
          .fillColor(this.currentIndex === 2 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
        Text($r('app.string.tab_settings'))
          .fontSize(DesignTokens.font.captionM)
          .fontColor(this.currentIndex === 2 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .height('100%')
      .onClick(() => {
        if (this.onTabChange !== undefined) {
          this.onTabChange(2);
        }
      })
    }
    .width('70%')
    .height(this.TAB_BAR_HEIGHT)
    .backgroundColor($r('app.color.floating_bar_bg'))
    .borderRadius(DesignTokens.radius.max)
    .shadow({ radius: 16, color: $r('app.color.shadow_color'), offsetY: 2 })
    .backgroundBlurStyle(BlurStyle.Thin)
    .justifyContent(FlexAlign.SpaceAround)
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 28 })
    .opacity(this.tabBarOpacity)
    .offset({ y: this.offsetY })
  }
}
