import { ComponentContent, mediaquery, uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  HdsAnimationMode,
  HdsNavigation,
  HdsNavigationMenuContentOptions,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  hdsMaterial
} from '@kit.UIDesignKit';
import { getPageContentMaxWidth, getPageMargin, isNarrowWidth, isWideWidth } from '../common/Breakpoints';
import { buildImmersiveTitleBar, buildSingleEntryMenu } from '../common/ImmersiveTitleBar';
import {
  buildLocalDeviceSheetOptions,
  buildTransferCenterMenuContent,
  TransferCenterTitleActions
} from '../views/transfer/TransferCenterTitleActions';
import { SendContent } from '../components/SendContent';
import { SettingsContent } from '../components/SettingsContent';
import { TransferCenterContent } from './TransferCenterPage';
import { LocalDeviceSection } from '../views/settings/LocalDeviceSection';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';
import {
  initAppService,
  startLocalServer,
  stopLocalServer,
  isHideTabBarOnScroll,
  startMtaDiscoveryScan,
  stopMtaDiscoveryScan,
  saveMediaToGallery,
  consumeRecvMediaFiles,
  getPendingRecvMediaPaths,
  peekRecvCompleted
} from '../service/AppService';
import { isSaveToGallery } from '../service/repository/SettingsRepository';
import { querySessions, subscribeSessions, unsubscribeSessions } from '../service/transfer/TransferSessionRegistry';
import { SessionFilter, SessionStage, TransferSession } from '../model/transfer/TransferSession';
import {
  galleryMediaFilesOf,
  isGallerySaveCandidate,
  parseMediaFilesJson
} from '../viewmodel/SessionDetailViewModel';
import { GallerySaveDialogParams, buildGallerySaveDialog } from '../views/SaveToGalleryDialog';
import { GallerySaveResult, MediaFileInfo } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';
import { MainTabViewModel } from '../viewmodel/MainTabViewModel';
import { TransferCenterViewModel } from '../viewmodel/TransferCenterViewModel';
import { getStringSync } from '../utils/ResourceUtil';

@Entry
@ComponentV2
struct MainTabFloating {
  // 系统宽度断点（@Env 随窗口尺寸变化自动刷新，宽 320vp~520vp 范围）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: MainTabViewModel = new MainTabViewModel();
  // 传输中心视图模型：由主入口持有并下传内容组件，标题栏入口与列表共享同一份历史状态
  @Local transferViewModel: TransferCenterViewModel = new TransferCenterViewModel();
  @Local private isShortHeight: boolean = false;
  private hdsController: HdsTabsController = new HdsTabsController();
  private shortHeightListener: mediaquery.MediaQueryListener | null = null
  // 各 Tab 的真实滚动控制器（由内容组件接收并使用，主入口据此绑定导航组件与页签控制器）
  private sendScroller: Scroller = new Scroller()
  private transferScroller: Scroller = new Scroller()
  private settingsScroller: Scroller = new Scroller()
  // 各 Tab 的滚动位置：页签切换前保存、切换后恢复
  private tabScrollOffsets: number[] = [0, 0, 0]
  // HdsTabs 滚动动画状态
  @Local private isTabHidden: boolean = false
  // 当前激活的主页 Tab 索引（默认发送页 0）：驱动标题栏文案与结束端菜单
  @Local currentTabIndex: number = 0
  // 本机信息半模态显隐
  @Local private isShowLocalDeviceSheet: boolean = false
  // Navigation 首页栏（Tab 区域）是否可见：推入子页面后为 false
  private navBarVisible: boolean = true
  // Navigation 根容器路由栈
  private pathStack: NavPathStack = new NavPathStack()
  // 相册保存自动提示：已提示过的会话标识（同一会话只提示一次；不持久化）
  private galleryPromptedSessionIds: string[] = []
  // 相册保存弹窗 ComponentContent（与 openCustomDialog 使用同一实例，供 closeCustomDialog 关闭）
  private galleryContentNode: ComponentContent<GallerySaveDialogParams> | null = null
  private galleryPromptCallback: () => void = (): void => {
  }

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

    // 角标刷新订阅统一变更总线（与传输中心列表同源同时机）；
    // 新的待确认会话经 autoOpenSessionId 信号（见 onAutoOpenSessionChanged）自动进入详情页
    this.viewModel.start();
    this.transferViewModel.start();

    // 相册保存自动提示：接收完成后用户未必停留在详情页，故在壳层订阅统一变更总线触发
    this.galleryPromptCallback = (): void => {
      this.detectAutoGalleryPrompt();
    };
    subscribeSessions(this.galleryPromptCallback);

    // 将内容组件真实使用的滚动控制器绑定到 HdsTabsController 以实现滚动感知动画
    this.hdsController.bindScroller(0, this.sendScroller);
    this.hdsController.bindScroller(1, this.transferScroller);
    this.hdsController.bindScroller(2, this.settingsScroller);
  }

  aboutToDisappear(): void {
    this.viewModel.stop();
    this.transferViewModel.stop();
    unsubscribeSessions(this.galleryPromptCallback);
    stopLocalServer();
    this.hdsController.unbindScroller(this.sendScroller);
    this.hdsController.unbindScroller(this.transferScroller);
    this.hdsController.unbindScroller(this.settingsScroller);
    if (this.shortHeightListener !== null) {
      this.shortHeightListener.off('change');
    }
  }

  /**
   * 收到新的接收请求（新的待确认会话）时自动进入该会话详情页。
   * 消费 autoOpenSessionId 信号；首页可见时导航，已推入子页面时仅消费信号不叠加页面。
   */
  @Monitor('viewModel.autoOpenSessionId')
  onAutoOpenSessionChanged(): void {
    let sessionId: string = this.viewModel.autoOpenSessionId;
    if (sessionId.length === 0) {
      return;
    }
    this.viewModel.autoOpenSessionId = '';
    if (!this.navBarVisible) {
      return;
    }
    let params: Record<string, string> = { 'sessionId': sessionId };
    this.pathStack.pushPathByName('SessionDetailPage', params);
  }

  // ── 相册保存自动提示（由设置项驱动） ──

  /**
   * 检测新达到成功完成态、具备可保存媒体的接收会话：命中即自动弹出相册保存提示。
   * 设置关闭时不提示；已有弹窗在场时本次不提示；同一会话只提示一次（按会话标识去重）；
   * 文本消息会话不提示。
   */
  private detectAutoGalleryPrompt(): void {
    if (!isSaveToGallery()) {
      return;
    }
    // 已有弹窗在场：本次不弹，且不把命中会话计入去重集合——若此刻再开一个，
    // 既会叠加弹窗，又会覆盖节点引用使前一个弹窗再也关不掉、可能残留；
    // 命中会话留待弹窗关闭后的下一次会话变更事件再检测，提示不会丢失
    if (this.galleryContentNode !== null) {
      return;
    }
    let filter: SessionFilter = { stage: SessionStage.succeeded };
    let succeeded: Array<TransferSession> = querySessions(filter);
    for (let i = 0; i < succeeded.length; i++) {
      let session: TransferSession = succeeded[i];
      if (this.galleryPromptedSessionIds.indexOf(session.id) >= 0) {
        continue;
      }
      if (!isGallerySaveCandidate(session)) {
        continue;
      }
      let mediaFiles: Array<MediaFileInfo> = this.resolveGalleryMediaForSession(session);
      if (mediaFiles.length === 0) {
        continue;
      }
      this.galleryPromptedSessionIds.push(session.id);
      this.openGallerySaveDialog(mediaFiles);
      // 同一时刻只提示一个：其余命中会话留待后续会话变更再次检测
      return;
    }
  }

  /**
   * 解析某会话可保存到相册的媒体：协议适配器的媒体能力优先（非破坏性读）；
   * 适配器未实现该能力时，回退到接收侧的一次性媒体信号。
   *
   * 该信号是"最近一次接收完成"的单槽位、读取即清空，故：
   * ① 先以非破坏性方式校验归属（信号记录的会话标识须与当前会话一致，避免与其它会话错配）
   *    与存在性（待处理媒体路径非空）；
   * ② 仅在确认要弹窗时才真正消费该信号取完整媒体列表，避免误清导致后续提示丢失。
   *
   * 注意：接收侧信号以**协议层会话标识**写入，而注册表会话持有的 id 是**统一会话标识**，
   * 两者分属不同的标识空间，故归属校验必须比对会话上承载协议层标识的字段。
   */
  private resolveGalleryMediaForSession(session: TransferSession): Array<MediaFileInfo> {
    let mediaFiles: Array<MediaFileInfo> = galleryMediaFilesOf(session.id, session.protocolKey);
    if (mediaFiles.length > 0) {
      return mediaFiles;
    }
    if (session.protocolSessionId.length === 0) {
      return [];
    }
    if (peekRecvCompleted() !== session.protocolSessionId) {
      return [];
    }
    if (getPendingRecvMediaPaths().length === 0) {
      return [];
    }
    return parseMediaFilesJson(consumeRecvMediaFiles());
  }

  /** 相册保存媒体数量文案（复用既有资源与占位符口径）。 */
  private buildMediaCountText(count: number): string {
    return getStringSync(this.getUIContext(), $r('app.string.gallery_save_media_count')).replace('%d',
      String(count));
  }

  /** 打开相册保存弹窗（复用既有保存弹窗与既有弹窗打开方式，不新造弹窗）。 */
  private openGallerySaveDialog(mediaFiles: Array<MediaFileInfo>): void {
    let params = new GallerySaveDialogParams();
    params.mediaFiles = mediaFiles;
    params.mediaCountText = this.buildMediaCountText(mediaFiles.length);
    params.onPerformSave = (files: Array<MediaFileInfo>): Promise<GallerySaveResult> => {
      let hostContext = this.getUIContext().getHostContext();
      if (hostContext === undefined) {
        let failed: GallerySaveResult = { successCount: 0, failCount: files.length, errors: ['no context'] };
        return Promise.resolve(failed);
      }
      return saveMediaToGallery(hostContext as common.UIAbilityContext, files);
    };
    params.onSaveComplete = (result: GallerySaveResult): void => {
      this.showGallerySaveResultToast(result);
    };
    // 用户跳过或点击遮罩关闭：仅复位节点引用（关闭按钮路径经 closeGallerySaveDialog 关闭并复位）
    params.onDismiss = (): void => {
      this.clearGallerySaveDialogNode();
    };
    params.onCloseDialog = (): void => {
      this.closeGallerySaveDialog();
    };
    let contentNode = new ComponentContent(this.getUIContext(), wrapBuilder(buildGallerySaveDialog), params);
    // closeCustomDialog 必须复用与 openCustomDialog 相同的 ComponentContent 实例。
    // 先置引用再打开：上方守卫据此判定「已有弹窗在场」；若改为打开成功后再置引用，
    // 同一轮内的第二次会话变更可能再开一个弹窗，造成叠加与引用覆盖
    this.galleryContentNode = contentNode;
    params.contentNode = contentNode;
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(contentNode, {
        autoCancel: true,
        alignment: DialogAlignment.Center
      })
      .catch(() => {
        // 打开失败：复位节点引用，避免「引用非空但实际未展示」使守卫此后永久拦截弹窗
        this.clearGallerySaveDialogNode();
      });
  }

  private closeGallerySaveDialog(): void {
    if (this.galleryContentNode !== null) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.galleryContentNode);
      this.clearGallerySaveDialogNode();
    }
  }

  /**
   * 复位相册保存弹窗的节点引用：弹窗关闭（含跳过/关闭按钮）、打开失败等所有退出路径
   * 统一经此复位，避免引用残留导致守卫永久拦截、此后不再弹窗。
   */
  private clearGallerySaveDialogNode(): void {
    this.galleryContentNode = null;
  }

  private showGallerySaveResultToast(result: GallerySaveResult): void {
    let message: ResourceStr = result.successCount > 0 ? $r('app.string.gallery_save_success') :
      $r('app.string.gallery_save_failed');
    this.getUIContext()
      .getPromptAction()
      .showToast({ message: message, duration: 2000 });
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

  // ── 滚动控制器链路：取用、绑定与页签切换时的位置保持 ──

  /** 页签索引 → 该页签真实使用的滚动控制器。 */
  private tabScrollerAt(index: number): Scroller {
    if (index === 1) {
      return this.transferScroller;
    }
    if (index === 2) {
      return this.settingsScroller;
    }
    return this.sendScroller;
  }

  /** 当前页签的滚动控制器：导航组件只绑定当前页签，避免多个控制器互相干扰。 */
  private currentTabScroller(): Scroller {
    return this.tabScrollerAt(this.currentTabIndex);
  }

  /** 页签切走前保存该页签的滚动位置。 */
  private saveTabScroll(index: number): void {
    if (index < 0 || index >= this.tabScrollOffsets.length) {
      return;
    }
    this.tabScrollOffsets[index] = this.tabScrollerAt(index).currentOffset().yOffset;
  }

  /** 切到目标页签后恢复其滚动位置（首次进入为 0，不产生滚动）。 */
  private restoreTabScroll(index: number): void {
    if (index < 0 || index >= this.tabScrollOffsets.length) {
      return;
    }
    let options: ScrollOptions = { xOffset: 0, yOffset: this.tabScrollOffsets[index] };
    this.tabScrollerAt(index).scrollTo(options);
  }

  // ── 标题栏内容与入口 ──

  /** 标题栏文案随页签索引变化（复用既有页签文案资源）。 */
  private currentTabTitle(): ResourceStr {
    if (this.currentTabIndex === 1) {
      return $r('app.string.tab_transfer_center');
    }
    if (this.currentTabIndex === 2) {
      return $r('app.string.tab_settings');
    }
    return $r('app.string.tab_send');
  }

  /** 传输中心标题栏入口动作：与路由外壳共用同一套装配。 */
  private transferCenterTitleActions(): TransferCenterTitleActions {
    return {
      onOpenLocalDevice: () => {
        this.isShowLocalDeviceSheet = true;
      },
      onOpenFileHistory: () => {
        this.pathStack.pushPathByName('ReceiveHistoryPage', undefined);
      },
      onClearSessionHistory: () => {
        this.transferViewModel.clearHistory();
      }
    };
  }

  /**
   * 标题栏结束端菜单随页签变化：发送=故障排查；传输中心=本机信息+更多。
   * 设置页无入口，显式下发空菜单（而非省略菜单字段），确保切页签后不残留上一页签的「更多」入口。
   */
  private currentTabMenu(): HdsNavigationMenuContentOptions {
    if (this.currentTabIndex === 0) {
      return buildSingleEntryMenu($r('sys.symbol.questionmark_circle'), $r('app.string.troubleshoot_title'), () => {
        this.pathStack.pushPathByName('TroubleshootPage', undefined);
      });
    }
    if (this.currentTabIndex === 1) {
      return buildTransferCenterMenuContent(this.transferViewModel.historyCount,
        this.transferCenterTitleActions());
    }
    return { value: [] };
  }

  /** 本机信息精简弹窗内容（别名 / 指纹 / 各网卡 IP）。 */
  @Builder
  localDeviceSheet() {
    LocalDeviceSection()
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
          scroller: this.sendScroller,
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
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_tab_send'), $r('app.string.tab_send')))
    .id('tab_send')
    // 页签内容不裁剪：允许滚动内容绘制到页签边界之外（标题栏区域），配合滚动容器不裁剪实现内容穿透
    .clip(false)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 切走前保存滚动位置，供切回时恢复
    .onWillHide(() => {
      this.saveTabScroll(0);
    })
  }

  // 传输中心页签标签：存在活跃会话时附带数量角标
  private transferTabLabel(): string {
    let label: string = getStringSync(this.getUIContext(), $r('app.string.tab_transfer_center'));
    if (this.viewModel.activeTransferCount > 0) {
      return label + ' (' + this.viewModel.activeTransferCount + ')';
    }
    return label;
  }

  @Builder
  transferTab() {
    TabContent() {
      Row() {
        TransferCenterContent({
          viewModel: this.transferViewModel,
          scroller: this.transferScroller,
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
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_tab_transfer'), this.transferTabLabel()))
    .id('tab_transfer_center')
    .clip(false)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onWillHide(() => {
      this.saveTabScroll(1);
    })
  }

  @Builder
  settingsTab() {
    TabContent() {
      Row() {
        SettingsContent({
          scroller: this.settingsScroller,
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
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .tabBar(new BottomTabBarStyle($r('app.media.ic_tab_settings'), $r('app.string.tab_settings')))
    .id('tab_settings')
    .clip(false)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onWillHide(() => {
      this.saveTabScroll(2);
    })
  }

  build() {
    HdsNavigation(this.pathStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          // Tab 栏形态：md 及以下（含平板竖屏 600~840vp）、平板竖屏（大平板宽度 ≥840vp 但纵向高宽比 ≥1.2）、
          // 或矮窗（高度 <600vp）→ 底部水平栏；lg/xl 宽屏且非平板竖屏 → 侧边垂直栏
          if (!isWideWidth(this.breakpointInfo.widthBreakpoint) || this.isShortHeight ||
            (deviceInfo.deviceType === 'tablet' &&
              this.breakpointInfo.heightBreakpoint === HeightBreakpoint.HEIGHT_LG)) {
            HdsTabs({ controller: this.hdsController }) {
              this.sendTab()
              this.transferTab()
              this.settingsTab()
            }
            .animationDuration(DesignTokens.animation.durationNormal)
            // 页签容器自身默认会裁剪超出其范围的子组件：不关闭则页签内容无法延伸至标题栏区域，
            // 标题栏透视/材质下无可透出内容；须与页签内容容器的不裁剪配套设置
            .clip(false)
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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
            // 切页签动画开始时即切换标题栏文案/菜单，并恢复目标页签的滚动位置
            .onAnimationStart((_index: number, targetIndex: number) => {
              this.currentTabIndex = targetIndex;
              this.restoreTabScroll(targetIndex);
            })
            .width('100%')
            .height('100%')
          } else {
            HdsTabs({ controller: this.hdsController }) {
              this.sendTab()
              this.transferTab()
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
            .onAnimationStart((_index: number, targetIndex: number) => {
              this.currentTabIndex = targetIndex;
              this.restoreTabScroll(targetIndex);
            })
            .width('100%')
            .height('100%')
            // 页签容器自身默认会裁剪超出其范围的子组件：不关闭则页签内容无法延伸至标题栏区域，
            // 标题栏透视/材质下无可透出内容；须与页签内容容器的不裁剪配套设置
            .clip(false)
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_background'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      // 安全区扩展逐层设置：内容根节点到滚动容器之间的各直接节点均需具备，
      // 否则滚动后延伸失效（内容根组件内部另按同规则逐层配置）
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    // 导航根容器延伸至系统状态栏与导航条区域：标题栏模糊覆盖状态栏所在高度、页面背景铺满屏幕
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 主页面为根页面无返回语义：隐藏返回入口；工具栏不使用
    .titleMode(HdsNavigationTitleMode.MINI)
    .titleBar(buildImmersiveTitleBar({
      title: this.currentTabTitle(),
      menu: this.currentTabMenu()
    }))
    .hideBackButton(true)
    .hideToolBar(true)
    // 只绑定当前页签的滚动控制器：嵌套底部页签时逐页签绑定才能保留标题栏滚动模糊
    .bindToScrollable([this.currentTabScroller()])
    // 强制单栏：避免宽屏（≥600vp，平板/PC/折叠屏展开态）下 Navigation Auto 自动分栏，
    // 导致主页面被限制在左侧 navBar 区域、右侧内容区空白（本功能不做宽屏分栏，子页面全屏推入）
    .mode(NavigationMode.Stack)
    .bindSheet($$this.isShowLocalDeviceSheet, this.localDeviceSheet(),
      buildLocalDeviceSheetOptions(this.breakpointInfo.widthBreakpoint))
    // 首页栏可见性联动互传发现扫描：推入子页面即停止扫描，返回时恢复
    .onNavBarStateChange((visible: boolean) => {
      this.navBarVisible = visible;
      this.updateMtaScanByVisibility();
    })
  }
}
