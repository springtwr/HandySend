import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { mediaquery } from '@kit.ArkUI';
import { SendContent } from '../components/SendContent';
import { ReceiveContent } from '../components/ReceiveContent';
import { SettingsContent } from '../components/SettingsContent';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';
import { initAppService, startLocalServer, stopLocalServer, rescanDevices } from '../service/AppService';

@Entry
@Component
struct MainTabFloating {
  @State private isSm: boolean = true;
  @StorageLink('nekoshare_floating') useFloating: boolean = true;
  private hdsController: HdsTabsController = new HdsTabsController();
  private stdController: TabsController = new TabsController();
  private smListener: mediaquery.MediaQueryListener | null = null;

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
    this.smListener.on('change', (result: mediaquery.MediaQueryResult) => {
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
  hdsSendTab() {
    TabContent() {
      SendContent()
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_send_filled'), $r('app.string.tab_send')))
  }

  @Builder
  hdsReceiveTab() {
    TabContent() {
      ReceiveContent()
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_connection_filled'), $r('app.string.tab_receive')))
  }

  @Builder
  hdsSettingsTab() {
    TabContent() {
      SettingsContent({ showFloatingOption: true })
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_settings_filled'), $r('app.string.tab_settings')))
  }

  @Builder
  stdSendTab() {
    TabContent() {
      SendContent()
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_send_filled'), $r('app.string.tab_send')))
  }

  @Builder
  stdReceiveTab() {
    TabContent() {
      ReceiveContent()
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_connection_filled'), $r('app.string.tab_receive')))
  }

  @Builder
  stdSettingsTab() {
    TabContent() {
      SettingsContent({ showFloatingOption: true })
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_settings_filled'), $r('app.string.tab_settings')))
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

  build() {
    Column() {
      if (this.useFloating) {
        if (this.isSm) {
          HdsTabs({ controller: this.hdsController }) {
            this.hdsSendTab()
            this.hdsReceiveTab()
            this.hdsSettingsTab()
          }
          .barOverlap(true)
          .barPosition(BarPosition.End)
          .vertical(false)
          .barFloatingStyle({
            barBottomMargin: 28,
            gradientMask: {
              maskColor: '#66F1F3F5',
              maskHeight: 92
            },
            systemMaterialEffect: {
              materialType: hdsMaterial.MaterialType.ADAPTIVE,
              materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
            }
          })
          .width('100%')
          .height('100%')
        } else {
          HdsTabs({ controller: this.hdsController }) {
            this.hdsSendTab()
            this.hdsReceiveTab()
            this.hdsSettingsTab()
          }
          .barPosition(BarPosition.Start)
          .vertical(true)
          .barWidth(96)
          .width('100%')
          .height('100%')
        }
      } else {
        if (this.isSm) {
          Tabs({ barPosition: BarPosition.End, controller: this.stdController }) {
            this.stdSendTab()
            this.stdReceiveTab()
            this.stdSettingsTab()
          }
          .width('100%')
          .height('100%')
        } else {
          Tabs({ barPosition: BarPosition.Start, controller: this.stdController }) {
            this.stdSendTab()
            this.stdReceiveTab()
            this.stdSettingsTab()
          }
          .vertical(true)
          .barWidth(96)
          .width('100%')
          .height('100%')
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }
}
