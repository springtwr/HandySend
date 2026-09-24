import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { unifiedDataChannel, uniformTypeDescriptor } from '@kit.ArkData';
import {
  curves,
  CustomContentDialogV2,
  AlertDialogV2,
  AdvancedDialogV2Button,
  promptAction
} from '@kit.ArkUI';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import {
  subscribe, unsubscribe, connectByIp, getPort
} from '../service/AppService';
import { DiscoveredDevice, StagedFile, FavoriteDevice } from '../model/Types';
import { SendContentZone } from './send/SendContentZone';
import { SendTargetZone } from './send/SendTargetZone';
import { setTransferMethodDispatcher } from '../service/transfer/DefaultRegistrations';
import { DesignTokens } from '../common/DesignTokens';
import { SendViewModel, SendInitiateResult, FavoriteSendResult, shouldShowProtocolDisabledHint } from '../viewmodel/SendViewModel';
import { FavoriteDevicesViewModel } from '../viewmodel/FavoriteDevicesViewModel';
import { FavoriteDevicesSheet } from '../views/FavoriteDevicesSheet';
import { isValidIpAddress } from '../utils/IPValidator';
import { parseDroppedRecords, fetchDroppedUnifiedData, DragDropParseResult } from '../model/DragDropParser';
import { isMtaDevice } from '../model/mta/MtaMainModels';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendContent', '发送内容');

@ComponentV2
export struct SendContent {
  @Local viewModel: SendViewModel = new SendViewModel();
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
  // 「两个协议均禁用」提示卡的关闭状态：由页面宿主持有并下传（跨 TabContent 重建保持，不持久化）
  @Param protocolHintDismissed: boolean = false
  // 关闭该提示（本次会话内不再显示）
  @Event onDismissProtocolHint: () => void = () => {
  }
  // 跳转设置页（仅切换页签，不直接改动开关）
  @Event onOpenSettings: () => void = () => {
  }
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
  // 收藏设备面板（半模态）显隐与面板状态
  @Local isShowFavoritesSheet: boolean = false
  @Local favoritesPanelViewModel: FavoriteDevicesViewModel = new FavoriteDevicesViewModel()

  // 发现快照刷新时更新面板在线状态（面板打开期间设备上线/离线实时反映）
  @Monitor('viewModel.discoveredDevices')
  onDiscoveredDevicesChange(): void {
    this.favoritesPanelViewModel.refreshOnlineStatus();
  }

  aboutToAppear(): void {
    this.viewModel.init(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.viewModel.subscribeFavorites();
    // 收藏面板：绑定在线快照来源并订阅收藏变更（新增/重命名/删除面板实时同步）
    this.favoritesPanelViewModel.attach(this.viewModel);
    this.favoritesPanelViewModel.subscribeFavorites();
    this.refreshCallback = () => {
      this.viewModel.refresh();
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
    if (key === 'web-send') {
      this.onShareByLink();
    } else if (key === 'web-receive') {
      this.onStartWebReceive();
    } else if (key === 'by-ip') {
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
    unsubscribe(this.refreshCallback);
    this.viewModel.unsubscribeFavorites();
    this.favoritesPanelViewModel.unsubscribeFavorites();
  }

  // 连接警告横幅文案：按优先级取一条（无警告时返回 undefined）。
  // 互传发现依赖蓝牙、互传传输依赖 WLAN（有线局域网不可替代），故 WLAN 关闭时
  // 需区分局域网是否可用：不可用时与「未连接局域网」合并为同一提示，可用时只提示互传；
  // 局域网警告需服务器就绪。互传相关提示受「互传连接提醒」设置控制（关闭时不提示）。
  // 协议总开关关闭的类别不再提示（主动禁用不是故障，改由中性禁用提示行说明）。
  private getConnectionWarningText(): ResourceStr | undefined {
    if (this.viewModel.mtaEnabled && this.viewModel.mtaConnectionWarnings) {
      if (!this.viewModel.mtaWifiOn && this.viewModel.noWifiWarning) {
        return $r('app.string.mta_wifi_off_warning');
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
      logger.error('handlePasteData error: ' + JSON.stringify(e));
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
        logger.warn('drop rejected: failed to fetch UDMF data');
        return;
      }
      let records: Array<unifiedDataChannel.UnifiedRecord> = data.getRecords();
      // 来源类型诊断：输出每条记录的 UTD 类型，便于确认中转站等来源实际拖出的数据类型
      // （如拖出图片是 general.image 还是 general.file）
      let types: Array<string> = [];
      for (let i = 0; i < records.length; i++) {
        types.push(records[i].getType());
      }
      logger.info('drop records: count=' + records.length + ' types=' + types.join(','));
      let result: DragDropParseResult = parseDroppedRecords(records);
      let added: boolean = this.viewModel.applyDroppedContent(result);
      // 整批均无任何可处理内容（不支持类型）才算失败；重复内容已走暂存去重、语义上仍是已接受
      let unsupported: boolean = result.uris.length === 0 && result.texts.length === 0;
      this.isDragOver = false;
      event.setResult(unsupported ? DragResult.DRAG_FAILED : DragResult.DRAG_SUCCESSFUL);
      logger.info('drop handled: uris=' + result.uris.length + ' texts=' + result.texts.length +
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
      logger.error('Paste error: ' + JSON.stringify(e));
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.clipboard_read_failed'), duration: 2000 });
    }
  }

  // 刷新旋转使用 springMotion
  refreshDevices(): void {
    // 扫描中不累加旋转角度（刷新旋转由 LoadingProgress 呈现）
    if (!this.viewModel.isScanning) {
      this.getUIContext()
        .animateTo({
          duration: 800,
          curve: curves.springMotion(DesignTokens.animation.springStiffness, DesignTokens.animation.springDamping)
        }, () => {
          this.viewModel.refreshAngle = this.viewModel.refreshAngle + 360;
        });
    }
    // 点击始终触发刷新：扫描进行中会合并排队（最多补扫一次）
    if (this.viewModel.serverReady) {
      this.viewModel.rescanDevices();
    }
    // MTA 发现扫描与 LocalSend 发现同一触发时机（不依赖 LocalSend 服务器就绪）
    this.viewModel.rescanMtaDevices();
  }

  sendToSelectedDevice(device: DiscoveredDevice): void {
    // 未暂存内容时提示并中断发送（点击设备即发送的统一拦截）
    if (this.viewModel.stagedFiles.length === 0) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_select_file_first'), duration: 2000, alignment: Alignment.Center });
      return;
    }
    // MTA（互传联盟）设备：走 MTA 发送编排（会话仍统一登记到注册表）
    if (isMtaDevice(device)) {
      this.sendToMtaDevice(device);
      return;
    }
    // 点击设备即发送：统一走内联发送（无单/多目标模式差异，停留发送页）
    this.viewModel.sendToMultipleDeviceInline(device).then((result: SendInitiateResult) => {
      this.showSendInitiateFeedback(result);
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
    this.viewModel.startMtaSend(params);
  }

  // 点击"用网页分享"菜单项：未暂存文件时居中提示，否则创建分享链接
  onShareByLink(): void {
    // LocalSend 总开关关闭时不创建分享链接（菜单入口已置灰，此处为防御纵深）
    if (!this.viewModel.localSendEnabled) {
      logger.warn('LocalSend 已禁用，忽略网页分享入口');
      return;
    }
    if (this.viewModel.stagedFiles.length === 0) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_select_file_first'), duration: 2000, alignment: Alignment.Center });
      return;
    }
    this.viewModel.shareByLink().then((shareUrl: string) => {
      if (shareUrl.length > 0) {
        let navParam: Record<string, Object> = { 'shareUrl': shareUrl };
        this.onNavigateTo('ShareLinkPage', navParam);
      }
    });
  }

  // 点击「网页接收」菜单项：进入网页接收模式（浏览器上传通道）
  onStartWebReceive(): void {
    // LocalSend 总开关关闭时不进入网页接收页（菜单入口已置灰，此处为防御纵深）
    if (!this.viewModel.localSendEnabled) {
      logger.warn('LocalSend 已禁用，忽略网页接收入口');
      return;
    }
    let navParam: Record<string, Object> = { 'mode': 'receive' };
    this.onNavigateTo('ShareLinkPage', navParam);
  }

  // 点击"指定IP分享"菜单项：未暂存文件时居中提示，否则弹出IP输入框
  onSendByIp(): void {
    // LocalSend 总开关关闭时不允许按 IP 发送（菜单入口已置灰，此处为防御纵深）
    if (!this.viewModel.localSendEnabled) {
      logger.warn('LocalSend 已禁用，忽略按 IP 发送入口');
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

  // 指定 IP 分享：connectByIp → 成功走单目标发送流程，失败 Toast 提示
  async sendToSpecifiedIp(ip: string): Promise<void> {
    let result: DiscoveredDevice | undefined = await connectByIp(ip, getPort());
    if (result === undefined) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_error_connection'), duration: 2000 });
      return;
    }
    let device: DiscoveredDevice = result;
    // 复用「点击设备即发送」的内联流程，并据返回结果给出可见反馈
    let outcome: SendInitiateResult = await this.viewModel.sendToMultipleDeviceInline(device);
    this.showSendInitiateFeedback(outcome);
  }

  // ── 收藏设备面板 ──

  // 点击「收藏列表」菜单项：刷新面板条目后直接打开半模态面板，不以是否已暂存内容为门禁；
  // 未选择内容时不阻止打开，仅在实际点击设备发起发送阶段拦截并提示。
  onOpenFavorites(): void {
    // LocalSend 总开关关闭时不允许打开收藏面板（入口已置灰，此处为防御纵深）
    if (!this.viewModel.localSendEnabled) {
      logger.warn('LocalSend 已禁用，忽略收藏入口');
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
    this.viewModel.sendToFavorite(favorite).then((result: FavoriteSendResult) => {
      this.favoritesPanelViewModel.clearProbing();
      this.showFavoriteSendFeedback(result);
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
            Row() {
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

          // 「两个协议均禁用」中性提示卡：单一协议禁用不提示，仅当已无任何可用路径时才说明。
          // 主动禁用不是故障，故取中性/信息语义色（非警示橙），并提供「去设置」入口与关闭入口。
          if (shouldShowProtocolDisabledHint(this.viewModel.localSendEnabled, this.viewModel.mtaEnabled,
            this.protocolHintDismissed)) {
            Row({ space: DesignTokens.space.sm }) {
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

          // 服务器重启警告横幅（LocalSend 总开关关闭时不显示：服务器已停，重启提示无意义）
          if (this.viewModel.localSendEnabled && this.viewModel.serverNeedsRestart) {
            Row() {
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
            Row({ space: DesignTokens.space.tiny }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
                .fontSize(DesignTokens.font.bodyM)
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
      preferType: SheetType.BOTTOM,
      blurStyle: BlurStyle.Regular,
      title: {
        title: $r('app.string.favorite_devices_title')
      },
      showClose: true
    })
  }
}
