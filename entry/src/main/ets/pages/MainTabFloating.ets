import { mediaquery, curves } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { SendContent } from '../components/SendContent';
import { ReceiveContent } from '../components/ReceiveContent';
import { SettingsContent } from '../components/SettingsContent';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';
import { initAppService, startLocalServer, stopLocalServer, subscribe, unsubscribe } from '../service/AppService';
import { DesignTokens } from '../common/DesignTokens';
import { MainTabViewModel } from '../viewmodel/MainTabViewModel';
import { FloatingTabBar } from '../views/FloatingTabBar';
import { CompletionOverlay } from '../views/CompletionOverlay';

const MAX_CONTENT_WIDTH: number = 800;

@Entry
@Component
struct MainTabFloating {
  @State viewModel: MainTabViewModel = new MainTabViewModel();
  @State private isSm: boolean = true;
  @State private isShortHeight: boolean = false;
  private hdsController: HdsTabsController = new HdsTabsController();
  private stdController: TabsController = new TabsController();
  private smListener: mediaquery.MediaQueryListener | null = null;
  private shortHeightListener: mediaquery.MediaQueryListener | null = null;
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

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    preferencesUtil.init(context);

    initAppService(context);
    startLocalServer().catch((_e: Error) => {
      // Server start failure is logged by AppService
    });

    // Bridge for the completion overlay: the VM detects one-shot transfer
    // events (auto-accepted session completed/cancelled) and delegates the
    // overlay display back to the view via this callback (UIContext boundary).
    this.viewModel.onTransferEvent = (type: string, alias: string) => {
      if (type === 'completed') {
        this.completionOverlayTitle = (this.getUIContext().getHostContext() as common.UIAbilityContext).resourceManager.getStringSync($r('app.string.recv_complete_title').id);
        this.completionOverlayMessage = (this.getUIContext().getHostContext() as common.UIAbilityContext).resourceManager.getStringSync($r('app.string.recv_complete_message').id).replace('%s', alias);
      } else {
        this.completionOverlayTitle = (this.getUIContext().getHostContext() as common.UIAbilityContext).resourceManager.getStringSync($r('app.string.send_cancelled_title').id);
        this.completionOverlayMessage = (this.getUIContext().getHostContext() as common.UIAbilityContext).resourceManager.getStringSync($r('app.string.send_cancelled_message').id).replace('%s', alias);
      }
      this.showCompletionOverlay = true;
    };

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
      let navParams: Record<string, Object | string | number | boolean | Array<string>> | undefined =
        this.viewModel.handlePendingRequests();
      if (navParams !== undefined) {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/TransferPage', params: navParams });
      }
      this.viewModel.checkTransferEvents();
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
        FloatingTabBar({
          currentIndex: this.currentTabIndex,
          offsetY: this.tabBarOffsetY,
          tabBarOpacity: this.tabBarOpacity,
          onTabChange: (index: number) => {
            this.stdController.changeIndex(index);
            this.currentTabIndex = index;
            this.showTabBar();
          }
        })
      }

      
    if (this.showCompletionOverlay) {
      CompletionOverlay({
        show: this.showCompletionOverlay,
        title: this.completionOverlayTitle,
        message: this.completionOverlayMessage,
        onDismiss: () => {
          this.showCompletionOverlay = false;
        }
      })
    }
    }
    .width('100%')
    .height('100%')
  }
}
