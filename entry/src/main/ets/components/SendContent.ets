import { pasteboard, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { unifiedDataChannel, uniformTypeDescriptor } from '@kit.ArkData';
import {
  curves,
  CustomContentDialogV2,
  AlertDialogV2,
  AdvancedDialogV2Button,
  promptAction,
  uiObserver
} from '@kit.ArkUI';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import {
  subscribe, unsubscribe, connectByIp, getPort,
  getHttpsEnabled, resolveSendProtocol, isAutoOpenSessionDetailAfterSend
} from '../service/AppService';
import { DiscoveredDevice, StagedFile, FavoriteDevice } from '../model/Types';
import { SendContentZone } from './send/SendContentZone';
import { SendTargetZone } from './send/SendTargetZone';
import { setTransferMethodDispatcher } from '../service/transfer/DefaultRegistrations';
import { DesignTokens } from '../common/DesignTokens';
import { subscribeOverlayClose, unsubscribeOverlayClose } from '../utils/OverlayCloseBus';
import { getSheetWidth, isNarrowWidth, isWidescreenSideBarLayout, isWideWidth } from '../common/Breakpoints';
import {
  SendViewModel,
  SendInitiateResult,
  SendFailureNotice,
  MtaSendOutcome,
  FavoriteSendResult,
  shouldShowPartialProtocolDisabledHint,
  shouldShowProtocolDisabledHint
} from '../viewmodel/SendViewModel';
import { FavoriteDevicesViewModel } from '../viewmodel/FavoriteDevicesViewModel';
import { FavoriteDevicesSheet } from '../views/FavoriteDevicesSheet';
import { isValidIpAddress } from '../utils/IPValidator';
import { isLargeTransfer } from '../utils/LargeTransferUtil';
import { formatSizeDetailed } from '../utils/FormatUtil';
import { getStringSync } from '../utils/ResourceUtil';
import { parseDroppedRecords, fetchDroppedUnifiedData, DragDropParseResult } from '../model/DragDropParser';
import { isMtaDevice, MtaSendRequest } from '../model/mta/MtaMainModels';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendContent', '发送内容');

@ComponentV2
export struct SendContent {
  // 系统宽度断点（随窗口尺寸变化自动刷新，收藏面板宽度断点化用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  // 发送页视图模型由页面宿主持有：页签容器跨断点重建时暂存列表等状态不丢失
  @Require @Param viewModel: SendViewModel
  // 滚动控制器由壳层下传：壳层需将它绑定到导航组件（驱动标题栏滚动模糊）与页签控制器
  @Require @Param scroller: Scroller
  @Local refreshAngle: number = 0
  @Local isRestarting: boolean = false
  // 拖拽悬停状态：驱动发送页高亮遮罩显隐（onDragEnter 置真 / onDragLeave 复位 / onDrop 处理完毕复位）
  @Local isDragOver: boolean = false
  @Event onScrollDelta: (deltaY: number, absY: number) => void = (_deltaY: number, _absY: number) => {
  }
  // 页面导航回调（NavBar 首页组件经 UIContext 上抛，由 MainTabFloating 持有 pathStack 执行）
  @Event onNavigateTo: (name: string, param: Object | undefined) => void =
    (_name: string, _param: Object | undefined) => {
    }
  // 协议状态提示卡的关闭状态（部分关闭与全部关闭提示共用）：由页面宿主持有并下传
  // （跨 TabContent 重建保持，不持久化，重启应用后重新提示）
  @Param protocolHintDismissed: boolean = false
  // 本次启动是否允许显示「部分传输方式已关闭」提示（同一关闭状态只提示一次）
  @Param partialProtocolHintVisible: boolean = false
  // 关闭该提示（本次会话内不再显示）
  @Event onDismissProtocolHint: () => void = () => {
  }
  // 跳转设置页（仅切换页签，不直接改动开关）
  @Event onOpenSettings: () => void = () => {
  }
  // 切到任务页（多条失败的动作入口）
  @Event onOpenTaskCenter: () => void = () => {
  }
  // 打开指定会话详情（单条失败的动作入口；宿主负责先回根再切换页签）
  @Event onOpenSessionDetail: (sessionId: string) => void = (_sessionId: string) => {
  }
  // 当前是否应由浮卡提醒失败（宿主判定页面可见性：任务列表在场/应用在后台时不打扰）
  @Event shouldShowSendFailureCard: () => boolean = (): boolean => true
  private refreshCallback: () => void = () => {
  }
  // 文本发送弹窗（B 类 CustomContentDialogV2）输入值
  @Local textSendValue: string = ''
  // 文本弹窗确认按钮可用性：输入非空白（trim 后长度 > 0）时可用，新增/编辑模式统一适用
  @Local textSendValid: boolean = false
  // 文本弹窗编辑目标下标：-1 为新增模式；>= 0 为编辑模式（对应 viewModel.stagedFiles 中条目）
  @Local textEditTargetIndex: number = -1
  // IP 输入弹窗（B 类 CustomContentDialogV2）输入值与校验状态
  @Local ipInputValue: string = ''
  @Local ipInputValid: boolean = false
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1
  // 大文件发送二次确认弹窗文案、待执行发送动作与 Promise 结算回调（关闭时复位）
  @Local largeFileDialogMessage: string = ''
  private largeFileDialogId: number = -1
  private largeFilePendingAction: (() => void) | undefined = undefined
  private largeFileConfirmResolve: ((ok: boolean) => void) | undefined = undefined
  // 收藏设备面板（半模态）显隐与面板状态
  @Local isShowFavoritesSheet: boolean = false
  // 新传输直达详情前的弹层收起：本组件只处理自己打开的收藏面板与发送弹窗
  private overlayCloseCallback: () => void = (): void => {
    this.isShowFavoritesSheet = false;
    this.settleLargeFileConfirm(false);
    this.closeProtocolBlockedDialog();
    this.closeActiveDialog();
    this.closeSendFailureCard();
  }
  @Local favoritesPanelViewModel: FavoriteDevicesViewModel = new FavoriteDevicesViewModel()
  // ── 发送结果反馈：开始确认 toast + 失败浮卡 ──
  // 浮卡内容由 @Local 承载：同一张卡片在连续失败时就地更新，不叠加多个弹窗
  @Local private sendFailureTitle: string = ''
  @Local private sendFailureBody: string = ''
  @Local private sendFailureMulti: boolean = false
  private sendFailureSessionId: string = ''
  private sendFailureCount: number = 0
  private sendFailureLastMessage: string = ''
  // 多条失败时失败原因是否一致：一致才展示具体原因，不一致只提示去任务页查看
  private sendFailureUniform: boolean = true
  private sendFailureDialogId: number = -1
  // 浮卡实例打开的窗口断点签名与代次：跨形态后旧实例不可信，代次用于作废其迟到回调
  private sendFailureCardBreakpoint: string = ''
  private sendFailureCardGeneration: number = 0
  // 协议不兼容拦截：展示文案（只说明不提供动作，改不改设置由用户自行决定）
  @Local private protocolBlockedAlias: string = ''
  @Local private protocolBlockedMessage: string = ''
  private protocolBlockDialogId: number = -1
  // 协议弹窗打开的窗口断点签名与代次：跨形态后旧实例不可信
  private protocolBlockBreakpoint: string = ''
  private protocolBlockGeneration: number = 0
  // 页面已销毁标记：在途发送的回调不再触碰 UI，避免在已销毁的组件上取 UIContext
  private isDetached: boolean = false
  // MTA 发起前会话快照：建链完成即返回，不能靠发起返回判定结果，
  // 改在变更通知里等本次新建会话进入终态（见 checkMtaSendWatch）
  private mtaWatchBeforeIds: Array<string> | undefined = undefined
  // 本次 MTA 发送已自动进入详情的新会话标识：只跳转一次，避免每次注册表变更重复导航
  private mtaAutoOpenSessionId: string = ''

  // 发现快照刷新时更新面板在线状态（面板打开期间设备上线/离线实时反映）
  @Monitor('viewModel.discoveredDevices')
  onDiscoveredDevicesChange(): void {
    this.favoritesPanelViewModel.refreshOnlineStatus();
  }

  // 面板关闭时退出多选：面板视图模型的生命周期跟随发送页（@Local 字段）而非面板本身，
  // bindSheet 关闭只隐藏面板、不销毁该实例，故须在此显式复位，
  // 否则再次打开面板会直接呈现上次遗留的多选态与勾选。
  @Monitor('isShowFavoritesSheet')
  onFavoritesSheetVisibilityChange(): void {
    if (!this.isShowFavoritesSheet) {
      this.favoritesPanelViewModel.exitSelection();
    }
  }

  aboutToAppear(): void {
    this.isDetached = false;
    subscribeOverlayClose(this.overlayCloseCallback);
    // 收藏面板：绑定在线快照来源并订阅收藏变更（新增/重命名/删除面板实时同步）
    this.favoritesPanelViewModel.attach(this.viewModel);
    this.favoritesPanelViewModel.subscribeFavorites();
    this.refreshCallback = () => {
      this.viewModel.refresh();
      // MTA 发送的终态只能从注册表变更通知里拿到（发起返回早于对端确认）
      this.checkMtaSendWatch();
    };
    subscribe(this.refreshCallback);
    this.viewModel.refresh();
    // 方式区动作分发：方式描述符的 action 交由发送页执行真实副作用（弹窗/导航/分享链接）
    setTransferMethodDispatcher((key: string): void => {
      this.onMethodAction(key);
    });
  }

  /** 方式区动作分发：按注册表方式键执行发送页动作。 */
  onMethodAction(key: string): void {
    if (key === 'by-ip') {
      this.onSendByIp();
    } else if (key === 'favorites') {
      this.onOpenFavorites();
    }
  }

  /** 设备详情页路由参数（目标区设备条目信息入口使用）。 */
  private deviceNavParam(device: DiscoveredDevice): Record<string, Object> {
    return {
      'alias': device.alias,
      'ip': device.ip,
      'port': device.port,
      'fingerprint': device.fingerprint,
      'version': device.version,
      'deviceModel': device.deviceModel,
      'deviceType': device.deviceType,
      'protocol': device.protocol
    };
  }

  aboutToDisappear(): void {
    this.isDetached = true;
    unsubscribeOverlayClose(this.overlayCloseCallback);
    unsubscribe(this.refreshCallback);
    this.favoritesPanelViewModel.unsubscribeFavorites();
    // 浮卡挂在 UIContext 层，不随页面销毁自动消失：离开发送页时主动关闭
    this.closeSendFailureCard();
  }

  // 连接警告横幅文案：按优先级取一条（无警告时返回 undefined）。
  // 互传发现依赖蓝牙、互传传输依赖 WLAN（有线局域网不可替代），故 WLAN 关闭时
  // 需区分局域网是否可用：不可用时与「未连接局域网」合并为同一提示，可用时只提示互传；
  // 局域网警告需服务器就绪。互传相关提示受「显示互传提醒」设置控制（关闭时不提示）。
  // 协议总开关关闭的类别不再提示（主动禁用不是故障，改由中性禁用提示行说明）。
  private getConnectionWarningText(): ResourceStr | undefined {
    if (this.viewModel.mtaEnabled && this.viewModel.mtaConnectionWarnings) {
      if (!this.viewModel.mtaWifiOn && this.viewModel.noWifiWarning) {
        // 该合并提示只在 LocalSend 与互传均开启时成立；LocalSend 已关闭时只说明互传自身的 WLAN 依赖
        return this.viewModel.localSendEnabled ?
          $r('app.string.wifi_off_lan_and_mta_warning') :
          $r('app.string.mta_wifi_off_standalone_warning');
      }
      if (!this.viewModel.mtaWifiOn && !this.viewModel.mtaBluetoothOn) {
        return $r('app.string.mta_bt_wifi_off_warning');
      }
      if (!this.viewModel.mtaWifiOn) {
        return $r('app.string.mta_wifi_off_lan_ok_warning');
      }
    }
    if (this.viewModel.localSendEnabled && this.viewModel.noWifiWarning && this.viewModel.serverReady) {
      return $r('app.string.no_wifi_warning');
    }
    if (this.viewModel.localSendEnabled && this.viewModel.allInterfacesDisabled && this.viewModel.serverReady) {
      return $r('app.string.all_interfaces_disabled_warning');
    }
    if (this.viewModel.mtaEnabled && this.viewModel.mtaConnectionWarnings && !this.viewModel.mtaBluetoothOn) {
      return $r('app.string.mta_bluetooth_off_warning');
    }
    return undefined;
  }

  // 部分关闭提示文案：动态列出已关闭的传输方式（网页传输默认关闭且面板内自带开启入口，
  // 不列入本提示；全部关闭时由「所有传输方式均已关闭」提示负责）
  private partialProtocolHintText(): string {
    let names: Array<string> = [];
    if (!this.viewModel.localSendEnabled) {
      names.push(getStringSync(this.getUIContext(), $r('app.string.localsend_enabled_label')));
    }
    if (!this.viewModel.mtaEnabled) {
      names.push(getStringSync(this.getUIContext(), $r('app.string.mta_enabled_label')));
    }
    let template: string = getStringSync(this.getUIContext(),
      $r('app.string.send_partial_protocols_disabled_hint'));
    return template.replace('%s', names.join(' / '));
  }

  handlePasteData(text: string): void {
    try {
      if (!this.viewModel.handlePasteData(text)) {
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.send_clipboard_empty'), duration: 2000 });
        return;
      }
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_clipboard_pasted'), duration: 2000 });
    } catch (e) {
      logger.error('粘贴数据处理失败：' + JSON.stringify(e));
    }
  }

  // 拖放目标处理：获取 UDMF 数据（首次失败 1500ms 重试一次）→ 解析分流 → 暂存 → 反馈拖拽结果。
  // 结果语义：数据获取失败或整批类型均不支持时反馈失败（不支持时同时提示）；
  // 存在可处理内容即反馈成功，包括内容因重复去重而未新增的拖入（操作已接受、仅未新增条目）。
  private handleDropContent(event: DragEvent): void {
    fetchDroppedUnifiedData(event, (data: unifiedDataChannel.UnifiedData | undefined) => {
      if (data === undefined) {
        this.isDragOver = false;
        event.setResult(DragResult.DRAG_FAILED);
        logger.warn('拖放已拒绝：获取 UDMF 数据失败');
        return;
      }
      let records: Array<unifiedDataChannel.UnifiedRecord> = data.getRecords();
      // 来源类型诊断：输出每条记录的 UTD 类型，便于确认中转站等来源实际拖出的数据类型
      // （如拖出图片是 general.image 还是 general.file）
      let types: Array<string> = [];
      for (let i = 0; i < records.length; i++) {
        types.push(records[i].getType());
      }
      logger.debug('拖放记录：count=' + records.length + ' types=' + types.join(','));
      let result: DragDropParseResult = parseDroppedRecords(records);
      let added: boolean = this.viewModel.applyDroppedContent(result);
      // 整批均无任何可处理内容（不支持类型）才算失败；重复内容已走暂存去重、语义上仍是已接受
      let unsupported: boolean = result.uris.length === 0 && result.texts.length === 0;
      this.isDragOver = false;
      event.setResult(unsupported ? DragResult.DRAG_FAILED : DragResult.DRAG_SUCCESSFUL);
      logger.debug('拖放已处理：uris=' + result.uris.length + ' texts=' + result.texts.length +
        ' added=' + added + ' unsupported=' + unsupported);
      if (unsupported) {
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.drag_drop_unsupported'), duration: 2000 });
      }
      // 移动端会话首次拖入含文件类内容：弹出可靠性提示（须手动关闭）
      if (this.viewModel.shouldShowDropReliabilityHint(result.uris.length > 0)) {
        this.openDropReliabilityNotice();
      }
    });
  }

  // 拖入文件类内容的可靠性提示：移动端会话首次拖入文件类内容时弹出。
  // autoCancel:false 禁止点击外部关闭，必须点击「知道了」手动关闭。
  // 提示缘由：拖入文件的 URI 由来源应用/中转站托管，关闭后可能不可读（文本已写入沙箱不受影响）。
  private openDropReliabilityNotice(): void {
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.dropReliabilityNoticeDialog();
      },
      autoCancel: false
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
      });
  }

  @Builder
  dropReliabilityNoticeDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.drag_drop_reliability_title'),
      content: $r('app.string.drag_drop_reliability_message'),
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.drag_drop_reliability_ok'),
        action: () => {
          this.closeActiveDialog();
        }
      })
    })
  }

  // 大文件发送二次确认：暂存总量达到阈值时先弹确认（取消/发送两键），否则直接执行
  private runAfterLargeFileConfirm(action: () => void): void {
    let totalBytes: number = this.viewModel.getStagedTotalBytes();
    if (!isLargeTransfer(totalBytes)) {
      action();
      return;
    }
    this.largeFilePendingAction = action;
    this.largeFileConfirmResolve = undefined;
    this.openLargeFileConfirmDialog(totalBytes);
  }

  // 大文件发送二次确认（Promise 版，供 async 发送链路使用）：无需确认返回真；
  // 需确认时弹确认框，确认返回真，取消/关闭返回假
  private confirmLargeFileIfNeeded(): Promise<boolean> {
    let totalBytes: number = this.viewModel.getStagedTotalBytes();
    if (!isLargeTransfer(totalBytes)) {
      return Promise.resolve(true);
    }
    return new Promise<boolean>((resolve: (ok: boolean) => void) => {
      this.largeFilePendingAction = undefined;
      this.largeFileConfirmResolve = resolve;
      this.openLargeFileConfirmDialog(totalBytes);
    });
  }

  /** 打开大文件确认弹窗（调用方已备好待执行动作或结算回调）。 */
  private openLargeFileConfirmDialog(totalBytes: number): void {
    this.largeFileDialogMessage = getStringSync(this.getUIContext(),
      $r('app.string.large_file_send_confirm_message')).replace('%s', formatSizeDetailed(totalBytes));
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.largeFileConfirmDialog();
      },
      onDidDisappear: () => {
        // 遮罩/返回关闭同样视为取消：结算未完成的 Promise，避免 async 链路悬挂
        let resolve = this.largeFileConfirmResolve;
        this.largeFileDialogMessage = '';
        this.largeFileDialogId = -1;
        this.largeFilePendingAction = undefined;
        this.largeFileConfirmResolve = undefined;
        if (resolve !== undefined) {
          resolve(false);
        }
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.largeFileDialogId = id;
      })
      .catch(() => {
      });
  }

  /** 关闭大文件确认弹窗并复位弹窗 id（弹窗 id 尚未就绪时为空操作）。 */
  private closeLargeFileDialog(): void {
    if (this.largeFileDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.largeFileDialogId);
      this.largeFileDialogId = -1;
    }
  }

  /** 结算大文件确认（确认执行暂存动作/结算 Promise，取消两者皆不执行）。 */
  private settleLargeFileConfirm(ok: boolean): void {
    let pending = this.largeFilePendingAction;
    let resolve = this.largeFileConfirmResolve;
    // 先关闭弹窗再执行发送，避免发送刷新与弹窗关闭竞争
    this.closeLargeFileDialog();
    this.largeFilePendingAction = undefined;
    this.largeFileConfirmResolve = undefined;
    if (ok && pending !== undefined) {
      pending();
    }
    if (resolve !== undefined) {
      resolve(ok);
    }
  }

  /** 大文件发送二次确认弹窗（取消 / 发送两键）。 */
  @Builder
  largeFileConfirmDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.large_file_send_confirm_title'),
      content: this.largeFileDialogMessage,
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_cancel'),
        action: () => {
          this.settleLargeFileConfirm(false);
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_confirm'),
        action: () => {
          this.settleLargeFileConfirm(true);
        }
      })
    })
      // 宽屏下限制弹窗最大宽度，避免铺满过宽（与项目既有弹窗一致）
      .constraintSize({ maxWidth: 480 })
      .id('send_large_file_confirm_dialog')
  }

  // 粘贴控件授权成功后的剪贴板读取链路：先预检再读取，避免对空/非纯文本剪贴板发起 getData。
  // 预检采用官方推荐做法——hasData（有内容）与 hasDataType(MIMETYPE_TEXT_PLAIN)（含纯文本），
  // 任一不满足即提示"剪贴板为空"并返回；getPrimaryText 返回 undefined 时规范化为空串，
  // 交由 handlePasteData 内部按空文本提示，消除 undefined 传入 text.length 抛 TypeError 的问题。
  private async readClipboardAndHandle(): Promise<void> {
    try {
      let systemPasteboard = pasteboard.getSystemPasteboard();
      // 预检：剪贴板无内容时不读取数据本体（空态 getData 行为在不同版本存在差异）
      let hasContent: boolean = await systemPasteboard.hasData();
      if (!hasContent) {
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.send_clipboard_empty'), duration: 2000 });
        return;
      }
      // 预检：剪贴板仅含非文本内容（图片/文件/HTML 等）时同样按空处理
      if (!systemPasteboard.hasDataType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.send_clipboard_empty'), duration: 2000 });
        return;
      }
      let pasteData: pasteboard.PasteData = await systemPasteboard.getData();
      // 规范化为空串兜底：读取间隙剪贴板可能被其他应用覆盖，getPrimaryText 仍可能返回 undefined
      let text: string = pasteData.getPrimaryText() ?? '';
      this.handlePasteData(text);
    } catch (e) {
      // 剪贴板服务异常、数据损坏等场景沿用既有兜底提示
      logger.error('剪贴板读取失败：' + JSON.stringify(e));
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.clipboard_read_failed'), duration: 2000 });
    }
  }

  // 刷新旋转使用 springMotion
  refreshDevices(): void {
    // 扫描中/统一刷新中不累加旋转角度（由 LoadingProgress 或既有扫描反馈呈现）
    if (!this.viewModel.isRefreshing && !this.viewModel.isScanning) {
      this.getUIContext()
        .animateTo({
          duration: 800,
          curve: curves.springMotion(DesignTokens.animation.springStiffness, DesignTokens.animation.springDamping)
        }, () => {
          this.viewModel.refreshAngle = this.viewModel.refreshAngle + 360;
        });
    }
    // 统一刷新入口：刷新中重复点击由 ViewModel 合并为一次待补刷
    this.viewModel.refreshAllDevices();
  }

  sendToSelectedDevice(device: DiscoveredDevice): void {
    // 未暂存内容时提示并中断发送（点击设备即发送的统一拦截）
    if (this.viewModel.stagedFiles.length === 0) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_select_file_first'), duration: 2000, alignment: Alignment.Center });
      return;
    }
    // 可预知的加密不兼容在点击时拦截：不建任务、不产生「点击即失败」，改为可操作说明
    if (this.isProtocolBlocked(device)) {
      this.openProtocolBlockedDialog(device);
      return;
    }
    // 大文件先二次确认（取消/发送两键），确认后按设备类型分发
    this.runAfterLargeFileConfirm(() => {
      // MTA（互传联盟）设备：走 MTA 发送编排（会话仍统一登记到注册表）
      if (isMtaDevice(device)) {
        this.sendToMtaDevice(device);
        return;
      }
      // 点击设备即发送：统一走内联发送（无单/多目标模式差异，停留发送页）
      this.beginInlineSend(device);
    });
  }

  /** 该目标是否因加密不兼容无法发送（判定与发送链路共用 resolveSendProtocol）。 */
  private isProtocolBlocked(device: DiscoveredDevice): boolean {
    if (isMtaDevice(device)) {
      return false;
    }
    return resolveSendProtocol(getHttpsEnabled(), device.protocol === 'https') === null;
  }

  /**
   * 发起内联发送并给出结果反馈：
   * 点击当帧即确认「已开始发送」（不引入人为延迟）；会话终结为失败时弹出失败浮卡
   * （「自动进入任务详情」开启时改为跳转详情页，失败由详情页承载、不再弹卡）。
   * 预判不可发起（忙/无内容）时不弹开始确认，避免两条提示互相打架。
   */
  private beginInlineSend(device: DiscoveredDevice): void {
    let pre: SendInitiateResult = this.viewModel.precheckSend(device);
    if (pre !== SendInitiateResult.initiated) {
      this.showSendInitiateFeedback(pre);
      return;
    }
    // 发送前快照：失败提示只认本次点击后新建的会话，历史失败不会被重复提示
    let beforeIds: Array<string> = this.viewModel.sendSessionIdsForIp(device.ip);
    // 自动进入任务详情：新会话登记后立即跳转，此时发送仍在后台继续；
    // 已进入详情时不再弹失败浮卡（失败原因在详情页可见）
    let autoEnterDetail: boolean = isAutoOpenSessionDetailAfterSend();
    let autoOpened: boolean = false;
    this.showSendToast($r('app.string.send_started_toast'), device.alias);
    this.viewModel.sendToMultipleDeviceInline(device, (sessionId: string) => {
      if (autoEnterDetail && !this.isDetached) {
        autoOpened = true;
        // 离开发送页前收起既有失败浮卡：浮卡挂在 UIContext 层，切页签不会自动消失，
        // 其内容属于上一次发送，留在详情页会误导
        this.closeSendFailureCard();
        this.onOpenSessionDetail(sessionId);
      }
    }).then((result: SendInitiateResult) => {
      if (this.isDetached) {
        return;
      }
      // 竞态兜底：预判后被并发操作拦截时按实际结果补提示
      this.showSendInitiateFeedback(result);
      let failure: SendFailureNotice | undefined = this.viewModel.newSendFailure(device.ip, beforeIds);
      if (failure !== undefined && !autoOpened) {
        this.showSendFailureCard(failure);
      }
    }).catch((e: Object) => {
      logger.error('发送启动失败：' + String(e));
    });
  }

  /** 发送结果轻提示（%s 为目标设备名）。 */
  private showSendToast(text: Resource, alias: string): void {
    this.getUIContext()
      .getPromptAction()
      .showToast({
        message: getStringSync(this.getUIContext(), text).replace('%s', alias),
        duration: 1500
      });
  }

  // 发送发起结果的可见反馈：被拦截/无内容给出轻提示，已发起保持正常路径（无提示）
  private showSendInitiateFeedback(result: SendInitiateResult): void {
    if (result === SendInitiateResult.blocked) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_device_busy'), duration: 2000, alignment: Alignment.Center });
    } else if (result === SendInitiateResult.noContent) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_select_file_first'), duration: 2000, alignment: Alignment.Center });
    }
  }

  // ── 失败浮卡：只负责提醒与原因，操作收敛到任务区（详情页或任务列表） ──

  /**
   * 展示失败浮卡：已打开时就地更新（多次失败合并为一张卡，按任务数计，不按设备去重）。
   * 单条展示设备名 + 原因；多条不再挑某一台设备，原因一致时展示该原因，不一致时指引去任务页。
   */
  private showSendFailureCard(notice: SendFailureNotice): void {
    // 失败行已在眼前（任务列表）或应用不在前台（结果由系统通知/任务列表承载）时不弹卡
    if (!this.shouldShowSendFailureCard()) {
      logger.debug('失败浮卡跳过：结果已在当前页面可见或应用不在前台');
      return;
    }
    // 窗口形态已变化：旧浮层随页面重建消失，句柄与合并计数一并作废，从本条重新开始
    // （必须在累加计数之前判断，否则重置后标题会显示成「0 个任务失败」）
    let breakpoint: string = this.breakpointSignature();
    if (this.sendFailureCardBreakpoint.length > 0 && this.sendFailureCardBreakpoint !== breakpoint) {
      logger.debug('窗口形态已变化，重建失败浮卡');
      this.discardSendFailureCard();
      this.resetSendFailureCard();
    }
    this.sendFailureCount = this.sendFailureCount + 1;
    let multi: boolean = this.sendFailureCount > 1;
    this.sendFailureMulti = multi;
    if (!multi) {
      this.sendFailureUniform = true;
      this.sendFailureSessionId = notice.sessionId;
    } else {
      this.sendFailureUniform = this.sendFailureUniform && notice.message === this.sendFailureLastMessage;
    }
    this.sendFailureLastMessage = notice.message;
    this.sendFailureTitle = multi ?
      getStringSync(this.getUIContext(), $r('app.string.send_failure_card_title_multi'))
        .replace('%s', this.sendFailureCount.toString()) :
      getStringSync(this.getUIContext(), $r('app.string.send_failure_card_title'))
        .replace('%s', notice.alias);
    if (!multi) {
      // 原因为空时只展示标题，不重复「发送失败」这类无信息量的兜底文案
      this.sendFailureBody = notice.message;
    } else if (this.sendFailureUniform) {
      this.sendFailureBody = notice.message;
    } else {
      this.sendFailureBody = getStringSync(this.getUIContext(), $r('app.string.send_failure_card_mixed'));
    }
    this.openSendFailureCard(breakpoint);
  }

  /** 窗口断点签名（宽|高）：跨形态后旧浮卡实例不可信。 */
  private breakpointSignature(): string {
    return this.breakpointInfo.widthBreakpoint + '|' + this.breakpointInfo.heightBreakpoint;
  }

  /** 打开浮卡（幂等：已打开时只靠 @Local 内容更新，不重复 open）。 */
  private openSendFailureCard(breakpoint: string): void {
    // -1 空闲、-2 打开中、>=0 已打开：打开中同样视为已占用，避免同帧连续失败开出多张卡
    if (this.sendFailureDialogId !== -1) {
      return;
    }
    this.sendFailureDialogId = -2;
    this.sendFailureCardBreakpoint = breakpoint;
    // 代次用于作废旧实例的迟到回调：形态变化后旧实例可能稍后才回调 onDidDisappear，
    // 不设代次会把新实例刚写入的内容清空
    this.sendFailureCardGeneration = this.sendFailureCardGeneration + 1;
    let generation: number = this.sendFailureCardGeneration;
    // 只有宽屏侧边栏形态才贴右下角做桌面式通知；平板竖屏虽然够宽但仍用底部页签，按底部摆放。
    // 宽度：窄屏占窗口 92%，平板/宽屏固定窄卡，避免细长条铺满屏幕
    let sideBarLayout: boolean = isWidescreenSideBarLayout(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType) &&
      canIUse('SystemCapability.UIDesign.HDSPattern.Standard');
    let narrow: boolean = isNarrowWidth(this.breakpointInfo.widthBreakpoint);
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.sendFailureCard();
      },
      // 非模态：不遮挡页面、不拦截周边操作；浮在页面之上但位于系统弹窗之下
      isModal: false,
      autoCancel: false,
      alignment: sideBarLayout ? DialogAlignment.BottomEnd : DialogAlignment.Bottom,
      // 窄屏/平板抬升一行避开底部页签与手势区；宽屏无底部页签，只留页边距
      offset: sideBarLayout ? { dx: -DesignTokens.space.lg, dy: -DesignTokens.space.lg } :
        { dx: 0, dy: -DesignTokens.size.tabBarClearance },
      width: sideBarLayout ? 400 : (narrow ? '92%' : 480),
      // 卡片外观画在弹窗背板上：内容区不再自带底色与描边，避免叠出两层边框
      maskColor: Color.Transparent,
      backgroundColor: $r('app.color.card_background'),
      backgroundBlurStyle: BlurStyle.NONE,
      cornerRadius: DesignTokens.radius.lg,
      borderWidth: DesignTokens.component.borderSlim,
      borderColor: $r('app.color.danger_red'),
      shadow: { radius: 12, color: '#33000000', offsetY: 4 },
      onDidDisappear: () => {
        if (generation !== this.sendFailureCardGeneration) {
          return;
        }
        this.sendFailureDialogId = -1;
        this.resetSendFailureCard();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        // 打开期间又被重建（代次已变）时丢弃旧实例，避免它的 id 覆盖新实例
        if (generation !== this.sendFailureCardGeneration) {
          this.closeDialogById(id);
          return;
        }
        this.sendFailureDialogId = id;
      })
      .catch(() => {
        if (generation !== this.sendFailureCardGeneration) {
          return;
        }
        this.sendFailureDialogId = -1;
        this.resetSendFailureCard();
      });
  }

  /** 按 id 关闭弹窗；实例可能已随窗口重建消失，关闭失败可忽略。 */
  private closeDialogById(id: number): void {
    if (id < 0) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().closeCustomDialog(id);
    } catch (_e) {
    }
  }

  /** 作废旧浮卡实例但保留内容（随后会按新内容重开）。 */
  private discardSendFailureCard(): void {
    this.sendFailureCardGeneration = this.sendFailureCardGeneration + 1;
    this.closeDialogById(this.sendFailureDialogId);
    this.sendFailureDialogId = -1;
  }

  /** 关闭浮卡并清空内容。 */
  private closeSendFailureCard(): void {
    this.sendFailureCardGeneration = this.sendFailureCardGeneration + 1;
    this.closeDialogById(this.sendFailureDialogId);
    this.sendFailureDialogId = -1;
    this.resetSendFailureCard();
  }

  private resetSendFailureCard(): void {
    this.sendFailureTitle = '';
    this.sendFailureBody = '';
    this.sendFailureMulti = false;
    this.sendFailureSessionId = '';
    this.sendFailureCount = 0;
    this.sendFailureLastMessage = '';
    this.sendFailureUniform = true;
    this.sendFailureCardBreakpoint = '';
  }

  /**
   * 浮卡动作：单条失败直接进该会话详情（原因/文件/时间线都在那里）；
   * 多条失败进任务页，由用户自己挑要看的任务——合并后不替用户选其中一条。
   */
  private openFailureTarget(): void {
    let multi: boolean = this.sendFailureMulti;
    let sessionId: string = this.sendFailureSessionId;
    this.closeSendFailureCard();
    if (!multi && sessionId.length > 0) {
      this.onOpenSessionDetail(sessionId);
      return;
    }
    this.onOpenTaskCenter();
  }

  @Builder
  sendFailureCard() {
    Row({ space: DesignTokens.space.sm }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(DesignTokens.font.iconInline)
        .fontColor([$r('app.color.danger_red')])

      Column({ space: DesignTokens.space.mini }) {
        Text(this.sendFailureTitle)
          .fontSize(DesignTokens.font.bodyM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.danger_red'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.sendFailureBody.length > 0) {
          Text(this.sendFailureBody)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button(this.sendFailureMulti ? $r('app.string.send_failure_card_action_tasks') :
        $r('app.string.send_failure_card_action_detail'))
        .fontSize(DesignTokens.font.bodyS)
        .height(DesignTokens.size.inlineButton)
        .fontColor($r('app.color.text_on_color'))
        .backgroundColor($r('app.color.accent_blue'))
        .borderRadius(DesignTokens.radius.max)
        .onClick(() => {
          this.openFailureTarget();
        })
        .id('send_failure_action')

      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(DesignTokens.font.iconInline)
        .fontColor([$r('app.color.text_secondary')])
        .responseRegion({
          x: -8,
          y: -8,
          width: 40,
          height: 40
        })
        .onClick(() => {
          this.closeSendFailureCard();
        })
        .id('send_failure_close')
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    // 底色、圆角、描边与阴影由弹窗外壳统一绘制，内容区只负责排版，避免两层边框
    .id('send_failure_card')
  }

  // ── 协议不兼容拦截弹窗（点击时就地说明，不建任务） ──

  private openProtocolBlockedDialog(device: DiscoveredDevice): void {
    let breakpoint: string = this.breakpointSignature();
    // 同一形态下已有弹窗时忽略连点；形态变化后旧实例不可信，作废重开
    if (this.protocolBlockDialogId !== -1) {
      if (this.protocolBlockBreakpoint === breakpoint) {
        return;
      }
      this.discardProtocolBlockedDialog();
    }
    this.protocolBlockDialogId = -2;
    this.protocolBlockBreakpoint = breakpoint;
    this.protocolBlockGeneration = this.protocolBlockGeneration + 1;
    let generation: number = this.protocolBlockGeneration;
    this.protocolBlockedAlias = device.alias;
    // 复用发送链路已有的本地化文案（含设备名与两种处理方式）
    this.protocolBlockedMessage = getStringSync(this.getUIContext(), $r('app.string.protocol_mismatch_error'))
      .replace('%s', device.alias);
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.protocolBlockedDialog();
      },
      onDidDisappear: () => {
        if (generation !== this.protocolBlockGeneration) {
          return;
        }
        this.protocolBlockDialogId = -1;
        this.protocolBlockBreakpoint = '';
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        if (generation !== this.protocolBlockGeneration) {
          this.closeDialogById(id);
          return;
        }
        this.protocolBlockDialogId = id;
      })
      .catch(() => {
        if (generation !== this.protocolBlockGeneration) {
          return;
        }
        this.protocolBlockDialogId = -1;
        this.protocolBlockBreakpoint = '';
      });
  }

  /** 作废旧协议弹窗实例（随后按新形态重开）。 */
  private discardProtocolBlockedDialog(): void {
    this.protocolBlockGeneration = this.protocolBlockGeneration + 1;
    this.closeDialogById(this.protocolBlockDialogId);
    this.protocolBlockDialogId = -1;
  }

  private closeProtocolBlockedDialog(): void {
    this.protocolBlockGeneration = this.protocolBlockGeneration + 1;
    this.closeDialogById(this.protocolBlockDialogId);
    this.protocolBlockDialogId = -1;
    this.protocolBlockBreakpoint = '';
  }

  /**
   * 协议不兼容说明弹窗：只告知原因与两条可行路径，不在本页改动全局加密设置。
   * 关闭加密会重启 LocalSend 服务（中断接收、取消在途校验和），应由用户在设置页自行决定。
   */
  @Builder
  protocolBlockedDialog() {
    AlertDialogV2({
      primaryTitle: getStringSync(this.getUIContext(), $r('app.string.send_protocol_block_title'))
        .replace('%s', this.protocolBlockedAlias),
      content: this.protocolBlockedMessage,
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_confirm'),
        action: () => {
          this.closeProtocolBlockedDialog();
        }
      })
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽
      .constraintSize({ maxWidth: 480 })
      .id('send_protocol_blocked_dialog')
  }

  // MTA 单目标发送：编排（服务生命周期/收发互斥/注册表登记）由 MTA 发送适配器承接，
  // 会话统一经任务与通用详情页呈现，不再跳转 MTA 专用传输页。
  private sendToMtaDevice(device: DiscoveredDevice): void {
    if (this.viewModel.isMtaSendBusy()) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.mta_transfer_busy'), duration: 2000, alignment: Alignment.Center });
      return;
    }
    let params = this.viewModel.buildMtaSendParams(device);
    if (params === undefined) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.mta_transfer_no_content'), duration: 2000, alignment: Alignment.Center });
      return;
    }
    this.beginMtaSend(device, params);
  }

  /**
   * 发起 MTA 发送并给出与局域网一致的反馈：点击当帧确认开始，会话终结为失败时弹浮卡
   * （「自动进入任务详情」开启时改为进入详情页，失败由详情页承载）。
   * 结果只能等会话终态：`startMtaSend` 在建链（写回 P2pInfo）后就返回，
   * 早于对端确认/传输，按发起返回查询会漏掉「对方拒绝」这类终态。
   */
  private beginMtaSend(device: DiscoveredDevice, params: MtaSendRequest): void {
    this.mtaWatchBeforeIds = this.viewModel.mtaSendSessionIds();
    this.mtaAutoOpenSessionId = '';
    this.showSendToast($r('app.string.send_started_toast'), device.alias);
    this.viewModel.startMtaSend(params);
  }

  /** 检查本次 MTA 发起的结局：新会话出现时按设置进入详情，已结算则停止监听，失败时弹浮卡。 */
  private checkMtaSendWatch(): void {
    let beforeIds: Array<string> | undefined = this.mtaWatchBeforeIds;
    if (beforeIds === undefined) {
      return;
    }
    let outcome: MtaSendOutcome = this.viewModel.mtaSendOutcome(beforeIds);
    // 新会话一出现即按设置进入详情（MTA 会话在发送状态事件中才登记，故在变更通知里补跳）；
    // 已自动进入时不再弹失败浮卡，失败原因在详情页可见
    if (outcome.sessionId.length > 0 && this.mtaAutoOpenSessionId.length === 0 &&
      isAutoOpenSessionDetailAfterSend() && !this.isDetached) {
      this.mtaAutoOpenSessionId = outcome.sessionId;
      // 与点击设备路径一致：离开发送页前收起既有失败浮卡，避免旧内容覆盖详情页
      this.closeSendFailureCard();
      this.onOpenSessionDetail(outcome.sessionId);
    }
    if (!outcome.settled) {
      return;
    }
    this.mtaWatchBeforeIds = undefined;
    if (outcome.failure !== undefined && this.mtaAutoOpenSessionId.length === 0 && !this.isDetached) {
      this.showSendFailureCard(outcome.failure);
    }
  }

  // 点击网页图标：进入统一的「网页传输」面板。
  // 已挂载同一份暂存内容时直接进入，避免重复挂载重置本次上传免确认。
  onOpenWebPanel(): void {
    if (!this.viewModel.webSendAllowed || this.viewModel.stagedFiles.length === 0 ||
      this.viewModel.isWebShareMounted()) {
      this.onNavigateTo('ShareLinkPage', undefined);
      return;
    }
    // 挂载分享同样经大文件二次确认门禁（总量达阈值时先弹确认）
    this.runAfterLargeFileConfirm(() => {
      this.viewModel.shareByLink().then((shareUrl: string) => {
        if (shareUrl.length > 0) {
          this.onNavigateTo('ShareLinkPage', undefined);
        }
      });
    });
  }

  // 点击云图标：进入「远程传输」站点导航页。
  onOpenPortalPanel(): void {
    this.onNavigateTo('PortalPage', undefined);
  }

  // 点击"指定IP分享"菜单项：未暂存文件时居中提示，否则弹出IP输入框
  onSendByIp(): void {
    // LocalSend 总开关关闭时不允许按 IP 发送（菜单入口已置灰，此处为防御纵深）
    if (!this.viewModel.localSendEnabled) {
      logger.debug('LocalSend 已禁用，忽略按 IP 发送入口');
      return;
    }
    if (this.viewModel.stagedFiles.length === 0) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_select_file_first'), duration: 2000, alignment: Alignment.Center });
      return;
    }
    this.ipInputValue = '';
    this.ipInputValid = false;
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.ipInputDialog();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
      });
  }

  // ── DialogV2 弹窗：文本发送（B 类 CustomContentDialogV2） ──

  // 新增模式：复位弹窗状态（编辑目标置 -1、输入清空、确认禁用）后打开文本弹窗
  private openTextSendDialog(): void {
    this.textEditTargetIndex = -1;
    this.textSendValue = '';
    this.textSendValid = false;
    this.openTextDialogCommon();
  }

  // 打开文本弹窗（新增/编辑模式共用样板）：B 类 CustomContentDialogV2，id 记录供关闭使用
  private openTextDialogCommon(): void {
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.textSendDialog();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
      });
  }

  // 打开文本编辑弹窗（编辑模式）：读取目标条目当前文本预填输入框后打开弹窗。
  // 条目不存在或非文本消息（普通文件，含 .txt）时直接返回，不进入编辑；
  // 底层文件被系统清理/不可读时按空串预填并继续允许编辑（不崩溃）。
  private openTextEditDialog(index: number): void {
    let staged: StagedFile | undefined = this.viewModel.stagedFiles[index];
    if (staged === undefined || staged.isManualText !== true) {
      return;
    }
    let current: string = '';
    try {
      current = fs.readTextSync(staged.uri);
    } catch (_e) {
      // 文件缺失/不可读（如缓存被系统清理）：按空串预填，不中断编辑
      current = '';
    }
    this.textEditTargetIndex = index;
    this.textSendValue = current;
    this.textSendValid = this.textSendValue.trim().length > 0;
    this.openTextDialogCommon();
  }

  private closeActiveDialog(): void {
    if (this.activeDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.activeDialogId);
      this.activeDialogId = -1;
    }
  }

  @Builder
  textSendDialog() {
    CustomContentDialogV2({
      // 标题按模式切换：编辑模式（textEditTargetIndex >= 0）显示「编辑文本」，新增模式显示「输入文本」
      primaryTitle: this.textEditTargetIndex >= 0 ? $r('app.string.send_text_edit_title') :
        $r('app.string.send_text_input_title'),
      contentBuilder: () => {
        this.textSendContent();
      },
      buttons: [
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_cancel'),
          action: () => {
            this.closeActiveDialog();
          }
        }),
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_confirm'),
          enabled: this.textSendValid,
          action: () => {
            if (this.textEditTargetIndex >= 0) {
              // 编辑模式：写回原暂存文本文件（内容已由 enabled 保证非空白，条目标识与持久化语义不变）
              this.viewModel.updateStagedTextFile(this.textEditTargetIndex, this.textSendValue);
            } else if (this.textSendValid) {
              // 新增模式：暂存新文本条目（既有行为，仅非空白内容暂存）
              this.viewModel.stageTextFile(this.textSendValue, 'text_');
            }
            this.closeActiveDialog();
          }
        })
      ]
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  textSendContent() {
    Column({ space: DesignTokens.space.sm }) {
      TextArea({ text: this.textSendValue })
        .height(120)
        .borderRadius(DesignTokens.radius.md)
        .defaultFocus(true)
        .id('send_text_input')
        .onChange((value: string) => {
          this.textSendValue = value;
          // 联动确认按钮可用性：空白（或仅空白字符）时禁用确认，禁止提交空文本
          this.textSendValid = value.trim().length > 0;
        })
    }
    .width('100%')
  }

  // ── DialogV2 弹窗：IP 输入（B 类 CustomContentDialogV2，确认按钮随有效性联动） ──

  @Builder
  ipInputDialog() {
    CustomContentDialogV2({
      primaryTitle: $r('app.string.send_mode_ip'),
      contentBuilder: () => {
        this.ipInputContent();
      },
      buttons: [
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_cancel'),
          action: () => {
            this.closeActiveDialog();
          }
        }),
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_confirm'),
          enabled: this.ipInputValid,
          action: () => {
            this.sendToSpecifiedIp(this.ipInputValue);
            this.closeActiveDialog();
          }
        })
      ]
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  ipInputContent() {
    Column({ space: DesignTokens.space.sm }) {
      TextInput({ placeholder: $r('app.string.send_mode_ip_placeholder'), text: this.ipInputValue })
        .borderRadius(DesignTokens.radius.max)
        .defaultFocus(true)
        .id('send_ip_input')
        .onChange((value: string) => {
          this.ipInputValue = value;
          this.ipInputValid = isValidIpAddress(value);
        })
    }
    .width('100%')
  }

  // 指定 IP 分享：大文件先二次确认，connectByIp → 成功走单目标发送流程，失败 Toast 提示
  async sendToSpecifiedIp(ip: string): Promise<void> {
    if (!(await this.confirmLargeFileIfNeeded())) {
      return;
    }
    let result: DiscoveredDevice | undefined = await connectByIp(ip, getPort());
    if (result === undefined) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_error_connection'), duration: 2000 });
      return;
    }
    let device: DiscoveredDevice = result;
    // 与点击设备同一套前置判定：加密不兼容时先说明，不产生秒失败任务
    if (this.isProtocolBlocked(device)) {
      this.openProtocolBlockedDialog(device);
      return;
    }
    // 复用「点击设备即发送」的内联反馈（开始确认 + 失败浮卡）
    this.beginInlineSend(device);
  }

  // ── 收藏设备面板 ──

  // 点击「收藏列表」菜单项：刷新面板条目后直接打开半模态面板，不以是否已暂存内容为门禁；
  // 未选择内容时不阻止打开，仅在实际点击设备发起发送阶段拦截并提示。
  onOpenFavorites(): void {
    // LocalSend 总开关关闭时不允许打开收藏面板（入口已置灰，此处为防御纵深）
    if (!this.viewModel.localSendEnabled) {
      logger.debug('LocalSend 已禁用，忽略收藏入口');
      return;
    }
    this.favoritesPanelViewModel.refresh();
    this.isShowFavoritesSheet = true;
  }

  // 收藏条目「设备详情」：bindSheet 不支持路由跳转且模态会遮挡新页面，故先关闭面板再跳转；
  // 参数由面板视图模型构造（可选字段补空串），离线收藏同样可查看已保存信息。
  private onOpenFavoriteDetails(favorite: FavoriteDevice): void {
    this.isShowFavoritesSheet = false;
    this.onNavigateTo('DeviceDetailsPage', this.favoritesPanelViewModel.buildDetailsParams(favorite));
  }

  // 点击收藏条目请求发送：在线直发；离线先按保存地址定向探测（探测中给出行级反馈）。
  // 发送编排下沉到 SendViewModel，返回结果枚举由本视图给出提示。
  private onFavoriteSendRequest(favorite: FavoriteDevice): void {
    // 已有定向探测进行中：忽略重复点击，避免重复发起
    if (this.favoritesPanelViewModel.probingFingerprint.length > 0) {
      return;
    }
    // 离线条目先按保存地址探测，探测期间展示行级进行中反馈
    let isOnline: boolean = false;
    for (let i = 0; i < this.favoritesPanelViewModel.items.length; i++) {
      let item = this.favoritesPanelViewModel.items[i];
      if (item.fingerprint === favorite.fingerprint) {
        isOnline = item.isOnline;
        break;
      }
    }
    if (!isOnline) {
      this.favoritesPanelViewModel.setProbing(favorite.fingerprint);
    }
    // 收藏发送同样经大文件二次确认门禁（总量达阈值时先弹确认）
    this.runAfterLargeFileConfirm(() => {
      let autoEnterDetail: boolean = isAutoOpenSessionDetailAfterSend();
      this.viewModel.sendToFavorite(favorite, (sessionId: string) => {
        if (autoEnterDetail && !this.isDetached) {
          // 面板是模态：先收起面板再跳转，避免详情页被半模态遮挡；旧失败浮卡同样在离开前收起
          this.isShowFavoritesSheet = false;
          this.closeSendFailureCard();
          this.onOpenSessionDetail(sessionId);
        }
      }).then((result: FavoriteSendResult) => {
        this.favoritesPanelViewModel.clearProbing();
        this.showFavoriteSendFeedback(result);
      });
    });
  }

  // 收藏发送结果提示：探测失败明确提示；目标忙/无内容复用既有提示；已发起不提示（面板保持打开）
  private showFavoriteSendFeedback(result: FavoriteSendResult): void {
    if (result === FavoriteSendResult.probeFailed) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.favorites_probe_failed'), duration: 2000, alignment: Alignment.Center });
    } else if (result === FavoriteSendResult.busy) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_device_busy'), duration: 2000, alignment: Alignment.Center });
    } else if (result === FavoriteSendResult.noContent) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_select_file_first'), duration: 2000, alignment: Alignment.Center });
    }
  }

  // 收藏面板内容（bindSheet 宿主为发送页根 Stack）：发送成功后面板保持打开，便于连续发送
  @Builder
  favoritesSheetBuilder() {
    FavoriteDevicesSheet({
      sendViewModel: this.viewModel,
      panelViewModel: this.favoritesPanelViewModel,
      onRequestSend: (favorite: FavoriteDevice) => {
        this.onFavoriteSendRequest(favorite);
      },
      onOpenDetails: (favorite: FavoriteDevice) => {
        this.onOpenFavoriteDetails(favorite);
      }
    })
  }

  build() {
    // 根容器：Stack 包裹既有 Scroll，作为发送页整体拖放目标（allowDrop 声明支持的 UTD 类型），
    // 悬停时叠加高亮遮罩提示；遮罩不拦截触摸（HitTestMode.None），不影响正常滚动与点击
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll(this.scroller) {
        Column() {
          if (this.viewModel.localSendEnabled && !this.viewModel.serverReady) {
            Row({ space: DesignTokens.space.sm }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
                .fontSize(DesignTokens.font.iconInline)
                .fontColor([$r('app.color.warning_orange')])

              Text($r('app.string.server_offline_warning'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.warning_orange'))
                .layoutWeight(1)

              Button($r('app.string.start_server'))
                .fontSize(DesignTokens.font.bodyS)
                .height(DesignTokens.size.inlineButton)
                .fontColor($r('app.color.text_on_color'))
                .backgroundColor($r('app.color.accent_blue'))
                .borderRadius(DesignTokens.radius.max)
                .onClick(() => {
                  this.viewModel.startServer().then(() => {
                  }).catch((_e: Error) => {
                    // 启动失败，保持离线
                  });
                })
                .id('send_server_start_btn')
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.warning_bg'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.warning_orange') })
            .margin({ top: DesignTokens.space.md })
          }

          // 「所有传输方式均已关闭」中性提示卡：全部关闭且无任何可用路径时说明；
          // 仅部分方式关闭时由下方「部分传输方式已关闭」提示卡负责。
          // 主动禁用不是故障，故取中性/信息语义色（非警示橙），并提供「去设置」入口与关闭入口。
          if (shouldShowProtocolDisabledHint(this.viewModel.localSendEnabled, this.viewModel.mtaEnabled,
            this.viewModel.webSendAllowed, this.protocolHintDismissed)) {
            Row({ space: DesignTokens.space.sm }) {
              SymbolGlyph($r('sys.symbol.info_circle'))
                .fontSize(DesignTokens.font.iconInline)
                .fontColor([$r('app.color.accent_blue_text')])

              Text($r('app.string.send_all_protocols_disabled_hint'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)

              Button($r('app.string.send_protocol_hint_settings'))
                .fontSize(DesignTokens.font.bodyS)
                .height(DesignTokens.size.inlineButton)
                .fontColor($r('app.color.text_on_color'))
                .backgroundColor($r('app.color.accent_blue'))
                .borderRadius(DesignTokens.radius.max)
                .onClick(() => {
                  this.onOpenSettings();
                })
                .id('send_protocol_hint_settings_btn')

              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(DesignTokens.font.iconInline)
                .fontColor([$r('app.color.text_secondary')])
                .responseRegion({
                  x: -14,
                  y: -14,
                  width: 48,
                  height: 48
                })
                .onClick(() => {
                  this.onDismissProtocolHint();
                })
                .id('send_protocol_hint_dismiss')
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.accent_blue_bg'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
            .margin({ top: DesignTokens.space.md })
            .alignItems(VerticalAlign.Center)
          }

          // 「部分传输方式已关闭」中性提示卡：同一关闭状态只在状态变化后的首次启动提示一次，
          // 避免对特意关闭某种方式的用户反复打扰；可关闭、本次会话内有效。
          if (this.partialProtocolHintVisible &&
            shouldShowPartialProtocolDisabledHint(this.viewModel.localSendEnabled, this.viewModel.mtaEnabled,
              this.viewModel.webSendAllowed, this.protocolHintDismissed)) {
            Row({ space: DesignTokens.space.sm }) {
              SymbolGlyph($r('sys.symbol.info_circle'))
                .fontSize(DesignTokens.font.iconInline)
                .fontColor([$r('app.color.accent_blue_text')])

              Text(this.partialProtocolHintText())
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)

              Button($r('app.string.send_protocol_hint_settings'))
                .fontSize(DesignTokens.font.bodyS)
                .height(DesignTokens.size.inlineButton)
                .fontColor($r('app.color.text_on_color'))
                .backgroundColor($r('app.color.accent_blue'))
                .borderRadius(DesignTokens.radius.max)
                .onClick(() => {
                  this.onOpenSettings();
                })
                .id('send_partial_protocol_hint_settings_btn')

              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(DesignTokens.font.iconInline)
                .fontColor([$r('app.color.text_secondary')])
                .responseRegion({
                  x: -14,
                  y: -14,
                  width: 48,
                  height: 48
                })
                .onClick(() => {
                  this.onDismissProtocolHint();
                })
                .id('send_partial_protocol_hint_dismiss')
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.accent_blue_bg'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
            .margin({ top: DesignTokens.space.md })
            .alignItems(VerticalAlign.Center)
          }

          // 服务器重启警告横幅（LocalSend 总开关关闭时不显示：服务器已停，重启提示无意义）
          if (this.viewModel.localSendEnabled && this.viewModel.serverNeedsRestart) {
            Row({ space: DesignTokens.space.sm }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
                .fontSize(DesignTokens.font.iconInline)
                .fontColor([$r('app.color.warning_orange')])

              Text($r('app.string.server_needs_restart'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.warning_orange'))
                .layoutWeight(1)

              if (this.isRestarting) {
                LoadingProgress()
                  .width(DesignTokens.font.iconInline)
                  .height(DesignTokens.font.iconInline)
                  .color($r('app.color.accent_blue'))
              }
              Button($r('app.string.restart_server'))
                .fontSize(DesignTokens.font.bodyS)
                .height(DesignTokens.size.inlineButton)
                .fontColor($r('app.color.text_on_color'))
                .backgroundColor($r('app.color.accent_blue'))
                .borderRadius(DesignTokens.radius.max)
                .enabled(!this.isRestarting)
                .onClick(() => {
                  this.isRestarting = true;
                  this.viewModel.restartServer().then(() => {
                    this.isRestarting = false;
                  }).catch(() => {
                    this.isRestarting = false;
                  });
                })
                .id('send_server_restart_btn')
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .borderRadius(DesignTokens.radius.lg)
            .backgroundColor($r('app.color.warning_bg'))
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.warning_orange') })
            .margin({ top: DesignTokens.space.md })
          }

          // 连接警告横幅：网络/蓝牙/互传依赖按优先级只显示一条，避免多条横幅堆叠
          // （未连接局域网与未开启 WLAN 在互传场景下是同一件事，故合并为同一条提示）
          if (this.getConnectionWarningText() !== undefined) {
            Row({ space: DesignTokens.space.sm }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
                .fontSize(DesignTokens.font.iconInline)
                .fontColor([$r('app.color.warning_orange')])
              Text(this.getConnectionWarningText())
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.warning_orange'))
                .layoutWeight(1)
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .borderRadius(DesignTokens.radius.lg)
            .backgroundColor($r('app.color.warning_bg'))
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.warning_orange') })
            .margin({ top: DesignTokens.space.md })
          }

          // 内容区 / 目标区上下纵向排列：内容区有暂存时压缩为摘要，目标区取自然高度，整页纵向滚动
          SendContentZone({
            viewModel: this.viewModel,
            onTextInput: () => {
              this.openTextSendDialog();
            },
            onPaste: () => {
              this.readClipboardAndHandle();
            },
            onEditText: (index: number) => {
              this.openTextEditDialog(index);
            }
          })

          SendTargetZone({
            viewModel: this.viewModel,
            onSend: (device: DiscoveredDevice) => {
              this.sendToSelectedDevice(device);
            },
            onInfo: (device: DiscoveredDevice) => {
              this.onNavigateTo('DeviceDetailsPage', this.deviceNavParam(device));
            },
            onRefresh: () => {
              this.refreshDevices();
            },
            onOpenWeb: () => {
              this.onOpenWebPanel();
            },
            onOpenPortal: () => {
              this.onOpenPortalPanel();
            }
          })
        }
        .width('100%')
        .padding(
          { left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.size.tabBarClearance })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .backgroundColor($r('app.color.page_background'))
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      // 滚动容器不裁剪：滚动中的内容可绘制到标题栏区域内，使毛玻璃背板有内容可透出
      .clip(false)
      // 安全区扩展逐层设置：滚动容器与其到内容根节点之间的各直接节点均需具备，
      // 否则滚动后延伸失效（顶层 Stack 同步配置）
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onDidScroll((_xOffset: number, yOffset: number) => {
        let offset = this.scroller.currentOffset();
        this.onScrollDelta(yOffset, offset.yOffset);
      })
      .onScrollEdge((edge: Edge) => {
        if (edge === Edge.Top) {
          this.onScrollDelta(-999, 0);
        }
      })

      // 拖拽悬停高亮遮罩：半透明遮罩（DesignTokens 色板中的既有遮罩色）+ 居中提示文案
      if (this.isDragOver) {
        Column({ space: DesignTokens.space.sm }) {
          Text($r('app.string.drag_drop_hint'))
            .fontSize(DesignTokens.font.bodyL)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_on_color'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.overlay_mask'))
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    // 内容根节点延伸至系统状态栏与导航条区域：页面背景铺满屏幕，正文保持在安全区内
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .allowDrop([
      uniformTypeDescriptor.UniformDataType.FILE,
      uniformTypeDescriptor.UniformDataType.IMAGE,
      uniformTypeDescriptor.UniformDataType.VIDEO,
      uniformTypeDescriptor.UniformDataType.AUDIO,
      uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
      uniformTypeDescriptor.UniformDataType.HYPERLINK
    ])
    .onDragEnter(() => {
      this.isDragOver = true;
    })
    .onDragLeave(() => {
      this.isDragOver = false;
    })
    .onDrop((event: DragEvent) => {
      this.handleDropContent(event);
    })
    // 收藏设备半模态面板：以发送页根 Stack 为常驻宿主，双向绑定显隐
    .bindSheet($$this.isShowFavoritesSheet, this.favoritesSheetBuilder(), {
      height: SheetSize.MEDIUM,
      width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
      // 宽屏（lg/xl）以居中弹窗呈现，窄屏保持底部弹窗（与手机行为一致）
      preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
      blurStyle: BlurStyle.Regular,
      title: {
        title: $r('app.string.favorite_devices_title')
      },
      showClose: true
    })
  }
}
