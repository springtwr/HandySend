import mediaQuery from '@ohos.mediaquery';
import { SendContent } from '../components/SendContent';
import { ReceiveContent } from '../components/ReceiveContent';
import { SettingsContent } from '../components/SettingsContent';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';
import { initAppService, startLocalServer, stopLocalServer, rescanDevices } from '../service/AppService';

const MAX_CONTENT_WIDTH: number = 800;

@Entry
@Component
struct MainPage {
  @State private isSm: boolean = true;
  private controller: TabsController = new TabsController();
  private smListener: mediaQuery.MediaQueryListener | null = null;

  aboutToAppear(): void {
    let context = getContext() as common.UIAbilityContext;
    preferencesUtil.init(context);
    let hideShareByLink: boolean = preferencesUtil.getBoolean('hideShareByLink', false);
    AppStorage.setOrCreate('hideShareByLink', hideShareByLink);

    let autoSaveMode: string = preferencesUtil.getString('autoSaveMode', 'off');
    AppStorage.setOrCreate('autoSaveMode', autoSaveMode);

    let favoriteDevices: string = preferencesUtil.getString('favoriteDevices', '[]');
    AppStorage.setOrCreate('favoriteDevices', favoriteDevices);

    let encryptedTransfer: boolean = preferencesUtil.getBoolean('encryptedTransfer', true);
    AppStorage.setOrCreate('encryptedTransfer', encryptedTransfer);

    AppStorage.setOrCreate('serverReady', false);
    initAppService(context);
    startLocalServer().then(() => {
      AppStorage.setOrCreate('serverReady', true);
      rescanDevices();
    });

    this.smListener = this.getUIContext().getMediaQuery().matchMediaSync('(320vp<=width<520vp)');
    this.smListener.on('change', (result: mediaQuery.MediaQueryResult) => {
      this.isSm = result.matches;
    });
    this.isSm = this.smListener.matches;
  }

  aboutToDisappear(): void {
    stopLocalServer();
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
      Row() {
        Column() {
          SendContent()
        }
        .width(this.isSm ? '100%' : MAX_CONTENT_WIDTH)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_send_filled'), $r('app.string.tab_send')))
  }

  @Builder
  receiveTab() {
    TabContent() {
      Row() {
        Column() {
          ReceiveContent()
        }
        .width(this.isSm ? '100%' : MAX_CONTENT_WIDTH)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_connection_filled'), $r('app.string.tab_receive')))
  }

  @Builder
  settingsTab() {
    TabContent() {
      Row() {
        Column() {
          SettingsContent()
        }
        .width(this.isSm ? '100%' : MAX_CONTENT_WIDTH)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
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
