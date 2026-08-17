import { mediaquery, curves } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { SendContent } from '../components/SendContent';
import { ReceiveContent } from '../components/ReceiveContent';
import { SettingsContent } from '../components/SettingsContent';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';
import { initAppService, startLocalServer, stopLocalServer, rescanDevices,
  subscribe, unsubscribe, getPendingRequests, getDiscoveredDevices,
  respondToRequest, getLocalDeviceInfo, getDeviceType, getDeviceModel } from '../service/AppService';
import { PendingRequest, DiscoveredDevice, LocalDeviceInfo, FavoriteDevice } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';

const MAX_CONTENT_WIDTH: number = 800;

@Entry
@Component
struct MainTabFloating {
  @State private isSm: boolean = true;
  @State private isShortHeight: boolean = false;
  @StorageLink('autoSaveMode') autoSaveMode: string = 'off'
  @StorageLink('favoriteDevices') favoriteDevicesJson: string = '[]'
  @StorageLink('recvTransferCompleted') @Watch('onRecvCompleted') recvTransferCompleted: string = ''
  @StorageLink('recvTransferCancelled') @Watch('onRecvCancelled') recvTransferCancelled: string = ''
  @StorageLink('silentReceive') silentReceive: boolean = true
  private hdsController: HdsTabsController = new HdsTabsController();
  private stdController: TabsController = new TabsController();
  private smListener: mediaquery.MediaQueryListener | null = null;
  private shortHeightListener: mediaquery.MediaQueryListener | null = null;
  private requestDismissed: Record<string, boolean> = {}
  private autoAcceptedSessions: Record<string, string> = {}
  private receiveCallback: () => void = () => {}
  // Scrollers for bindScroller (HdsTabs API >23)
  private sendScroller: Scroller = new Scroller()
  private receiveScroller: Scroller = new Scroller()
  private settingsScroller: Scroller = new Scroller()
  // Whether device supports HdsTabs scroll animation (API >23)
  private readonly useHdsTabs: boolean = deviceInfo.sdkApiVersion > 23
  // HdsTabs scroll animation state
  @State private isTabHidden: boolean = false
  // Manual floating tab bar state (API ≤23)
  @State private tabBarOffsetY: number = 0
  @State private tabBarOpacity: number = 1
  @State private currentTabIndex: number = 0
  private readonly TAB_BAR_HEIGHT: number = 56
  private readonly SCROLL_THRESHOLD: number = 5
  private readonly MIN_SCROLL_TO_HIDE: number = 20
  private lastToggleTime: number = 0
  private readonly TOGGLE_DEBOUNCE_MS: number = 300

  @State showCompletionOverlay: boolean = false
  @State completionOverlayTitle: string = ''
  @State completionOverlayMessage: string = ''
  @State checkScale: number = 0

  onRecvCompleted(): void {
    hilog.info(0x0001, 'LocalSend:MainTab', '[onRecvCompleted] val=%{public}s', this.recvTransferCompleted);
    if (this.recvTransferCompleted.length === 0) {
      return;
    }
    let completedId: string = this.recvTransferCompleted;
    let alias: string | undefined = this.autoAcceptedSessions[completedId];
    hilog.info(0x0001, 'LocalSend:MainTab', '[onRecvCompleted] id=%{public}s alias=%{public}s',
      completedId.substring(0, 8), alias ?? 'undefined');
    if (alias === undefined || alias.length === 0) {
      return;
    }
    this.autoAcceptedSessions[completedId] = '';
    AppStorage.setOrCreate('recvTransferCompleted', '');
    if (!this.silentReceive) {
      this.completionOverlayTitle = (this.getUIContext().getHostContext() as common.UIAbilityContext).resourceManager.getStringSync($r('app.string.recv_complete_title').id);
      this.completionOverlayMessage = (this.getUIContext().getHostContext() as common.UIAbilityContext).resourceManager.getStringSync($r('app.string.recv_complete_message').id).replace('%s', alias);
      this.checkScale = 0;
      this.showCompletionOverlay = true;
    }
  }

  onRecvCancelled(): void {
    hilog.info(0x0001, 'LocalSend:MainTab', '[onRecvCancelled] val=%{public}s', this.recvTransferCancelled);
    if (this.recvTransferCancelled.length === 0) {
      return;
    }
    let cancelledId: string = this.recvTransferCancelled;
    let alias: string | undefined = this.autoAcceptedSessions[cancelledId];
    hilog.info(0x0001, 'LocalSend:MainTab', '[onRecvCancelled] id=%{public}s alias=%{public}s',
      cancelledId.substring(0, 8), alias ?? 'undefined');
    if (alias === undefined || alias.length === 0) {
      return;
    }
    this.autoAcceptedSessions[cancelledId] = '';
    AppStorage.setOrCreate('recvTransferCancelled', '');
    if (!this.silentReceive) {
      this.completionOverlayTitle = (this.getUIContext().getHostContext() as common.UIAbilityContext).resourceManager.getStringSync($r('app.string.send_cancelled_title').id);
      this.completionOverlayMessage = (this.getUIContext().getHostContext() as common.UIAbilityContext).resourceManager.getStringSync($r('app.string.send_cancelled_message').id).replace('%s', alias);
      this.checkScale = 0;
      this.showCompletionOverlay = true;
    }
  }

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    preferencesUtil.init(context);

    // All AppStorage initialization is now handled by AppService.initAppService()
    // to avoid duplicate writes with inconsistent default values

    initAppService(context);
    startLocalServer().catch((_e: Error) => {
      // Server start failure is logged by AppService
    });

    this.smListener = this.getUIContext().getMediaQuery().matchMediaSync('(320vp<=width<520vp)');
    this.smListener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isSm = result.matches;
    });
    this.isSm = this.smListener.matches;

    this.shortHeightListener = this.getUIContext().getMediaQuery().matchMediaSync('(height<600vp)');
    this.shortHeightListener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isShortHeight = result.matches;
    });
    this.isShortHeight = this.shortHeightListener.matches;

    this.receiveCallback = () => {
      let sharedJson: string = AppStorage.get<string>('sharedFileUris') ?? '';
      if (sharedJson.length > 0) {
        AppStorage.setOrCreate('sharedFileUris', '');
        AppStorage.setOrCreate('pendingSharedUris', sharedJson);
      }

      let requests: Array<PendingRequest> = getPendingRequests();
      for (let i = 0; i < requests.length; i++) {
        let r: PendingRequest = requests[i];
        if (this.requestDismissed[r.sessionId] !== undefined) {
          continue;
        }
        this.requestDismissed[r.sessionId] = true;

        let clipboardPreview: string = '';
        if (r.files.length === 1
          && r.files[0].fileType === 'text/plain'
          && r.files[0].preview !== undefined
          && r.files[0].preview.length > 0) {
          clipboardPreview = r.files[0].preview;
        }
        let isClipboard: boolean = clipboardPreview.length > 0;

        let autoSave: boolean = false;
        if (!isClipboard) {
          if (this.autoSaveMode === 'on') {
            autoSave = true;
          } else if (this.autoSaveMode === 'paired') {
            try {
              let favs: Array<FavoriteDevice> = JSON.parse(this.favoriteDevicesJson) as Array<FavoriteDevice>;
              for (let j = 0; j < favs.length; j++) {
                if (r.senderFingerprint === favs[j].fingerprint) {
                  autoSave = true;
                  break;
                }
              }
            } catch (_e) {}
          }
        }

        if (autoSave) {
          this.autoAcceptedSessions[r.sessionId] = r.senderAlias;
          hilog.info(0x0001, 'LocalSend:MainTabFloating',
            '[diag] auto-accept session=%{public}s alias=%{public}s', r.sessionId, r.senderAlias);
          let allFileIds: Array<string> = [];
          for (let j = 0; j < r.files.length; j++) {
            allFileIds.push(r.files[j].fileId);
          }
          respondToRequest(r.sessionId, true, allFileIds);
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
          let allFileIds: Array<string> = [];
          for (let k = 0; k < r.files.length; k++) {
            totalSize = totalSize + r.files[k].size;
            if (!isClipboard) {
              allFileIds.push(r.files[k].fileId);
            }
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
            'targetFingerprint': r.senderFingerprint,
            'targetProtocol': senderDevice !== undefined ? senderDevice.protocol : '',
            'sessionId': r.sessionId,
            'autoConfirm': isClipboard,
            'fileCount': r.files.length,
            'totalSize': totalSize,
            'isClipboard': isClipboard,
            'clipboardContent': clipboardPreview,
            'acceptedFileIds': allFileIds
          };
          this.getUIContext().getRouter().pushUrl({ url: 'pages/TransferPage', params: params });
        }
      }
    };
    subscribe(this.receiveCallback);

    // Bind scrollers to HdsTabsController for scroll-aware animation (API >23)
    if (this.useHdsTabs) {
      this.hdsController.bindScroller(0, this.sendScroller);
      this.hdsController.bindScroller(1, this.receiveScroller);
      this.hdsController.bindScroller(2, this.settingsScroller);
    }
  }

  aboutToDisappear(): void {
    unsubscribe(this.receiveCallback);
    stopLocalServer();
    if (this.useHdsTabs) {
      this.hdsController.unbindScroller(this.sendScroller);
      this.hdsController.unbindScroller(this.receiveScroller);
      this.hdsController.unbindScroller(this.settingsScroller);
    }
    if (this.smListener !== null) {
      this.smListener.off('change');
    }
    if (this.shortHeightListener !== null) {
      this.shortHeightListener.off('change');
    }
  }

  private showTabBar(fromUserAction: boolean = false): void {
    if (this.useHdsTabs) {
      if (this.isTabHidden) {
        this.isTabHidden = false;
        this.hdsController.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION);
      }
    } else {
      if (this.tabBarOffsetY !== 0) {
        this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
          this.tabBarOffsetY = 0;
          this.tabBarOpacity = 1;
        });
      }
    }
  }

  private hideTabBar(): void {
    if (this.useHdsTabs) {
      if (!this.isTabHidden) {
        this.isTabHidden = true;
        this.hdsController.applyHideAnimation(HdsAnimationMode.SCROLL_ANIMATION);
      }
    } else {
      if (this.tabBarOffsetY === 0) {
        this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
          this.tabBarOffsetY = this.TAB_BAR_HEIGHT;
          this.tabBarOpacity = 0;
        });
      }
    }
  }

  // deltaY: scroll delta per frame; absY: absolute scroll offset from top
  private handleScrollDelta(deltaY: number, absY: number): void {
    // At or near top → always show, never hide
    if (absY <= this.MIN_SCROLL_TO_HIDE) {
      this.showTabBar();
      return;
    }
    // User action sentinel (-999) → always show
    if (deltaY === -999) {
      this.showTabBar();
      return;
    }
    if (deltaY > this.SCROLL_THRESHOLD) {
      this.hideTabBar();
    } else if (deltaY < -this.SCROLL_THRESHOLD) {
      this.showTabBar();
    }
  }

  @Builder
  hdsSendTab() {
    TabContent() {
      Row() {
        Column() {
          SendContent({ onScrollDelta: (deltaY: number, absY: number) => { this.handleScrollDelta(deltaY, absY) } })
        }
        .width('100%')
        .constraintSize({ maxWidth: MAX_CONTENT_WIDTH })
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_send_filled'), $r('app.string.tab_send')))
  }

  @Builder
  hdsReceiveTab() {
    TabContent() {
      Row() {
        Column() {
          ReceiveContent({ onScrollDelta: (deltaY: number, absY: number) => { this.handleScrollDelta(deltaY, absY) } })
        }
        .width('100%')
        .constraintSize({ maxWidth: MAX_CONTENT_WIDTH })
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_connection_filled'), $r('app.string.tab_receive')))
  }

  @Builder
  hdsSettingsTab() {
    TabContent() {
      Row() {
        Column() {
          SettingsContent({ onScrollDelta: (deltaY: number, absY: number) => { this.handleScrollDelta(deltaY, absY) } })
        }
        .width('100%')
        .constraintSize({ maxWidth: MAX_CONTENT_WIDTH })
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_public_settings_filled'), $r('app.string.tab_settings')))
  }

  @Builder
  stdSendTab() {
    TabContent() {
      Row() {
        Column() {
          SendContent({ onScrollDelta: (deltaY: number, absY: number) => { this.handleScrollDelta(deltaY, absY) } })
        }
        .width('100%')
        .constraintSize({ maxWidth: MAX_CONTENT_WIDTH })
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .tabBar($r('app.string.tab_send'))
  }

  @Builder
  stdReceiveTab() {
    TabContent() {
      Row() {
        Column() {
          ReceiveContent({ onScrollDelta: (deltaY: number, absY: number) => { this.handleScrollDelta(deltaY, absY) } })
        }
        .width('100%')
        .constraintSize({ maxWidth: MAX_CONTENT_WIDTH })
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .tabBar($r('app.string.tab_receive'))
  }

  @Builder
  stdSettingsTab() {
    TabContent() {
      Row() {
        Column() {
          SettingsContent({ onScrollDelta: (deltaY: number, absY: number) => { this.handleScrollDelta(deltaY, absY) } })
        }
        .width('100%')
        .constraintSize({ maxWidth: MAX_CONTENT_WIDTH })
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .tabBar($r('app.string.tab_settings'))
  }

  @Builder
  customFloatingTabBar() {
    Row() {
      Column() {
        Image($r('app.media.ic_public_send_filled'))
          .width(24)
          .height(24)
          .fillColor(this.currentTabIndex === 0 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
        Text($r('app.string.tab_send'))
          .fontSize(DesignTokens.font.captionM)
          .fontColor(this.currentTabIndex === 0 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .height('100%')
      .onClick(() => {
        this.stdController.changeIndex(0);
        this.currentTabIndex = 0;
        this.showTabBar();
      })

      Column() {
        Image($r('app.media.ic_public_connection_filled'))
          .width(24)
          .height(24)
          .fillColor(this.currentTabIndex === 1 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
        Text($r('app.string.tab_receive'))
          .fontSize(DesignTokens.font.captionM)
          .fontColor(this.currentTabIndex === 1 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .height('100%')
      .onClick(() => {
        this.stdController.changeIndex(1);
        this.currentTabIndex = 1;
        this.showTabBar();
      })

      Column() {
        Image($r('app.media.ic_public_settings_filled'))
          .width(24)
          .height(24)
          .fillColor(this.currentTabIndex === 2 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
        Text($r('app.string.tab_settings'))
          .fontSize(DesignTokens.font.captionM)
          .fontColor(this.currentTabIndex === 2 ? $r('app.color.accent_blue') : $r('app.color.tab_icon_inactive'))
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .height('100%')
      .onClick(() => {
        this.stdController.changeIndex(2);
        this.currentTabIndex = 2;
        this.showTabBar();
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
    .offset({ y: this.tabBarOffsetY })
  }

  @Builder
  emptyPage(title: ResourceStr, subtitle: ResourceStr) {
    Column() {
      Text(title)
        .fontSize(DesignTokens.font.titleM)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.tab_text_active'))
      Text(subtitle)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: DesignTokens.space.xs })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (this.useHdsTabs) {
          // API >23: HdsTabs with built-in floating style and scroll animation
          if (this.isSm || this.isShortHeight) {
            HdsTabs({ controller: this.hdsController }) {
              this.hdsSendTab()
              this.hdsReceiveTab()
              this.hdsSettingsTab()
            }
            .animationDuration(DesignTokens.animation.durationNormal)
            .barHeight(56)
            .barOverlap(true)
            .barPosition(BarPosition.End)
            .vertical(false)
            .barFloatingStyle({
              barBottomMargin: 28,
              gradientMask: {
                maskColor: $r('app.color.gradient_mask'),
                maskHeight: 92
              },
              systemMaterialEffect: {
                materialType: hdsMaterial.MaterialType.ADAPTIVE,
                materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
              }
            })
            .onChange((_index: number) => {
              this.showTabBar();
            })
            .width('100%')
            .height('100%')
          } else {
            HdsTabs({ controller: this.hdsController }) {
              this.hdsSendTab()
              this.hdsReceiveTab()
              this.hdsSettingsTab()
            }
            .animationDuration(DesignTokens.animation.durationNormal)
            .barPosition(BarPosition.Start)
            .vertical(true)
            .barWidth(96)
            .onChange((_index: number) => {
              this.showTabBar();
            })
            .width('100%')
            .height('100%')
          }
        } else {
          // API ≤23: Standard Tabs + custom floating tab bar in Stack
          if (this.isSm || this.isShortHeight) {
            Tabs({ barPosition: BarPosition.End, controller: this.stdController }) {
              this.stdSendTab()
              this.stdReceiveTab()
              this.stdSettingsTab()
            }
            .barHeight(0)
            .onChange((index: number) => {
              this.currentTabIndex = index;
              this.showTabBar();
            })
            .width('100%')
            .height('100%')
          } else {
            Tabs({ barPosition: BarPosition.Start, controller: this.stdController }) {
              this.stdSendTab()
              this.stdReceiveTab()
              this.stdSettingsTab()
            }
            .animationDuration(DesignTokens.animation.durationNormal)
            .vertical(true)
            .barWidth(96)
            .onChange((index: number) => {
              this.currentTabIndex = index;
            })
            .width('100%')
            .height('100%')
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))

      // Custom floating tab bar overlay (API ≤23, phone layout only)
      if (!this.useHdsTabs && (this.isSm || this.isShortHeight)) {
        this.customFloatingTabBar()
      }

      if (this.showCompletionOverlay) {
        Column() {
          Column() {
            Image($r('app.media.ic_public_ok_filled'))
              .width(64)
              .height(64)
              .fillColor($r('app.color.success_green'))
              .scale({ x: this.checkScale, y: this.checkScale })
              .onAppear(() => {
                setTimeout(() => {
                  this.getUIContext().animateTo({ duration: 500, curve: curves.springMotion(DesignTokens.animation.springStiffness, DesignTokens.animation.springDamping) }, () => {
                    this.checkScale = 1;
                  });
                }, 200);
              })

            Text(this.completionOverlayTitle)
              .fontSize(DesignTokens.font.titleS)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .margin({ top: DesignTokens.space.md })

            Text(this.completionOverlayMessage)
              .fontSize(DesignTokens.font.subtitleM)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
              .margin({ top: DesignTokens.space.xs })

            Button($r('app.string.dialog_confirm'))
              .width('80%')
              .height(DesignTokens.hotspot.minSize)
              .fontSize(DesignTokens.font.subtitleM)
              .fontColor($r('app.color.text_on_color'))
              .backgroundColor($r('app.color.accent_blue'))
              .borderRadius(DesignTokens.radius.max)
              .margin({ top: DesignTokens.space.xl })
              .onClick(() => {
                this.showCompletionOverlay = false;
              })
          }
          .width('80%')
          .constraintSize({ maxWidth: 360 })
          .padding({ top: DesignTokens.space.xl, bottom: 28, left: DesignTokens.space.lg, right: DesignTokens.space.lg })
          .borderRadius(DesignTokens.radius.lg)
          .backgroundColor($r('app.color.card_background'))
          .shadow({ radius: 20, color: $r('app.color.shadow_color'), offsetY: 4 })
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.overlay_mask'))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => {
          this.showCompletionOverlay = false;
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
