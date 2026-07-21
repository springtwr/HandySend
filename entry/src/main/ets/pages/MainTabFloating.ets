import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { mediaquery } from '@kit.ArkUI';
import { SendContent } from '../components/SendContent';
import { ReceiveContent } from '../components/ReceiveContent';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct MainTabFloating {
  @State private isSm: boolean = true;
  @StorageLink('nekoshare_floating') useFloating: boolean = true;
  @StorageLink('hideShareByLink') hideShareByLink: boolean = false;
  @StorageLink('encryptedTransfer') encryptedTransfer: boolean = true;
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

    this.smListener = this.getUIContext().getMediaQuery().matchMediaSync('(320vp<=width<520vp)');
    this.smListener.on('change', (result: mediaquery.MediaQueryResult) => {
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
      this.settingsContent()
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
      this.settingsContent()
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_settings_filled'), $r('app.string.tab_settings')))
  }

  @Builder
  settingsContent() {
    Column() {
      Column() {
        Text($r('app.string.settings_title'))
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#181818')
      }
      .margin({ top: 32 })
      .alignSelf(ItemAlign.Start)
      .padding({ left: 24 })

      Column() {
        Row() {
          Text($r('app.string.floating_label'))
            .fontSize(16)
            .fontColor('#181818')
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.useFloating })
            .onChange((isOn: boolean) => {
              this.useFloating = isOn;
            })
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.floating_desc'))
          .fontSize(12)
          .fontColor('#999999')
      }
      .width('100%')
      .padding({ left: 24, right: 24 })
      .margin({ top: 24 })

      Column() {
        Row() {
          Text($r('app.string.hide_share_by_link'))
            .fontSize(16)
            .fontColor('#181818')
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.hideShareByLink })
            .onChange((isOn: boolean) => {
              this.hideShareByLink = isOn;
              preferencesUtil.setBoolean('hideShareByLink', isOn);
            })
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 24, right: 24 })
      .margin({ top: 24 })

      Column() {
        Row() {
          Text($r('app.string.encrypted_transfer'))
            .fontSize(16)
            .fontColor('#181818')
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.encryptedTransfer })
            .onChange((isOn: boolean) => {
              this.encryptedTransfer = isOn;
              preferencesUtil.setBoolean('encryptedTransfer', isOn);
            })
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 24, right: 24 })
      .margin({ top: 24 })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
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
