import { mediaquery, uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial } from '@kit.UIDesignKit';
import { getPageContentMaxWidth, getPageMargin, isNarrowWidth, isWideWidth } from '../common/Breakpoints';
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
  isHideTabBarOnScroll,
  subscribeMtaReceiveRequest,
  unsubscribeMtaReceiveRequest,
  startMtaDiscoveryScan,
  stopMtaDiscoveryScan
} from '../service/AppService';
import { DesignTokens } from '../common/DesignTokens';
import { MainTabViewModel } from '../viewmodel/MainTabViewModel';
import { buildMtaReceivePageParams } from '../model/mta/MtaMainModels';

@Entry
@ComponentV2
struct MainTabFloating {
  // 系统宽度断点（@Env 随窗口尺寸变化自动刷新，宽 320vp~520vp 范围）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: MainTabViewModel = new MainTabViewModel();
  @Local private isShortHeight: boolean = false;
  private hdsController: HdsTabsController = new HdsTabsController();
  private shortHeightListener: mediaquery.MediaQueryListener | null = null;
  private receiveCallback: () => void = () => {
  }
  // MTA 接收请求到达回调（经 MtaRepository 事件总线触发，导航到 MTA 传输页接收模式）
  private mtaReceiveCallback: () => void = () => {
  }
  // 用于 bindScroller 的滚动容器
  private sendScroller: Scroller = new Scroller()
  private receiveScroller: Scroller = new Scroller()
  private settingsScroller: Scroller = new Scroller()
  // HdsTabs 滚动动画状态
  @Local private isTabHidden: boolean = false
  // 当前激活的主页 Tab 索引（默认发送页 0）
  private currentTabIndex: number = 0
  // Navigation 首页栏（Tab 区域）是否可见：推入子页面后为 false
  private navBarVisible: boolean = true
  // Navigation 根容器路由栈
  private pathStack: NavPathStack = new NavPathStack()

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    preferencesUtil.init(context);

    initAppService(context);
    startLocalServer().catch((_e: Error) => {
      // 服务器启动失败由 AppService 记录日志
    });

    this.shortHeightListener = this.getUIContext().getMediaQuery().matchMediaSync('(height<600vp)');
    this.shortHeightListener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isShortHeight = result.matches;
    });
    this.isShortHeight = this.shortHeightListener.matches;

    this.receiveCallback = () => {
      let navParams: Record<string, Object | string | number | boolean | Array<string>> | undefined =
        this.viewModel.handlePendingRequests();
      if (navParams !== undefined) {
        this.pathStack.pushPathByName('TransferPage', navParams);
      }
    };
    subscribe(this.receiveCallback);

    // 订阅 MTA 接收请求：收到互传联盟设备传输请求时导航到 MTA 传输页（接收模式）
    this.mtaReceiveCallback = () => {
      this.pathStack.pushPathByName('MtaTransferPage', buildMtaReceivePageParams());
    };
    subscribeMtaReceiveRequest(this.mtaReceiveCallback);

    // 将滚动容器绑定到 HdsTabsController 以实现滚动感知动画
    this.hdsController.bindScroller(0, this.sendScroller);
    this.hdsController.bindScroller(1, this.receiveScroller);
    this.hdsController.bindScroller(2, this.settingsScroller);
  }

  aboutToDisappear(): void {
    unsubscribe(this.receiveCallback);
    unsubscribeMtaReceiveRequest(this.mtaReceiveCallback);
    stopLocalServer();
    this.hdsController.unbindScroller(this.sendScroller);
    this.hdsController.unbindScroller(this.receiveScroller);
    this.hdsController.unbindScroller(this.settingsScroller);
    if (this.shortHeightListener !== null) {
      this.shortHeightListener.off('change');
    }
  }

  // 互传发现扫描随发送页可见性启停：仅首页 Tab 区域可见且发送页激活时扫描，其余情况停止
  private updateMtaScanByVisibility(): void {
    if (this.navBarVisible && this.currentTabIndex === 0) {
      startMtaDiscoveryScan();
    } else {
      stopMtaDiscoveryScan();
    }
  }

  onPageShow(): void {
    this.updateMtaScanByVisibility();
  }

  onPageHide(): void {
    stopMtaDiscoveryScan();
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

    // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    return getPageContentMaxWidth(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType);
  }

  // 主页面 Tab 内容水平边距：手机（sm）保持原贴边设计（0）；md 及以上按断点取页边距（24/32vp）
  private getTabContentMargin(): number {
    if (isNarrowWidth(this.breakpointInfo.widthBreakpoint)) {
      return 0;
    }
    return getPageMargin(this.breakpointInfo.widthBreakpoint);
  }

  @Builder
  sendTab() {
    TabContent() {
      Row() {
        SendContent({
          onScrollDelta: (deltaY: number, absY: number) => {
            this.handleScrollDelta(deltaY, absY)
          },
          onNavigateTo: (name: string, param: Object | undefined) => {
            this.pathStack.pushPathByName(name, param);
          }
        })
          .width('100%')
          .constraintSize({ maxWidth: this.getContentMaxWidth() })
          .padding({
            left: this.getTabContentMargin(),
            right: this.getTabContentMargin()
          })
          .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_tab_send'), $r('app.string.tab_send')))
    .id('tab_send')
  }

  @Builder
  receiveTab() {
    TabContent() {
      Row() {
        ReceiveContent({
          onScrollDelta: (deltaY: number, absY: number) => {
            this.handleScrollDelta(deltaY, absY)
          },
          onNavigateTo: (name: string, param: Object | undefined) => {
            this.pathStack.pushPathByName(name, param);
          }
        })
          .width('100%')
          .constraintSize({ maxWidth: this.getContentMaxWidth() })
          .padding({
            left: this.getTabContentMargin(),
            right: this.getTabContentMargin()
          })
          .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_tab_receive'), $r('app.string.tab_receive')))
    .id('tab_receive')
  }

  @Builder
  settingsTab() {
    TabContent() {
      Row() {
        SettingsContent({
          onScrollDelta: (deltaY: number, absY: number) => {
            this.handleScrollDelta(deltaY, absY)
          }
        })
          .width('100%')
          .constraintSize({ maxWidth: this.getContentMaxWidth() })
          .padding({
            left: this.getTabContentMargin(),
            right: this.getTabContentMargin()
          })
          .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_tab_settings'), $r('app.string.tab_settings')))
    .id('tab_settings')
  }

  build() {
    Navigation(this.pathStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          // Tab 栏形态：md 及以下（含平板竖屏 600~840vp）、平板竖屏（大平板宽度 ≥840vp 但纵向高宽比 ≥1.2）、
          // 或矮窗（高度 <600vp）→ 底部水平栏；lg/xl 宽屏且非平板竖屏 → 侧边垂直栏
          if (!isWideWidth(this.breakpointInfo.widthBreakpoint) || this.isShortHeight ||
            (deviceInfo.deviceType === 'tablet' &&
              this.breakpointInfo.heightBreakpoint === HeightBreakpoint.HEIGHT_LG)) {
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
            .onChange((index: number) => {
              this.currentTabIndex = index;
              this.showTabBar();
              this.updateMtaScanByVisibility();
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
            .onChange((index: number) => {
              this.currentTabIndex = index;
              this.showTabBar();
              this.updateMtaScanByVisibility();
            })
            .width('100%')
            .height('100%')
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_background'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .hideTitleBar(true)
    // 强制单栏：避免宽屏（≥600vp，平板/PC/折叠屏展开态）下 Navigation Auto 自动分栏，
    // 导致主页面被限制在左侧 navBar 区域、右侧内容区空白（本功能不做宽屏分栏，子页面全屏推入）
    .mode(NavigationMode.Stack)
    // 首页栏可见性联动互传发现扫描：推入子页面即停止扫描，返回时恢复
    .onNavBarStateChange((visible: boolean) => {
      this.navBarVisible = visible;
      this.updateMtaScanByVisibility();
    })
  }
}
