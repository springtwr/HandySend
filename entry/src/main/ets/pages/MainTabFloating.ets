import {
  AlertDialogV2,
  AdvancedDialogV2Button,
  ComponentContent,
  mediaquery,
  promptAction,
  uiObserver
} from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
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
import { buildClearHistoryMessage } from '../views/transfer/ClearHistoryConfirmDialog';
import { SendContent } from '../components/SendContent';
import { SettingsContent } from '../components/SettingsContent';
import { TransferCenterContent } from './TransferCenterPage';
import { LocalDeviceSection } from '../views/settings/LocalDeviceSection';
import { initAllPreferences } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';
import {
  initAppService,
  startLocalServer,
  stopLocalServer,
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
  consumePendingNavigation
} from '../service/AppService';
import { isAppForeground } from '../service/repository/AppCore';
import { NAV_TARGET_TRANSFER_CENTER } from '../utils/WantAgentUtil';
import {
  isSaveToGallery, getLocalSendEnabled, getMtaEnabled
} from '../service/repository/SettingsRepository';
import {
  querySessions, getSession, subscribeSessions, unsubscribeSessions
} from '../service/transfer/TransferSessionRegistry';
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
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:MainTabFloating', '首页');

@Entry
@ComponentV2
struct MainTabFloating {
  // 系统宽度断点（@Env 随窗口尺寸变化自动刷新，宽 320vp~520vp 范围）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: MainTabViewModel = new MainTabViewModel();
  // 任务视图模型：由主入口持有并下传内容组件，标题栏入口与列表共享同一份历史状态
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
  // 「两个协议均禁用」提示卡的关闭状态：本次会话内有效、不持久化（双关解除后复位）
  @Local protocolHintDismissed: boolean = false
  // 本机信息半模态显隐
  @Local private isShowLocalDeviceSheet: boolean = false
  // 清除任务历史确认弹窗的说明文案（打开时构造，关闭时清空）
  @Local private clearHistoryDialogMessage: string = ''
  // 当前打开的确认弹窗 id（关闭时使用）
  private clearHistoryDialogId: number = -1
  // 新传输提示弹窗：在场标记（单槽位守卫，覆盖打开未决期的重入）、弹窗 id（关闭用）与当前待提示会话
  private newTransferDialogOpen: boolean = false
  private newTransferDialogId: number = -1
  private newTransferDialogSessionId: string = ''
  // 新传输提示弹窗正文（打开时构造，关闭时清空）
  @Local private newTransferDialogMessage: string = ''
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

  // 设置变化回调：两个开关不再同时关闭时复位提示关闭状态，
  // 使用户下次再进入「双关死路」时仍能看到提示（本次会话内关闭状态不持久化）。
  private settingsChangedCallback: () => void = (): void => {
    if (getLocalSendEnabled() || getMtaEnabled()) {
      this.protocolHintDismissed = false;
    }
  }

  // 通知深链回调：热启动（Ability 存活）时经变更总线送达，消费并执行导航
  private navigationCallback: () => void = (): void => {
    this.handlePendingNavigation();
  }

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    initAllPreferences(context);

    initAppService(context);
    // LocalSend 总开关关闭时不自动启动服务器（关闭状态跨重启保持）
    if (getLocalSendEnabled()) {
      startLocalServer().catch((_e: Error) => {
        // 服务器启动失败由 AppService 记录日志
      });
    } else {
      logger.debug('LocalSend 总开关已关闭，首页出现时不启动服务器');
    }

    this.shortHeightListener = this.getUIContext().getMediaQuery().matchMediaSync('(height<600vp)');
    this.shortHeightListener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isShortHeight = result.matches;
    });
    this.isShortHeight = this.shortHeightListener.matches;

    // 角标刷新订阅统一变更总线（与任务列表同源同时机）；
    // 新的待确认会话经 autoOpenSessionId 信号（见 onAutoOpenSessionChanged）弹出新传输提示弹窗
    this.viewModel.start();
    this.transferViewModel.start();

    // 相册保存自动提示：接收完成后用户未必停留在详情页，故在壳层订阅统一变更总线触发
    this.galleryPromptCallback = (): void => {
      this.detectAutoGalleryPrompt();
    };
    subscribeSessions(this.galleryPromptCallback);
    // 设置变化订阅：用于复位「两个协议均禁用」提示卡的关闭状态（详见回调注释）
    subscribe(this.settingsChangedCallback);
    // 通知深链订阅：热启动时消费深链信号并导航
    subscribe(this.navigationCallback);

    // 将内容组件真实使用的滚动控制器绑定到 HdsTabsController 以实现滚动感知动画
    this.hdsController.bindScroller(0, this.sendScroller);
    this.hdsController.bindScroller(1, this.transferScroller);
    this.hdsController.bindScroller(2, this.settingsScroller);

    // 冷启动深链：onCreate 已置位信号，此处首次消费（onPageShow 亦会兜底一次，消费即清空不重复）
    this.handlePendingNavigation();
  }

  aboutToDisappear(): void {
    this.viewModel.stop();
    this.transferViewModel.stop();
    unsubscribeSessions(this.galleryPromptCallback);
    unsubscribe(this.settingsChangedCallback);
    unsubscribe(this.navigationCallback);
    stopLocalServer();
    this.hdsController.unbindScroller(this.sendScroller);
    this.hdsController.unbindScroller(this.transferScroller);
    this.hdsController.unbindScroller(this.settingsScroller);
    if (this.shortHeightListener !== null) {
      this.shortHeightListener.off('change');
    }
  }

  /**
   * 消费通知深链信号：命中「任务中心」时先清空路由栈回到根（清掉已推入的子页面），
   * 再切到任务页签，保证点击通知回前台后展示任务中心列表而非退出时所在页面。
   * 信号为一次性，消费即清空，重复触发无副作用。
   */
  private handlePendingNavigation(): void {
    let target: string = consumePendingNavigation();
    if (target !== NAV_TARGET_TRANSFER_CENTER) {
      return;
    }
    this.pathStack.clear();
    this.switchToTab(1);
  }

  /**
   * 收到新的接收请求（新的待确认会话）：在应用前台任意页面之上弹出新传输提示弹窗。
   * 消费 autoOpenSessionId 信号；非前台不消费（保留待回前台补弹，见 onPageShow）；
   * 已有弹窗在场时不消费（保留信号，弹窗关闭后再试），保证同一时刻仅一个弹窗。
   */
  @Monitor('viewModel.autoOpenSessionId')
  onAutoOpenSessionChanged(): void {
    this.tryOpenNewTransferDialog();
  }

  /**
   * 尝试弹出新传输提示弹窗：仅在应用前台、存在待提示信号且当前无弹窗在场时打开；
   * 信号在打开前消费（会话已消失时同样消费，避免残留重复触发）。
   */
  private tryOpenNewTransferDialog(): void {
    if (!isAppForeground()) {
      return;
    }
    let sessionId: string = this.viewModel.autoOpenSessionId;
    if (sessionId.length === 0) {
      return;
    }
    if (this.newTransferDialogOpen) {
      return;
    }
    this.viewModel.autoOpenSessionId = '';
    let session = getSession(sessionId);
    if (session === undefined) {
      // 会话已消失（被处理/回收）：仅消费信号，不弹窗
      return;
    }
    this.newTransferDialogSessionId = sessionId;
    this.newTransferDialogMessage = this.buildNewTransferMessage(session);
    this.openNewTransferDialog();
  }

  /** 新传输提示弹窗正文：对端名称 + 文件数量（按当前会话即时解析模板占位符）。 */
  private buildNewTransferMessage(session: TransferSession): string {
    let peer: string = session.peer.displayName.length > 0 ? session.peer.displayName :
      getStringSync(this.getUIContext(), $r('app.string.session_peer_unknown_device'));
    let template: string = getStringSync(this.getUIContext(), $r('app.string.new_transfer_alert_message'));
    return template.replace('%s', peer).replace('%d', String(session.files.length));
  }

  /**
   * 打开新传输提示弹窗（单槽位）：
   * 打开前同步置位在场标记（覆盖 openCustomDialog 未决期间的重入），
   * 关闭/打开失败均复位并尝试补弹在场期间到达的其它新会话，保证提示不丢失。
   */
  private openNewTransferDialog(): void {
    this.newTransferDialogOpen = true;
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.newTransferConfirmDialog();
      },
      onDidDisappear: () => {
        // 「稍后」/点击遮罩/返回键关闭同样经此复位
        this.resetNewTransferDialogState();
        this.tryOpenNewTransferDialog();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.newTransferDialogId = id;
      })
      .catch(() => {
        // 打开失败：复位状态并尝试补弹，避免待提示信号丢失
        this.resetNewTransferDialogState();
        this.tryOpenNewTransferDialog();
      });
  }

  /** 复位新传输提示弹窗状态（在场标记、弹窗 id 与文案）。 */
  private resetNewTransferDialogState(): void {
    this.newTransferDialogOpen = false;
    this.newTransferDialogId = -1;
    this.newTransferDialogMessage = '';
    this.newTransferDialogSessionId = '';
  }

  /** 关闭新传输提示弹窗（弹窗 id 尚未就绪时为空操作）。 */
  private closeNewTransferDialog(): void {
    if (this.newTransferDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.newTransferDialogId);
      this.newTransferDialogId = -1;
    }
  }

  /** 新传输提示弹窗（「稍后」/「查看」两键）。 */
  @Builder
  newTransferConfirmDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.new_transfer_alert_title'),
      content: this.newTransferDialogMessage,
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.new_transfer_alert_later'),
        action: () => {
          // 仅关闭，不改变当前页面
          this.closeNewTransferDialog();
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.new_transfer_alert_view'),
        action: () => {
          let sessionId: string = this.newTransferDialogSessionId;
          this.closeNewTransferDialog();
          if (sessionId.length > 0) {
            let params: Record<string, string> = { 'sessionId': sessionId };
            this.pathStack.pushPathByName('SessionDetailPage', params);
          }
        }
      })
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽（与项目既有弹窗一致）
      .constraintSize({ maxWidth: 480 })
      .id('main_tab_new_transfer_dialog')
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
      // 保存至少一个媒体即回写接收历史的「已保存到相册」标记（按协议会话标识匹配历史条目）
      if (result.successCount > 0 && protocolSessionId.length > 0) {
        updateGallerySavedStatus(protocolSessionId, true);
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

  onPageShow(): void {
    this.updateMtaScanByVisibility();
    // 冷启动/热启动兜底：消费可能仍待处理的深链信号（消费即清空，不重复导航）
    this.handlePendingNavigation();
    // 覆盖「待确认请求在后台到达、回到前台」的场景：补弹一次（非前台时未消费信号）
    this.tryOpenNewTransferDialog();
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
      onOpenLocalDevice: () => {
        this.isShowLocalDeviceSheet = true;
      },
      onOpenFileHistory: () => {
        this.pathStack.pushPathByName('ReceiveHistoryPage', undefined);
      },
      onClearSessionHistory: () => {
        // 先弹二次确认，确认后才执行清除（取消不产生任何效果）
        this.openClearHistoryConfirmDialog();
      }
    };
  }

  /** 打开「清除任务历史」确认弹窗：确认才执行清除，取消 / 点遮罩 / 返回键均不产生效果。 */
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

  /** 「清除任务历史」二次确认弹窗（取消 / 清除两键）。 */
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
          // 先关闭弹窗再执行清除，避免清除刷新与弹窗关闭竞争
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
   * 标题栏结束端菜单随页签变化：发送=故障排查/诊断日志（收进「更多」溢出菜单）；
   * 任务=本机信息+更多。
   * 设置页无入口，显式下发空菜单（而非省略菜单字段），确保切页签后不残留上一页签的「更多」入口。
   */
  private currentTabMenu(): HdsNavigationMenuContentOptions {
    if (this.currentTabIndex === 0) {
      // 发送页求助入口：「故障排查」与「诊断日志」两项均收入自动生成的「更多」溢出菜单。
      // maxCount 取 1：自动生成的「更多」入口自身占用一个槽位，取 1 时「更多」占满槽位、
      // 两项全部进其原生溢出菜单，标题栏呈现单个「⋯」入口，样式与任务页菜单一致。
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
      let items: Array<HdsNavigationMenuItemOptions> = [troubleshootItem, diagnosticLogsItem];
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
   * 宽屏侧边栏形态判定：宽度 lg/xl 且设备非平板竖屏、窗口非矮窗，且侧边栏套件能力可用。
   * 为 true 时主界面以常驻宽侧边栏承载导航、内容区单栏；为 false 时沿用底部浮动页签栏形态。
   */
  private useWidescreenSideBar(): boolean {
    if (!this.supportsHdsPattern()) {
      return false;
    }
    return isWidescreenSideBarLayout(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType, this.isShortHeight);
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
          },
          protocolHintDismissed: this.protocolHintDismissed,
          onDismissProtocolHint: () => {
            this.protocolHintDismissed = true;
          },
          onOpenSettings: () => {
            // 仅切换页签，不直接改动开关（不存在一键启用捷径）
            this.switchToTab(2);
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

  /** 底部浮动页签栏形态的页签容器（窄屏、平板竖屏、矮窗与套件能力降级时使用）。 */
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
      // 页签栏与窗口底边的固定间距（12vp）：无系统导航条的窗口形态（PC 自由窗口、手机/平板小窗）下
      // 安全区不提供间距，须显式留出；有系统导航条时安全区与之间距叠加，观感协调。
      // 该间距加页签栏高度（56vp）仍小于内容底部避让（tabBarClearance 80vp），内容不被页签栏遮挡
      barBottomMargin: DesignTokens.space.sm,
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
    })
    // 切页签动画开始时即切换标题栏文案/菜单，并恢复目标页签的滚动位置
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

  /** 导航内容区：宽屏为「左宽侧边栏 + 右页签内容」两段式布局，其余形态为单栏页签容器。 */
  @Builder
  navigationContent() {
    // 页签容器形态：宽屏（lg/xl 且非平板竖屏、非矮窗、套件能力可用）→ 常驻宽侧边栏 + 隐藏页签栏的内容区；
    // 其余情况（手机、平板竖屏 600~840vp 及以上、矮窗）→ 底部浮动水平栏
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
    // 其余情况（手机、平板竖屏、矮窗、套件能力缺失）沿用底部浮动页签栏形态
    HdsNavigation(this.pathStack) {
      this.navigationContent()
    }
    .width('100%')
    .height('100%')
    // 导航根容器延伸至系统状态栏与导航条区域：标题栏模糊覆盖状态栏所在高度、页面背景铺满屏幕
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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
      buildLocalDeviceSheetOptions(this.breakpointInfo.widthBreakpoint))
    // 首页栏可见性联动互传发现扫描：推入子页面即停止扫描，返回时恢复
    .onNavBarStateChange((visible: boolean) => {
      this.navBarVisible = visible;
      this.updateMtaScanByVisibility();
    })
  }
}
