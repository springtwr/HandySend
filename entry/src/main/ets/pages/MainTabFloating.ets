import { mediaquery } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial } from '@kit.UIDesignKit';
import { SendContent } from '../components/SendContent';
import { ReceiveContent } from '../components/ReceiveContent';
import { SettingsContent } from '../components/SettingsContent';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';
import { initAppService, startLocalServer, stopLocalServer, subscribe, unsubscribe } from '../service/AppService';
import { DesignTokens } from '../common/DesignTokens';
import { MainTabViewModel } from '../viewmodel/MainTabViewModel';
import { CompletionOverlay } from '../views/CompletionOverlay';

const MAX_CONTENT_WIDTH: number = 800;

@Entry
@ComponentV2
struct MainTabFloating {
  @Local viewModel: MainTabViewModel = new MainTabViewModel();
  @Local private isSm: boolean = true;
  @Local private isShortHeight: boolean = false;
  private hdsController: HdsTabsController = new HdsTabsController();
  private smListener: mediaquery.MediaQueryListener | null = null;
  private shortHeightListener: mediaquery.MediaQueryListener | null = null;
  private receiveCallback: () => void = () => {}
  // Scrollers for bindScroller
  private sendScroller: Scroller = new Scroller()
  private receiveScroller: Scroller = new Scroller()
  private settingsScroller: Scroller = new Scroller()
  // HdsTabs scroll animation state
  @Local private isTabHidden: boolean = false

  @Local showCompletionOverlay: boolean = false
  @Local completionOverlayTitle: string = ''
  @Local completionOverlayMessage: string = ''

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

    // Bind scrollers to HdsTabsController for scroll-aware animation
    this.hdsController.bindScroller(0, this.sendScroller);
    this.hdsController.bindScroller(1, this.receiveScroller);
    this.hdsController.bindScroller(2, this.settingsScroller);
  }

  aboutToDisappear(): void {
    unsubscribe(this.receiveCallback);
    stopLocalServer();
    this.hdsController.unbindScroller(this.sendScroller);
    this.hdsController.unbindScroller(this.receiveScroller);
    this.hdsController.unbindScroller(this.settingsScroller);
    if (this.smListener !== null) {
      this.smListener.off('change');
    }
    if (this.shortHeightListener !== null) {
      this.shortHeightListener.off('change');
    }
  }

  private showTabBar(): void {
    if (this.isTabHidden) {
      this.isTabHidden = false;
      this.hdsController.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION);
    }
  }

  private hideTabBar(): void {
    if (!this.isTabHidden) {
      this.isTabHidden = true;
      this.hdsController.applyHideAnimation(HdsAnimationMode.SCROLL_ANIMATION);
    }
  }

  // deltaY: scroll delta per frame; absY: absolute scroll offset from top
  private handleScrollDelta(deltaY: number, absY: number): void {
    const SCROLL_THRESHOLD: number = 5;
    const MIN_SCROLL_TO_HIDE: number = 20;
    // At or near top → always show, never hide
    if (absY <= MIN_SCROLL_TO_HIDE) {
      this.showTabBar();
      return;
    }
    // User action sentinel (-999) → always show
    if (deltaY === -999) {
      this.showTabBar();
      return;
    }
    if (deltaY > SCROLL_THRESHOLD) {
      this.hideTabBar();
    } else if (deltaY < -SCROLL_THRESHOLD) {
      this.showTabBar();
    }
  }

  @Builder
  sendTab() {
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
    .tabBar(new BottomTabBarStyle($r('app.media.ic_tab_send'), $r('app.string.tab_send')))
  }

  @Builder
  receiveTab() {
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
    .tabBar(new BottomTabBarStyle($r('app.media.ic_tab_receive'), $r('app.string.tab_receive')))
  }

  @Builder
  settingsTab() {
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
    .tabBar(new BottomTabBarStyle($r('app.media.ic_tab_settings'), $r('app.string.tab_settings')))
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (this.isSm || this.isShortHeight) {
          HdsTabs({ controller: this.hdsController }) {
            this.sendTab()
            this.receiveTab()
            this.settingsTab()
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
            this.sendTab()
            this.receiveTab()
            this.settingsTab()
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
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))

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
