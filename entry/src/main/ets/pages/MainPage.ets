import mediaQuery from '@ohos.mediaquery';

@Entry
@Component
struct MainPage {
  @State private isSm: boolean = true;
  private controller: TabsController = new TabsController();
  private smListener: mediaQuery.MediaQueryListener | null = null;

  aboutToAppear(): void {
    this.smListener = this.getUIContext().getMediaQuery().matchMediaSync('(320vp<=width<520vp)');
    this.smListener.on('change', (result: mediaQuery.MediaQueryResult) => {
      this.isSm = result.matches;
    });
    this.isSm = this.smListener.matches;
  }

  aboutToDisappear(): void {
    if (this.smListener !== null) {
      this.smListener.off('change');
    }
  }

  @Builder
  emptyPage(title: ResourceStr, subtitle: ResourceStr) {
    Column() {
      Text(title)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor('#181818')
      Text(subtitle)
        .fontSize(14)
        .fontColor('#999999')
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  sendTab() {
    TabContent() {
      this.emptyPage($r('app.string.tab_send'), $r('app.string.send_subtitle'))
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_send_filled'), $r('app.string.tab_send')))
  }

  @Builder
  receiveTab() {
    TabContent() {
      this.emptyPage($r('app.string.tab_receive'), $r('app.string.receive_subtitle'))
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_connection_filled'), $r('app.string.tab_receive')))
  }

  @Builder
  settingsTab() {
    TabContent() {
      this.emptyPage($r('app.string.tab_settings'), $r('app.string.settings_subtitle'))
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_settings_filled'), $r('app.string.tab_settings')))
  }

  build() {
    Column() {
      if (this.isSm) {
        Tabs({ barPosition: BarPosition.End, controller: this.controller }) {
          this.sendTab()
          this.receiveTab()
          this.settingsTab()
        }
        .width('100%')
        .height('100%')
      } else {
        Tabs({ barPosition: BarPosition.Start, controller: this.controller }) {
          this.sendTab()
          this.receiveTab()
          this.settingsTab()
        }
        .vertical(true)
        .barWidth(96)
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }
}
