import { mediaquery } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial } from '@kit.UIDesignKit';
import { SendContent } from '../components/SendContent';
import { ReceiveContent } from '../components/ReceiveContent';
import { SettingsContent } from '../components/SettingsContent';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';
import {
  initAppService,
  startLocalServer,
  stopLocalServer,
  subscribe,
  unsubscribe,
  isHideTabBarOnScroll
} from '../service/AppService';
import { DesignTokens } from '../common/DesignTokens';
import { MainTabViewModel } from '../viewmodel/MainTabViewModel';
import { CompletionOverlay } from '../views/CompletionOverlay';
import { getStringSync } from '../utils/ResourceUtil';

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
  private receiveCallback: () => void = () => {
  }
  // 用于 bindScroller 的滚动容器
  private sendScroller: Scroller = new Scroller()
  private receiveScroller: Scroller = new Scroller()
  private settingsScroller: Scroller = new Scroller()
  // HdsTabs 滚动动画状态
  @Local private isTabHidden: boolean = false
  @Local showCompletionOverlay: boolean = false
  @Local completionOverlayTitle: string = ''
  @Local completionOverlayMessage: string = ''

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    preferencesUtil.init(context);

    initAppService(context);
    startLocalServer().catch((_e: Error) => {
      // 服务器启动失败由 AppService 记录日志
    });

    // 完成浮层的桥接：VM 检测一次性传输
    // 事件（自动接收的会话完成/取消）并将
    // 通过此回调将浮层展示交还给视图（UIContext 边界）。
    this.viewModel.onTransferEvent = (type: string, alias: string) => {
      if (type === 'completed') {
        this.completionOverlayTitle = getStringSync(this.getUIContext(), $r('app.string.recv_complete_title'));
        this.completionOverlayMessage = getStringSync(this.getUIContext(), $r('app.string.recv_complete_message'))
          .replace('%s', alias);
      } else {
        this.completionOverlayTitle = getStringSync(this.getUIContext(), $r('app.string.send_cancelled_title'));
        this.completionOverlayMessage = getStringSync(this.getUIContext(), $r('app.string.send_cancelled_message'))
          .replace('%s', alias);
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

    // 将滚动容器绑定到 HdsTabsController 以实现滚动感知动画
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

  // deltaY：每帧滚动增量；absY：距顶部的绝对滚动偏移
  private handleScrollDelta(deltaY: number, absY: number): void {
    const SCROLL_THRESHOLD: number = 5;
    const MIN_SCROLL_TO_HIDE: number = 20;
    // 开关关闭时（默认）页签始终显示，不随滚动隐藏
    if (!isHideTabBarOnScroll()) {
      this.showTabBar();
      return;
    }
    // 位于或接近顶部 → 始终显示，永不隐藏
    if (absY <= MIN_SCROLL_TO_HIDE) {
      this.showTabBar();
      return;
    }
    // 用户动作哨兵值（-999）→ 始终显示
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
          SendContent({
            onScrollDelta: (deltaY: number, absY: number) => {
              this.handleScrollDelta(deltaY, absY)
            }
          })
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
          ReceiveContent({
            onScrollDelta: (deltaY: number, absY: number) => {
              this.handleScrollDelta(deltaY, absY)
            }
          })
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
          SettingsContent({
            onScrollDelta: (deltaY: number, absY: number) => {
              this.handleScrollDelta(deltaY, absY)
            }
          })
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
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

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

  pageTransition() {
    PageTransitionEnter(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
    PageTransitionEnter(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }
}
