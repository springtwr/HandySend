import {
  AlertDialogV2,
  AdvancedDialogV2Button,
  ComponentContent,
  promptAction,
  uiObserver,
  window
} from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import {
  HdsAnimationMode,
  HdsNavigation,
  HdsNavigationMenuContentOptions,
  HdsNavigationMenuItemOptions,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  hdsMaterial
} from '@kit.UIDesignKit';
import {
  getPageContentMaxWidth, getPageMargin, isNarrowWidth, isWidescreenSideBarLayout
} from '../common/Breakpoints';
import { buildImmersiveTitleBar } from '../common/ImmersiveTitleBar';
import { WidescreenSideBar } from '../views/WidescreenSideBar';
import {
  buildLocalDeviceSheetOptions,
  buildTransferCenterMenuContent,
  TransferCenterTitleActions
} from '../views/transfer/TransferCenterTitleActions';
import {
  buildClearHistoryMessage,
  buildDeleteSelectedMessage
} from '../views/transfer/ClearHistoryConfirmDialog';
import { SendContent } from '../components/SendContent';
import { SettingsContent } from '../components/SettingsContent';
import { TransferCenterContent } from './TransferCenterContent';
import { LocalDeviceSection } from '../views/settings/LocalDeviceSection';
import { initAllPreferences } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';
import {
  initAppService,
  startLocalServer,
  stopLocalServer,
  restoreWebService,
  isHideTabBarOnScroll,
  startMtaDiscoveryScan,
  stopMtaDiscoveryScan,
  saveMediaToGallery,
  updateGallerySavedStatus,
  consumeRecvMediaFiles,
  getPendingRecvMediaPaths,
  peekRecvCompleted,
  subscribe,
  unsubscribe,
  consumePendingNavigation,
  refreshWifiWarning,
  PendingNavigation,
} from '../service/AppService';
import { isAppForeground } from '../service/repository/AppCore';
import { isDesktopWindowMinimized } from '../service/BackgroundAttentionNotifier';
import { NAV_TARGET_SESSION_DETAIL, NAV_TARGET_TRANSFER_CENTER } from '../utils/WantAgentUtil';
import {
  isSaveToGallery, getLocalSendEnabled, getMtaEnabled,
  getWebSendAllowed, getNotifiedProtocolSignature, setNotifiedProtocolSignature
} from '../service/repository/SettingsRepository';
import {
  querySessions, getSession, getPendingSessionIds, hasSessionOrHistory, subscribeSessions,
  unsubscribeSessions
} from '../service/transfer/TransferSessionRegistry';
import {
  SessionFilter,
  SessionStage,
  TransferSession
} from '../model/transfer/TransferSession';
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
import { SendViewModel, shouldShowPartialProtocolDisabledHint } from '../viewmodel/SendViewModel';
import { getStringSync } from '../utils/ResourceUtil';
import { requestCloseOverlays } from '../utils/OverlayCloseBus';
import { isSessionDetailOpen } from '../utils/SessionDetailStack';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:MainTabFloating', '主页');

@Entry
@ComponentV2
struct MainTabFloating {
  // 系统宽度断点（@Env 随窗口尺寸变化自动刷新，宽 320vp~520vp 范围）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: MainTabViewModel = new MainTabViewModel();
  // 发送视图模型：由主入口持有并下传内容组件，窗口跨断点切换页签容器形态时保留暂存列表等状态
  @Local private sendViewModel: SendViewModel = new SendViewModel();
  // 任务视图模型：由主入口持有并下传内容组件，标题栏入口与列表共享同一份历史状态
  @Local transferViewModel: TransferCenterViewModel = new TransferCenterViewModel();
  // 首帧内容就绪标志：首帧仅构建壳层（标题栏 + 空页签容器），三个页签的重量级内容
  // 在此标志置真后一次性构建；同时作为重量级初始化（应用服务、服务器、订阅、滚动绑定）的
  // 一次性守卫。置真时机：onPageShow 首次触发时（首帧已绘制之后），此后不再重复执行
  @Local private firstFrameContentReady: boolean = false;
  private hdsController: HdsTabsController = new HdsTabsController();
  // 底部系统导航条避让高度（vp）：>0 表示存在系统导航条。窗口在全屏/小窗/分屏间切换、
  // 旋转或折叠时该值会变化，故监听 avoidAreaChange 动态更新；底部浮动页签栏间距据此条件化
  @Local private naviIndicatorHeight: number = 0;
  private avoidAreaWindow: window.Window | null = null;
  private avoidAreaChangeCallback: (options: window.AvoidAreaOptions) => void =
    (options: window.AvoidAreaOptions): void => {
      if (options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
        this.applyNaviIndicatorHeight(options.area);
      }
    };
  // 各 Tab 的真实滚动控制器（由内容组件接收并使用，主入口据此绑定导航组件与页签控制器）
  private sendScroller: Scroller = new Scroller()
  private transferScroller: Scroller = new Scroller()
  // 任务列表首个可见行下标（0 = 最新任务行仍在视口内）：失败浮卡的抑制判定
  private taskFirstVisibleIndex: number = 0
  private settingsScroller: Scroller = new Scroller()
  // 各 Tab 的滚动位置：页签切换前保存、切换后恢复
  private tabScrollOffsets: number[] = [0, 0, 0]
  // HdsTabs 滚动动画状态
  @Local private isTabHidden: boolean = false
  // 当前激活的主页 Tab 索引（默认发送页 0）：驱动标题栏文案与结束端菜单
  @Local currentTabIndex: number = 0
  // 「部分/全部传输方式已关闭」提示卡的关闭状态：本次会话内有效、不持久化（协议开关变化后复位）
  @Local protocolHintDismissed: boolean = false
  // 本次启动是否允许显示「部分传输方式已关闭」提示：同一关闭状态只提示一次（见启动评估方法）
  @Local partialProtocolHintVisible: boolean = false
  // 本机信息半模态显隐
  @Local private isShowLocalDeviceSheet: boolean = false
  // 本机信息半模态当前是否处于网络接口页：由宿主持有，供系统返回键先退回信息页
  @Local private localDeviceShowInterfaces: boolean = false
  // 清空任务历史确认弹窗的说明文案（打开时构造，关闭时清空）
  @Local private clearHistoryDialogMessage: string = ''
  // 当前打开的确认弹窗 id（关闭时使用）
  private clearHistoryDialogId: number = -1
  // 多选批量删除确认弹窗的说明文案（打开时构造，关闭时清空）
  @Local private deleteSelectedDialogMessage: string = ''
  // 当前打开的批量删除确认弹窗 id（关闭时使用）
  private deleteSelectedDialogId: number = -1
  // 点击通知进入前台时已存在的待确认会话：通知已承担提醒，本次前台不再补开详情页
  private suppressedTransferPromptSessionIds: Array<string> = []
  // Navigation 首页栏（Tab 区域）是否可见：推入子页面后为 false
  private navBarVisible: boolean = true
  // Navigation 根容器路由栈
  private pathStack: NavPathStack = new NavPathStack()
  // HDS 侧边栏套件能力探测结果：能力为设备级常量，探测一次后缓存
  private cachedHdsPatternSupported: boolean | undefined = undefined
  // 相册保存自动提示：已提示过的会话标识（同一会话只提示一次；不持久化）
  private galleryPromptedSessionIds: string[] = []
  // 相册保存弹窗 ComponentContent（与 openCustomDialog 使用同一实例，供 closeCustomDialog 关闭）
  private galleryContentNode: ComponentContent<GallerySaveDialogParams> | null = null
  private galleryPromptCallback: () => void = (): void => {
  }

  // 最近一次协议开关签名（LocalSend / 互传 / 网页总开关）：仅在开关实际变化时复位协议提示的关闭状态。
  // 数据总线还会因设备发现等普通刷新触发回调；若按当前开关值无条件复位，
  // 部分关闭场景下提示会被反复复活、无法关闭。
  private protocolToggleSignature: string = ''
  // 设置变化回调：协议开关实际变化时复位提示关闭状态，使提示内容随开关更新
  //（部分关闭提示的已展示签名持久化，同一状态只在下次启动提示一次）。
  private settingsChangedCallback: () => void = (): void => {
    let signature: string =
      `${getLocalSendEnabled()}|${getMtaEnabled()}|${getWebSendAllowed()}`;
    if (signature !== this.protocolToggleSignature) {
      this.protocolToggleSignature = signature;
      this.protocolHintDismissed = false;
      // 关闭状态已变化：本次会话不再沿用上次启动的提示显隐，下次启动重新评估并提示一次
      this.partialProtocolHintVisible = false;
      // 两种方式都开启时清除已提示记录：之后再次关闭应重新提示一次
      if (getLocalSendEnabled() && getMtaEnabled()) {
        setNotifiedProtocolSignature('');
      }
    }
  }

  // 变更总线回调：通知深链（热启动经变更总线送达）与回前台补开详情页共用。
  // 真机实测 onPageShow 可能早于 EntryAbility.onForeground（页面先显示、前台标志后更新），
  // 此时 onPageShow 内的补开详情页会因非前台被跳过；onForeground 末尾的 triggerRefresh 再经此处兜底一次。
  private navigationCallback: () => void = (): void => {
    this.handlePendingNavigation();
    this.tryOpenPendingSessionDetail();
  }

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // 偏好读取保留在首帧路径：首帧布局形态与设置值依赖它
    initAllPreferences(context);

    // 相册保存自动提示回调：订阅本身延后到首帧之后，但回调字段须在订阅前完成赋值
    this.galleryPromptCallback = (): void => {
      this.detectAutoGalleryPrompt();
    };

    // 冷启动深链：onCreate 已置位信号，此处首次消费（onPageShow 亦会兜底一次，消费即清空不重复）
    this.handlePendingNavigation();

    // 底部页签栏间距依赖系统导航条避让高度：注册避让区监听（同时完成初始取值）
    this.registerAvoidAreaListener();
  }

  /**
   * 启动时评估「部分传输方式已关闭」提示：持久化已提示的关闭状态签名，
   * 同一状态只在状态变化后的首次启动提示一次；之后即使重启也不再提示，
   * 避免对特意关闭某种方式的用户反复打扰。
   */
  private evaluateProtocolHintOnStartup(): void {
    let localSendEnabled: boolean = getLocalSendEnabled();
    let mtaEnabled: boolean = getMtaEnabled();
    let webSendEnabled: boolean = getWebSendAllowed();
    let enabledSignature: string = `${localSendEnabled}|${mtaEnabled}`;
    this.protocolToggleSignature = `${enabledSignature}|${webSendEnabled}`;
    // 两种方式都开启时清除已提示记录：之后再次关闭属于新的状态变化，应重新提示一次
    if (localSendEnabled && mtaEnabled) {
      if (getNotifiedProtocolSignature().length > 0) {
        setNotifiedProtocolSignature('');
      }
      this.partialProtocolHintVisible = false;
      return;
    }
    let shouldShow: boolean = shouldShowPartialProtocolDisabledHint(localSendEnabled, mtaEnabled,
      webSendEnabled, false);
    if (shouldShow && enabledSignature !== getNotifiedProtocolSignature()) {
      this.partialProtocolHintVisible = true;
      // 展示即记录：即使本次未手动关闭，后续启动也不再重复提示
      setNotifiedProtocolSignature(enabledSignature);
    } else {
      this.partialProtocolHintVisible = false;
    }
  }

  /**
   * 首帧之后一次性执行的重量级初始化：应用服务、接收服务器、视图模型订阅与页签滚动绑定。
   * 由 onPageShow 首次触发（一次性守卫），执行完毕置真首帧内容就绪标志，
   * 三处页签的重量级内容随之构建。保持原 aboutToAppear 内的相互顺序：
   * 先 initAppService，再启动服务器与订阅，最后绑定滚动控制器。
   */
  private runDeferredStartup(): void {
    if (this.firstFrameContentReady) {
      return;
    }
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    initAppService(context);
    // 设置加载完成后、内容构建前评估协议提示显隐（同一关闭状态只提示一次）
    this.evaluateProtocolHintOnStartup();
    // 网页服务独立于 LocalSend 服务器：按其方向开关在启动流程中自行恢复
    restoreWebService().catch((_e: Error) => {
      // 恢复失败由 AppService 记录日志
    });
    // LocalSend 总开关关闭时不自动启动服务器（关闭状态跨重启保持）
    if (getLocalSendEnabled()) {
      startLocalServer().catch((_e: Error) => {
        // 服务器启动失败由 AppService 记录日志
      });
    } else {
      logger.debug('LocalSend 总开关已关闭，主页出现时不启动服务器');
    }

    // 首帧前的 onPageShow 已按可见性尝试过一次扫描，但那时 initAppService 尚未执行；
    // 此处在其后补一次，恢复「initAppService 先于发现扫描」的原有时序（该状态机幂等，重复调用无副作用）
    this.updateMtaScanByVisibility();

    // 角标刷新订阅统一变更总线（与任务列表同源同时机）；
    // 新的待确认会话经 autoOpenSessionIds 队列（见 onAutoOpenSessionChanged）逐条进入详情页
    this.viewModel.start();
    // 发送页视图模型由页面宿主持有：在此注入上下文并订阅收藏，内容组件重建不改变其生命周期
    this.sendViewModel.init(context);
    this.sendViewModel.subscribeFavorites();
    this.transferViewModel.start();

    // 相册保存自动提示：接收完成后用户未必停留在详情页，故在壳层订阅统一变更总线触发
    subscribeSessions(this.galleryPromptCallback);
    // 设置变化订阅：用于复位「两个协议均禁用」提示卡的关闭状态（详见回调注释）
    subscribe(this.settingsChangedCallback);
    // 通知深链订阅：热启动时消费深链信号并导航
    subscribe(this.navigationCallback);

    // 将内容组件真实使用的滚动控制器绑定到 HdsTabsController 以实现滚动感知动画
    this.hdsController.bindScroller(0, this.sendScroller);
    this.hdsController.bindScroller(1, this.transferScroller);
    this.hdsController.bindScroller(2, this.settingsScroller);

    // 置真首帧内容就绪标志：@Local 赋值触发一次重建，三个页签的重量级内容在同一帧内构建
    this.firstFrameContentReady = true;

    // 启动期间可能已有网页访问提示/待确认会话到达：首帧之后再消费，避免和首屏构建抢页面
    setTimeout(() => {
        this.tryOpenPendingSessionDetail();
    }, 0);
  }

  aboutToDisappear(): void {
    this.viewModel.stop();
    this.sendViewModel.unsubscribeFavorites();
    this.transferViewModel.stop();
    unsubscribeSessions(this.galleryPromptCallback);
    unsubscribe(this.settingsChangedCallback);
    unsubscribe(this.navigationCallback);
    stopLocalServer();
    this.hdsController.unbindScroller(this.sendScroller);
    this.hdsController.unbindScroller(this.transferScroller);
    this.hdsController.unbindScroller(this.settingsScroller);
    this.unregisterAvoidAreaListener();
  }

  /**
   * 注册系统避让区监听并取初值：导航条高度随窗口在全屏/小窗/分屏间切换、旋转或折叠而变化，
   * 仅启动查一次会滞留旧值（如全屏算出 0、切小窗后仍为 0，页签贴窗口底边），故须持续监听。
   * 取窗口失败时保持回退值（0），页签间距退回固定值。
   */
  private registerAvoidAreaListener(): void {
    let context = this.getUIContext().getHostContext();
    if (!context) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window): void => {
      this.avoidAreaWindow = win;
      this.applyNaviIndicatorHeight(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR));
      win.on('avoidAreaChange', this.avoidAreaChangeCallback);
    }).catch((e: BusinessError): void => {
      logger.warn('获取窗口失败，页签底部间距沿用回退值：' + JSON.stringify(e));
    });
  }

  private unregisterAvoidAreaListener(): void {
    if (this.avoidAreaWindow !== null) {
      this.avoidAreaWindow.off('avoidAreaChange', this.avoidAreaChangeCallback);
      this.avoidAreaWindow = null;
    }
  }

  /** 避让区以 px 记录，换算为 vp：>0 表示存在系统导航条 */
  private applyNaviIndicatorHeight(area: window.AvoidArea): void {
    this.naviIndicatorHeight = this.getUIContext().px2vp(area.bottomRect.height);
  }

  /**
   * 消费通知深链信号：单任务通知直达该任务详情，其余（多条合并 / 实况进度 / 保活）回任务中心。
   * 两种落点都复用失败浮卡的跳转口径——回根、任务页签滚动归零并切到任务页签，
   * 保证返回时落在任务列表顶部而不是退出时所在页面或旧滚动位置；
   * 从通知进入前台时，点击通知那一刻已存在的待确认请求不再补开详情页（见 tryOpenPendingSessionDetail）；
   * 信号为一次性，消费即清空，重复触发无副作用。
   */
  private handlePendingNavigation(): void {
    let pending: PendingNavigation = consumePendingNavigation();
    // 通知进入前台（任务中心或详情）：点击时已存在的待确认会话由通知承担提醒，
    // 记录后跳过本次前台的补开；点击之后新到达的请求不在集合内，仍正常进入详情
    if (pending.target.length > 0) {
      this.suppressedTransferPromptSessionIds = getPendingSessionIds();
      // 通知落点页要被推到最前：先收起当前弹层；未保存修改走各自确认
      try {
        this.closeRootOverlays();
      } catch (e) {
        logger.warn('收起主页弹层异常：' + String(e));
      }
      requestCloseOverlays();
    }
    if (pending.target === NAV_TARGET_SESSION_DETAIL && pending.sessionId.length > 0) {
      if (!hasSessionOrHistory(pending.sessionId)) {
        // 会话与历史都不存在（如进程重启后残留的待确认通知）：退回任务中心
        this.focusTaskCenterTop();
        return;
      }
      // 与失败浮卡的「查看详情」同源：先回根、切任务页签并归零滚动，再压入该会话详情
      this.focusTaskCenterTop();
      let params: Record<string, string> = { 'sessionId': pending.sessionId };
      this.pathStack.pushPathByName('SessionDetailPage', params);
      return;
    }
    if (pending.target !== NAV_TARGET_TRANSFER_CENTER && pending.target !== NAV_TARGET_SESSION_DETAIL) {
      return;
    }
    // 任务中心；详情目标缺少会话标识时同样回到任务中心（与解析侧口径一致）
    this.focusTaskCenterTop();
  }

  /**
   * 收到新的接收请求（新的待确认会话）：在应用前台且窗口可见时逐条进入这些会话的详情页。
   * 接收任务优先级高于当前页面；后打开的详情页覆盖先打开的页面，用户逐条处理后返回。
   * 消费 autoOpenSessionIds 队列；非前台不消费（保留待回前台补开，见 onPageShow 与变更总线回调）。
   */
  @Monitor('viewModel.autoOpenSessionVersion')
  onAutoOpenSessionChanged(): void {
    this.tryOpenPendingSessionDetail();
  }

  /**
   * 尝试进入待确认会话详情页：仅前台、非最小化、队列非空时执行；
   * 队列在导航前消费；通知进入前台的抑制集合只对当前这一批生效。
   */
  private tryOpenPendingSessionDetail(): void {
    // 首帧内容就绪前不导航，避免与首屏构建抢页面；就绪后由启动回调补一次
    if (!this.firstFrameContentReady) {
      return;
    }
    // PC 最小化时窗口不可见，不跳转，由后台关注通知/角标承担提醒
    if (!isAppForeground() || isDesktopWindowMinimized()) {
      return;
    }
    let sessionIds: Array<string> = this.viewModel.autoOpenSessionIds;
    if (sessionIds.length === 0) {
      return;
    }
    this.viewModel.autoOpenSessionIds = [];
    // 先筛出仍待确认的会话：整批都已失效时不要无谓关闭用户当前弹层
    let validIds: Array<string> = [];
    for (let i = 0; i < sessionIds.length; i++) {
      let sessionId: string = sessionIds[i];
      if (this.suppressedTransferPromptSessionIds.indexOf(sessionId) >= 0) {
        continue;
      }
      if (isSessionDetailOpen(sessionId)) {
        // 同一会话的详情页已在栈中：不重复推入
        logger.debug('会话详情已打开，跳过重复入栈 session=' + sessionId);
        continue;
      }
      let session = getSession(sessionId);
      if (session === undefined || session.stage !== SessionStage.awaitingConfirmation) {
        // 会话已消失或已不处于待确认（被处理 / 超时 / 已开始）：跳过该条
        logger.debug('待处理会话已不可用，跳过 session=' + sessionId);
        continue;
      }
      validIds.push(sessionId);
    }
    this.suppressedTransferPromptSessionIds = [];
    if (validIds.length === 0) {
      return;
    }
    // 先收起主页自持弹层，再广播给设置页等子组件；带未保存修改的弹层会自行弹确认
    try {
      this.closeRootOverlays();
    } catch (e) {
      logger.warn('收起主页弹层异常：' + String(e));
    }
    requestCloseOverlays();
    // 按到达顺序逐条推入：后打开的页面覆盖先打开的页面，用户返回时逐条处理
    for (let i = 0; i < validIds.length; i++) {
      let sessionId: string = validIds[i];
      logger.debug('直接打开新传输详情 session=' + sessionId);
      let params: Record<string, string> = { 'sessionId': sessionId };
      this.pathStack.pushPathByName('SessionDetailPage', params);
    }
  }

  /** 收起主页自持的弹窗/半模态；有未保存修改的弹层由各自组件处理确认。 */
  private closeRootOverlays(): void {
    if (this.isShowLocalDeviceSheet) {
      this.isShowLocalDeviceSheet = false;
    }
    this.closeClearHistoryDialog();
    this.closeDeleteSelectedDialog();
    this.closeGallerySaveDialog();
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
      this.openGallerySaveDialog(mediaFiles, session.id, session.protocolSessionId);
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
  private openGallerySaveDialog(mediaFiles: Array<MediaFileInfo>, sessionId: string,
    protocolSessionId: string): void {
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
      // 保存至少一个媒体即回写接收历史的「已保存到相册」标记。接收历史主键随协议而异：
      // LocalSend 按协议会话标识，网页上传按统一会话标识（同浏览器 token 会跨会话复用）；
      // 两处都是前缀匹配，互不命中时为空操作
      if (result.successCount > 0) {
        if (protocolSessionId.length > 0) {
          updateGallerySavedStatus(protocolSessionId, true);
        }
        updateGallerySavedStatus(sessionId, true);
      }
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
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(contentNode, {
        autoCancel: true,
        alignment: DialogAlignment.Center
      })
      .catch(() => {
        // 打开失败：复位节点引用，避免「引用非空但实际未展示」使守卫此后永久拦截弹窗；
        // 同时撤销本次的已提示标记——媒体信号已被消费，若不撤销该会话会永久失去提示机会
        this.clearGallerySaveDialogNode();
        let idx: number = this.galleryPromptedSessionIds.indexOf(sessionId);
        if (idx >= 0) {
          this.galleryPromptedSessionIds.splice(idx, 1);
        }
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

  // 互传发现扫描随发送页可见性启停：仅首页 Tab 区域可见且发送页激活时扫描，其余情况停止。
  // 可见性变化只更新「可见性期望意图」（互传发现的两大意图之一）：可见即设定期望、不可见即清期望；
  // 发送期间的暂停为另一独立意图，由发送流程自行挂起与恢复，不经此处。
  // MTA 总开关关闭时不扫描并清除意图（显式关闭）。
  private updateMtaScanByVisibility(): void {
    if (!getMtaEnabled()) {
      // 总开关关闭时清除期望意图；发送页可见时记录原因，便于与「页面不可见」区分
      if (this.navBarVisible && this.currentTabIndex === 0) {
        logger.debug('MTA 总开关已关闭，不启动发现扫描');
      }
      stopMtaDiscoveryScan();
      return;
    }
    if (this.navBarVisible && this.currentTabIndex === 0) {
      startMtaDiscoveryScan();
    } else {
      stopMtaDiscoveryScan();
    }
  }

  /**
   * 重枚举本地网卡：SoftAP（热点）与次要 STA 不产生网络连接事件，系统的网络变化监听
   * 覆盖不到开关热点，故停留在发送页或设置页时主动刷新一次接口列表与警告状态。
   */
  private refreshLocalInterfacesIfHomeVisible(): void {
    if (!this.firstFrameContentReady || (this.currentTabIndex !== 0 && this.currentTabIndex !== 2)) {
      return;
    }
    refreshWifiWarning();
  }

  onPageShow(): void {
    // 首帧的 build 与布局/绘制在主线程上同步执行，此处异步调度可确保
    // 门控标志在首帧构建之后才置真，使首帧只含壳层（标题栏 + 空页签容器）
    setTimeout(() => {
      this.runDeferredStartup();
      this.refreshLocalInterfacesIfHomeVisible();
    }, 0);
    this.updateMtaScanByVisibility();
    // 冷启动/热启动兜底：消费可能仍待处理的深链信号（消费即清空，不重复导航）
    this.handlePendingNavigation();
    // 覆盖「待确认请求在后台到达、回到前台」的场景：补开详情页一次（非前台时未消费信号）。
    // 真机实测 onPageShow 可能早于 onForeground，这里被前台判断拦下时由变更总线回调兜底重试。
    this.tryOpenPendingSessionDetail();
  }

  onPageHide(): void {
    // 显式离开页面：清除可见性期望与发送暂停两个发现意图
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
    // 宽屏侧边栏形态下页签栏已隐藏（高度归零）：不参与随滚动显隐
    if (this.useWidescreenSideBar()) {
      return;
    }
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

  /**
   * 读取某页签滚动控制器的当前纵向偏移；读数不可用时返回 undefined。
   * 滚动控制器尚未与滚动容器建立绑定（页签容器因断点切换被重建）或已被销毁时，
   * 组件返回空值而非有效偏移，此处统一归一为「无有效位置」。
   */
  private readTabScrollerOffset(index: number): number | undefined {
    let offset: OffsetResult | undefined = this.tabScrollerAt(index).currentOffset();
    if (offset === undefined) {
      return undefined;
    }
    return offset.yOffset;
  }

  /** 页签切走前保存该页签的滚动位置（读数不可用时视为本次无位置可保存）。 */
  private saveTabScroll(index: number): void {
    if (index < 0 || index >= this.tabScrollOffsets.length) {
      return;
    }
    let offset: number | undefined = this.readTabScrollerOffset(index);
    if (offset === undefined) {
      return;
    }
    this.tabScrollOffsets[index] = offset;
  }

  /** 切到目标页签后恢复其滚动位置（首次进入为 0，不产生滚动）。 */
  private restoreTabScroll(index: number): void {
    if (index < 0 || index >= this.tabScrollOffsets.length) {
      return;
    }
    // 控制器尚未绑定滚动容器时不做恢复：此时该页签尚无滚动状态，恢复动作无意义
    if (this.readTabScrollerOffset(index) === undefined) {
      return;
    }
    let options: ScrollOptions = { xOffset: 0, yOffset: this.tabScrollOffsets[index] };
    this.tabScrollerAt(index).scrollTo(options);
  }

  /**
   * 跳到任务区并把最新任务行带进视口：清空路由栈回到根、切到任务页签，
   * 且不沿用旧的滚动位置——失败浮卡与单任务通知的详情落点都要求目标行/返回落点可预期。
   */
  private focusTaskCenterTop(): void {
    this.pathStack.clear(false);
    // 页签切换的滚动恢复读取该值：置 0 才能在动画开始时落到顶部
    this.tabScrollOffsets[1] = 0;
    this.switchToTab(1);
    // 已在该页签时 switchToTab 提前返回，直接滚到顶部
    if (this.currentTabIndex === 1) {
      this.tabScrollerAt(1).scrollTo({ xOffset: 0, yOffset: 0 });
    }
  }

  /**
   * 切换主页页签：与底部页签栏切换行为一致——先保存当前页签滚动位置，
   * 再切换页签控制器索引（切换动画开始时由 onAnimationStart 恢复目标页签滚动位置），
   * 并同步互传发现扫描的可见性。宽屏侧边栏选中与发送页「去设置」入口共用。
   */
  private switchToTab(index: number): void {
    if (index < 0 || index >= this.tabScrollOffsets.length || index === this.currentTabIndex) {
      return;
    }
    this.saveTabScroll(this.currentTabIndex);
    this.currentTabIndex = index;
    this.hdsController.changeIndex(index);
    this.updateMtaScanByVisibility();
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

  /** 任务标题栏入口动作：与路由外壳共用同一套装配。 */
  private transferCenterTitleActions(): TransferCenterTitleActions {
    return {
      onOpenFileHistory: () => {
        this.pathStack.pushPathByName('ReceiveHistoryPage', undefined);
      },
      onClearSessionHistory: () => {
        // 先弹二次确认，确认后才执行清空（取消不产生任何效果）
        this.openClearHistoryConfirmDialog();
      }
    };
  }

  /** 打开「清空任务历史」确认弹窗：确认才执行清空，取消 / 点遮罩 / 返回键均不产生效果。 */
  private openClearHistoryConfirmDialog(): void {
    // 打开时构造说明文案（含可清除条数），关闭时在 onDidDisappear 中复位
    this.clearHistoryDialogMessage = buildClearHistoryMessage(this.getUIContext());
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.clearHistoryConfirmDialog();
      },
      onDidDisappear: () => {
        // 取消 / 点击弹窗外区域 / 返回键关闭同样经此复位，不触发清除
        this.clearHistoryDialogMessage = '';
        this.clearHistoryDialogId = -1;
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.clearHistoryDialogId = id;
      })
      .catch(() => {
      });
  }

  /** 关闭确认弹窗并复位弹窗 id（弹窗 id 尚未就绪时为空操作）。 */
  private closeClearHistoryDialog(): void {
    if (this.clearHistoryDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.clearHistoryDialogId);
      this.clearHistoryDialogId = -1;
    }
  }

  /**
   * 打开多选批量删除确认弹窗：确认才执行删除，取消 / 点遮罩 / 返回键均不产生效果。
   * 说明文案含勾选条数，与「清空任务历史」弹窗同样在打开时构造、关闭时复位。
   */
  private openDeleteSelectedConfirmDialog(): void {
    if (this.transferViewModel.selectedCount === 0) {
      return;
    }
    this.deleteSelectedDialogMessage =
      buildDeleteSelectedMessage(this.getUIContext(), this.transferViewModel.selectedCount);
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.deleteSelectedConfirmDialog();
      },
      onDidDisappear: () => {
        this.deleteSelectedDialogMessage = '';
        this.deleteSelectedDialogId = -1;
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.deleteSelectedDialogId = id;
      })
      .catch(() => {
      });
  }

  /** 关闭批量删除确认弹窗并复位弹窗 id（弹窗 id 尚未就绪时为空操作）。 */
  private closeDeleteSelectedDialog(): void {
    if (this.deleteSelectedDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.deleteSelectedDialogId);
      this.deleteSelectedDialogId = -1;
    }
  }

  /** 多选批量删除二次确认弹窗（取消 / 删除两键）。 */
  @Builder
  deleteSelectedConfirmDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.transfer_center_delete_selected_title'),
      content: this.deleteSelectedDialogMessage,
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_cancel'),
        action: () => {
          this.closeDeleteSelectedDialog();
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_confirm'),
        action: () => {
          // 先关闭弹窗再执行删除，避免删除刷新与弹窗关闭竞争
          this.closeDeleteSelectedDialog();
          this.transferViewModel.deleteSelected();
        }
      })
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽（与项目既有弹窗一致）
      .constraintSize({ maxWidth: 480 })
  }

  /** 「清空任务历史」二次确认弹窗（取消 / 确定两键）。 */
  @Builder
  clearHistoryConfirmDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.transfer_center_clear_history_title'),
      content: this.clearHistoryDialogMessage,
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_cancel'),
        action: () => {
          this.closeClearHistoryDialog();
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_confirm'),
        action: () => {
          // 先关闭弹窗再执行清空，避免清空刷新与弹窗关闭竞争
          this.closeClearHistoryDialog();
          this.transferViewModel.clearHistory();
        }
      })
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽（与项目既有弹窗一致）
      .constraintSize({ maxWidth: 480 })
      .id('main_tab_clear_history_dialog')
  }

  /**
   * 标题栏结束端菜单随页签变化：发送=本机信息/常见问题/诊断日志（全部收进「更多」溢出菜单）；
   * 任务=文件接收历史/清空任务历史。
   * 设置页无入口，显式下发空菜单（而非省略菜单字段），确保切页签后不残留上一页签的「更多」入口。
   */
  private currentTabMenu(): HdsNavigationMenuContentOptions {
    if (this.currentTabIndex === 0) {
      // 发送页入口：「本机信息」与求助入口「常见问题」「诊断日志」三项均收进自动生成的「更多」溢出菜单。
      // maxCount 取 1：自动生成的「更多」入口自身占一个槽位，取 1 时「更多」占满槽位，
      // 三项全进原生溢出菜单，标题栏只呈现单个「⋯」；「本机信息」为菜单首项。
      let localDeviceItem: HdsNavigationMenuItemOptions = {
        content: {
          icon: $r('sys.symbol.info_circle'),
          label: $r('app.string.settings_group_local_device'),
          action: () => {
            // 每次打开都从信息页开始（上次可能停在接口页）
            this.localDeviceShowInterfaces = false;
            this.isShowLocalDeviceSheet = true;
          }
        }
      };
      let troubleshootItem: HdsNavigationMenuItemOptions = {
        content: {
          icon: $r('sys.symbol.questionmark_circle'),
          label: $r('app.string.troubleshoot_title'),
          action: () => {
            this.pathStack.pushPathByName('TroubleshootPage', undefined);
          }
        }
      };
      let diagnosticLogsItem: HdsNavigationMenuItemOptions = {
        content: {
          icon: $r('sys.symbol.doc_text'),
          label: $r('app.string.diagnostic_logs_title'),
          action: () => {
            this.pathStack.pushPathByName('HttpLogsPage', undefined);
          }
        }
      };
      let items: Array<HdsNavigationMenuItemOptions> = [localDeviceItem, troubleshootItem, diagnosticLogsItem];
      return { value: items, maxCount: 1 };
    }
    if (this.currentTabIndex === 1) {
      return buildTransferCenterMenuContent(this.transferViewModel.clearableCount,
        this.transferCenterTitleActions());
    }
    return { value: [] };
  }

  /**
   * 主页面标题栏配置：按窗口形态取值。
   * 宽屏下内容区不再自动避让标题栏（改由内容区自行预留顶部避让，见 navigationContent），
   * 且显式下发空标题表示不显示页签名：标题栏配置按字段合并、省略字段会沿用上一次的值，
   * 否则平板由竖屏（有页签名）转为横屏时，页签名会被带进宽屏形态并压在侧边栏区域上方；
   * 其余（底部页签栏）形态下发当前页签名。
   */
  private mainTitleBarOptions(): HdsNavigationTitleBarOptions {
    if (this.useWidescreenSideBar()) {
      return buildImmersiveTitleBar({
        title: '',
        menu: this.currentTabMenu(),
        enableComponentSafeArea: false,
        scrollBlurRadius: 0.0
      });
    }
    return buildImmersiveTitleBar({
      title: this.currentTabTitle(),
      menu: this.currentTabMenu()
    });
  }

  /** 本机信息精简弹窗内容（设备身份 / LocalSend / 网页 / 互传）。 */
  @Builder
  localDeviceSheet() {
    LocalDeviceSection({
      showInterfacePage: this.localDeviceShowInterfaces,
      onRequestInterfacePage: (show: boolean): void => {
        this.switchLocalDevicePage(show);
      }
    })
  }

  /** 本机信息页与网络接口页的左右平移切换（官方 bindSheet 页内切换方案）。 */
  private switchLocalDevicePage(show: boolean): void {
    this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
      this.localDeviceShowInterfaces = show;
    });
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

  /**
   * 侧边栏菜单套件能力探测：HdsSideMenu 所属系统能力与在用的
   * HdsNavigation / HdsTabs（HDSComponent.Core）不同，部分设备可能不具备；
   * 能力缺失时回退到改造前的形态，保证低能力设备仍可正常进入宽屏界面。
   */
  private supportsHdsPattern(): boolean {
    if (this.cachedHdsPatternSupported === undefined) {
      this.cachedHdsPatternSupported = canIUse('SystemCapability.UIDesign.HDSPattern.Standard');
    }
    return this.cachedHdsPatternSupported;
  }

  /**
   * 宽屏侧边栏形态判定：宽度 lg/xl 且设备非平板竖屏，且侧边栏套件能力可用。
   * 为 true 时主界面以常驻宽侧边栏承载导航、内容区单栏；为 false 时沿用底部浮动页签栏形态。
   */
  private useWidescreenSideBar(): boolean {
    if (!this.supportsHdsPattern()) {
      return false;
    }
    return isWidescreenSideBarLayout(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType);
  }

  @Builder
  sendTab() {
    TabContent() {
      Row() {
        // 首帧只保留空的页签容器：发送页重量级内容在首帧之后构建
        if (this.firstFrameContentReady) {
          SendContent({
            viewModel: this.sendViewModel,
            scroller: this.sendScroller,
            onScrollDelta: (deltaY: number, absY: number) => {
              this.handleScrollDelta(deltaY, absY)
            },
            onNavigateTo: (name: string, param: Object | undefined) => {
              this.pathStack.pushPathByName(name, param);
            },
            protocolHintDismissed: this.protocolHintDismissed,
            partialProtocolHintVisible: this.partialProtocolHintVisible,
            onDismissProtocolHint: () => {
              this.protocolHintDismissed = true;
            },
            onOpenSettings: () => {
              // 仅切换页签，不直接改动开关（不存在一键启用捷径）
              this.switchToTab(2);
            },
            onOpenTaskCenter: () => {
              // 浮卡可能浮在子页面之上：先回到根再切任务页签，并把最新任务行带进视口
              this.focusTaskCenterTop();
            },
            onOpenSessionDetail: (sessionId: string) => {
              // 与「查看任务」同源：先回根并切到任务页签，再叠详情页，
              // 使返回时落在任务列表顶部而不是发送页；clear(false) 避免「弹出栈 + 压入」两段动画
              this.focusTaskCenterTop();
              let params: Record<string, string> = { 'sessionId': sessionId };
              this.pathStack.pushPathByName('SessionDetailPage', params);
            },
            shouldShowSendFailureCard: (): boolean => {
              // 后台：结果由系统通知与任务列表承载，回前台不再补一张过期的卡
              if (!isAppForeground()) {
                return false;
              }
              // 仅「任务列表正可见且最新任务行仍在视口内」才抑制：失败行就在第一行。
              // 已滚动到下一条之后、或停在任意子页面时照常弹卡
              let listVisible: boolean = this.currentTabIndex === 1 && this.pathStack.size() === 0;
              if (!listVisible) {
                return true;
              }
              return this.taskFirstVisibleIndex > 0;
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

  // 任务页签标签：存在活跃会话时附带数量角标
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
        // 首帧只保留空的页签容器：任务页重量级内容在首帧之后构建
        if (this.firstFrameContentReady) {
          TransferCenterContent({
            viewModel: this.transferViewModel,
            scroller: this.transferScroller,
            onScrollDelta: (deltaY: number, absY: number) => {
              this.handleScrollDelta(deltaY, absY)
            },
            onNavigateTo: (name: string, param: Object | undefined) => {
              this.pathStack.pushPathByName(name, param);
            },
            onDeleteSelected: () => {
              this.openDeleteSelectedConfirmDialog();
            },
            onFirstVisibleIndexChange: (index: number) => {
              this.taskFirstVisibleIndex = index;
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
        // 首帧只保留空的页签容器：设置页重量级内容在首帧之后构建
        if (this.firstFrameContentReady) {
          SettingsContent({
            scroller: this.settingsScroller,
            onScrollDelta: (deltaY: number, absY: number) => {
              this.handleScrollDelta(deltaY, absY)
            },
            onOpenDiagnosticLogs: () => {
              this.pathStack.pushPathByName('HttpLogsPage', undefined);
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

  /** 宽屏侧边栏面板：下传当前选中索引与活跃会话数，接收选中项变化执行页签切换。 */
  @Builder
  widescreenSideBarPanel() {
    WidescreenSideBar({
      selectedIndex: this.currentTabIndex,
      activeTransferCount: this.viewModel.activeTransferCount,
      onSelect: (index: number): void => {
        this.switchToTab(index);
      }
    })
  }

  /** 底部浮动页签栏形态的页签容器（窄屏、平板竖屏与套件能力降级时使用）。 */
  @Builder
  floatingTabs() {
    // 显式指定当前页签索引：页签容器在断点切换时会被条件渲染重建，不指定则落回默认索引 0，
    // 与标题栏文案（按 currentTabIndex 取值）不一致
    HdsTabs({ controller: this.hdsController, index: this.currentTabIndex }) {
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
      // 页签栏与窗口底边的间距：存在系统导航条时安全区已提供该间距，仅补 4vp 少量间隙（避免贴住导航条）；
      // 无系统导航条（PC 自由窗口、手机/平板小窗）时安全区不提供间距，须显式留出固定 12vp。
      // 该间距加页签栏高度（56vp）仍小于内容底部避让（tabBarClearance 80vp），内容不被页签栏遮挡
      barBottomMargin: this.naviIndicatorHeight > 0 ? DesignTokens.space.xxs : DesignTokens.space.sm,
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
      this.refreshLocalInterfacesIfHomeVisible();
    })
    // 切页签动画开始时即切换标题栏文案/菜单，并恢复目标页签的滚动位置。
    // 横向滑动未达切换阈值松手时会触发回弹动画（index === targetIndex，仍停留在当前页签），
    // 此时保存的滚动位置是旧值，恢复会把当前页签拉回过去的位置（表现为回到顶部），故仅在实际切换时恢复
    .onAnimationStart((index: number, targetIndex: number) => {
      this.currentTabIndex = targetIndex;
      if (index !== targetIndex) {
        this.restoreTabScroll(targetIndex);
      }
    })
    .width('100%')
    .height('100%')
  }

  /**
   * 宽屏形态的页签容器：导航已由常驻宽侧边栏承担，故隐藏页签栏
   * （页签栏高度归零且禁用滑动切换），仅保留 TabContent 的切换回调与滚动位置保持链路。
   */
  @Builder
  hiddenBarTabs() {
    // 显式指定当前页签索引：容器重建（断点切换）后回到用户当前页签，与标题栏文案保持一致
    HdsTabs({ controller: this.hdsController, index: this.currentTabIndex }) {
      this.sendTab()
      this.transferTab()
      this.settingsTab()
    }
    .animationDuration(DesignTokens.animation.durationNormal)
    .barHeight(0)
    .scrollable(false)
    .barPosition(BarPosition.End)
    .vertical(false)
    .onChange((index: number) => {
      this.currentTabIndex = index;
      this.showTabBar();
      this.updateMtaScanByVisibility();
      this.refreshLocalInterfacesIfHomeVisible();
    })
    // 切页签动画开始时即切换标题栏文案/菜单，并恢复目标页签的滚动位置。
    // 横向滑动未达切换阈值松手时会触发回弹动画（index === targetIndex，仍停留在当前页签），
    // 此时保存的滚动位置是旧值，恢复会把当前页签拉回过去的位置（表现为回到顶部），故仅在实际切换时恢复
    .onAnimationStart((index: number, targetIndex: number) => {
      this.currentTabIndex = targetIndex;
      if (index !== targetIndex) {
        this.restoreTabScroll(targetIndex);
      }
    })
    .width('100%')
    .height('100%')
    // 页签容器自身默认会裁剪超出其范围的子组件：不关闭则页签内容无法延伸至标题栏区域，
    // 标题栏透视/材质下无可透出内容；须与页签内容容器的不裁剪配套设置
    .clip(false)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 导航内容区：宽屏为「左宽侧边栏 + 右页签内容」两段式布局，其余形态为单栏页签容器。 */
  @Builder
  navigationContent() {
    // 页签容器形态：宽屏（lg/xl 且非平板竖屏、套件能力可用）→ 常驻宽侧边栏 + 隐藏页签栏的内容区；
    // 其余情况（手机、平板竖屏 600~840vp 及以上）→ 底部浮动水平栏
    // 窗口高度不参与形态判断：矮窗下侧边栏同样可用，且比底部页签栏更省竖向空间
    if (this.useWidescreenSideBar()) {
      Row() {
        // 左侧常驻宽侧边栏：宽度固定，不提供折叠与拖拽调宽。
        // 内容区已不再自动避让标题栏，本列因此自顶部高度带起排布，品牌区与内容区标题栏同高并列；
        // 底色同时向上延伸到系统状态栏区域，避免顶部出现与内容区不同色的空白带
        Column() {
          this.widescreenSideBarPanel()
        }
        .width(DesignTokens.size.widescreenSideBarWidth)
        .height('100%')
        .backgroundColor($r('app.color.accent_blue_bg'))
        // 侧边栏底色延伸至顶部高度带与底部系统导航条区域：与内容区同策略
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        // 右侧内容区：页签栏已由侧边栏承担，页签容器仅保留切换与滚动位置链路；
        // 顶部避让由本列自行保留（取标题栏高度，见 DesignTokens.size.widescreenSideBarHeaderHeight），
        // 内容区关闭自动避让后页签内容仍不被标题栏遮挡
        Column() {
          this.hiddenBarTabs()
        }
        .layoutWeight(1)
        .height('100%')
        .padding({ top: DesignTokens.size.widescreenSideBarHeaderHeight })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      // 安全区扩展逐层设置：侧边栏底色与内容区背景均需铺满系统栏区域
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          this.floatingTabs()
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
  }

  build() {
    // 导航容器始终为页面根容器；两种形态仅内容区不同。
    // 宽屏（平板横屏 / 折叠屏展开 / PC）时内容区为「常驻宽侧边栏 + 单栏内容」两段式布局，
    // 其余情况（手机、平板竖屏、套件能力缺失）沿用底部浮动页签栏形态
    HdsNavigation(this.pathStack) {
      this.navigationContent()
    }
    .width('100%')
    .height('100%')
    // 导航根容器使用绘制级安全区扩展：背景/分割线绘制到系统安全区，布局仍避让系统安全区，
    // 底部悬浮页签的间距（barFloatingStyle.barBottomMargin）条件化：有系统导航条时安全区
    // 自动提供导航条间距、该间距补 4vp；无导航条时安全区不提供、回退固定 12vp。
    // 导航条高度经 avoidAreaChange 监听动态更新（全屏/小窗/分屏/旋转/折叠），
    // 若根容器改用布局级忽略安全区，安全区不再提供该间距、页签会贴住系统小白条
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 导航根容器设置与页面一致的背景色：冷启动首帧窗口内容未覆盖顶部区域时不透出壁纸
    .backgroundColor($r('app.color.page_background'))
    // 主页面为根页面无返回语义：隐藏返回入口；工具栏不使用
    .titleMode(HdsNavigationTitleMode.MINI)
    .titleBar(this.mainTitleBarOptions())
    .hideBackButton(true)
    .hideToolBar(true)
    // 只绑定当前页签的滚动控制器：嵌套底部页签时逐页签绑定才能保留标题栏滚动模糊
    .bindToScrollable([this.currentTabScroller()])
    // 强制单栏：避免宽屏（≥600vp，平板/PC/折叠屏展开态）下 Navigation Auto 自动分栏，
    // 导致主页面被限制在左侧 navBar 区域、右侧内容区空白（本功能不做宽屏分栏，子页面全屏推入）
    .mode(NavigationMode.Stack)
    .bindSheet($$this.isShowLocalDeviceSheet, this.localDeviceSheet(),
      buildLocalDeviceSheetOptions(this.breakpointInfo.widthBreakpoint, (): boolean => {
        // 接口页时系统返回键先退回信息页，不关闭半模态
        if (!this.localDeviceShowInterfaces) {
          return false;
        }
        this.switchLocalDevicePage(false);
        return true;
      }))
    // 首页栏可见性联动互传发现扫描：推入子页面即停止扫描，返回时恢复
    .onNavBarStateChange((visible: boolean) => {
      this.navBarVisible = visible;
      this.updateMtaScanByVisibility();
    })
  }
}
