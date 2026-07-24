import { router, mediaquery } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { SendContent } from '../components/SendContent';
import { ReceiveContent } from '../components/ReceiveContent';
import { SettingsContent } from '../components/SettingsContent';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';
import { initAppService, startLocalServer, stopLocalServer, rescanDevices,
  subscribe, unsubscribe, getPendingRequests, getDiscoveredDevices,
  respondToRequest, getLocalDeviceInfo, getDeviceType, getDeviceModel } from '../service/AppService';
import { PendingRequest, DiscoveredDevice, LocalDeviceInfo } from '../model/Types';
import { hilog } from '@kit.PerformanceAnalysisKit';

@Entry
@Component
struct MainTabFloating {
  @State private isSm: boolean = true;
  @StorageLink('nekoshare_floating') useFloating: boolean = true;
  @StorageLink('autoSaveMode') autoSaveMode: string = 'off'
  @StorageLink('favoriteDevices') favoriteDevicesJson: string = '[]'
  @StorageLink('recvTransferCompleted') recvTransferCompleted: string = ''
  @StorageLink('silentReceive') silentReceive: boolean = false
  private hdsController: HdsTabsController = new HdsTabsController();
  private stdController: TabsController = new TabsController();
  private smListener: mediaquery.MediaQueryListener | null = null;
  private requestDismissed: Record<string, boolean> = {}
  private autoAcceptedSessions: Record<string, string> = {}
  private receiveCallback: () => void = () => {}

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

    let silentReceive: boolean = preferencesUtil.getBoolean('silentReceive', false);
    AppStorage.setOrCreate('silentReceive', silentReceive);

    let enablePickerSpring: boolean = preferencesUtil.getBoolean('enablePickerSpring', true);
    AppStorage.setOrCreate('enablePickerSpring', enablePickerSpring);

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

    this.receiveCallback = () => {
      let sharedJson: string = AppStorage.get<string>('sharedFileUris') ?? '';
      hilog.info(0x0000, 'NS_SHARE_DIAG', 'receiveCallback check sharedFileUris len=%{public}d', sharedJson.length);
      if (sharedJson.length > 0) {
        AppStorage.setOrCreate('sharedFileUris', '');
        AppStorage.setOrCreate('pendingSharedUris', sharedJson);
        hilog.info(0x0000, 'NS_SHARE_DIAG', 'receiveCallback forwarded to pendingSharedUris');
      }

      let requests: Array<PendingRequest> = getPendingRequests();
      for (let i = 0; i < requests.length; i++) {
        let r: PendingRequest = requests[i];
        if (this.requestDismissed[r.sessionId] !== undefined) {
          continue;
        }
        this.requestDismissed[r.sessionId] = true;

        let autoSave: boolean = false;
        if (this.autoSaveMode === 'on') {
          autoSave = true;
        } else if (this.autoSaveMode === 'favorites') {
          let favoriteFps: Array<string> = [];
          try {
            let arr: Object = JSON.parse(this.favoriteDevicesJson);
            if (Array.isArray(arr)) {
              favoriteFps = arr as Array<string>;
            }
          } catch (_e) {}
          for (let j = 0; j < favoriteFps.length; j++) {
            if (r.senderFingerprint === favoriteFps[j]) {
              autoSave = true;
              break;
            }
          }
        }

        if (autoSave) {
          this.autoAcceptedSessions[r.sessionId] = r.senderAlias;
          respondToRequest(r.sessionId, true);
        } else {
          let devices: Array<DiscoveredDevice> = getDiscoveredDevices();
          let senderDevice: DiscoveredDevice | undefined = undefined;
          for (let k = 0; k < devices.length; k++) {
            if (devices[k].fingerprint === r.senderFingerprint) {
              senderDevice = devices[k];
              break;
            }
          }
          let senderIp: string = '';
          let senderDeviceType: string = 'mobile';
          let senderDeviceModel: string = '';
          if (senderDevice !== undefined) {
            senderIp = senderDevice.ip;
            senderDeviceType = senderDevice.deviceType;
            senderDeviceModel = senderDevice.deviceModel;
          }
          let localInfo: LocalDeviceInfo = getLocalDeviceInfo();
          let totalSize: number = 0;
          for (let k = 0; k < r.files.length; k++) {
            totalSize = totalSize + r.files[k].size;
          }
          let params: Record<string, Object | string | number | boolean | Array<string>> = {
            'mode': 'receive',
            'sourceAlias': r.senderAlias,
            'sourceIp': senderIp,
            'sourceDeviceType': senderDeviceType,
            'sourceDeviceModel': senderDeviceModel,
            'targetAlias': localInfo.alias,
            'targetIp': localInfo.ip,
            'targetDeviceType': getDeviceType(),
            'targetDeviceModel': getDeviceModel(),
            'fileUris': new Array<string>(),
            'targetPort': 0,
            'targetFingerprint': '',
            'targetProtocol': '',
            'sessionId': r.sessionId,
            'autoConfirm': false,
            'fileCount': r.files.length,
            'totalSize': totalSize
          };
          router.pushUrl({ url: 'pages/TransferPage', params: params });
        }
      }

      if (this.recvTransferCompleted.length > 0) {
        let completedId: string = this.recvTransferCompleted;
        let alias: string | undefined = this.autoAcceptedSessions[completedId];
        if (alias !== undefined && alias.length > 0) {
          this.autoAcceptedSessions[completedId] = '';
          this.recvTransferCompleted = '';
          if (!this.silentReceive) {
            AlertDialog.show({
              title: '接收完成',
              message: '来自 ' + alias + ' 的文件已接收完成',
              confirm: {
                value: '确定',
                action: () => {}
              }
            });
          }
        }
      }
    };
    subscribe(this.receiveCallback);
  }

  aboutToDisappear(): void {
    unsubscribe(this.receiveCallback);
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
