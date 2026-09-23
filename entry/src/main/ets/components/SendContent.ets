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
import { DiscoveredDevice, StagedFile } from '../model/Types';
import { SendContentZone } from './send/SendContentZone';
import { SendTargetZone } from './send/SendTargetZone';
import { setTransferMethodDispatcher } from '../service/transfer/DefaultRegistrations';
import { DesignTokens } from '../common/DesignTokens';
import { SendViewModel, SendInitiateResult } from '../viewmodel/SendViewModel';
import { isValidIpAddress } from '../utils/IPValidator';
import { parseDroppedRecords, fetchDroppedUnifiedData, DragDropParseResult } from '../model/DragDropParser';
import { isMtaDevice } from '../model/mta/MtaMainModels';
import { isDemoDevice } from '../service/demo/DemoDevices';
import { DemoScenarioType } from '../service/demo/DemoData';
import { triggerScenario } from '../service/demo/DemoScenarioService';
import { DemoScenarioSheet } from './demo/DemoScenarioSheet';

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
  // 演示场景菜单当前目标设备（仅演示分支存在）：undefined 表示菜单未打开
  @Local demoScenarioDevice: DiscoveredDevice | undefined = undefined
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1

  aboutToAppear(): void {
    this.viewModel.init(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.viewModel.subscribeFavorites();
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
  }

  // 连接警告横幅文案：按优先级取一条（无警告时返回 undefined）。
  // 互传发现依赖蓝牙、互传传输依赖 WLAN（有线局域网不可替代），故 WLAN 关闭时
  // 需区分局域网是否可用：不可用时与「未连接局域网」合并为同一提示，可用时只提示互传；
  // 局域网警告需服务器就绪。互传相关提示受「互传连接提醒」设置控制（关闭时不提示）。
  private getConnectionWarningText(): ResourceStr | undefined {
    if (this.viewModel.mtaConnectionWarnings) {
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
    if (this.viewModel.noWifiWarning && this.viewModel.serverReady) {
      return $r('app.string.no_wifi_warning');
    }
    if (this.viewModel.allInterfacesDisabled && this.viewModel.serverReady) {
      return $r('app.string.all_interfaces_disabled_warning');
    }
    if (this.viewModel.mtaConnectionWarnings && !this.viewModel.mtaBluetoothOn) {
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

  // 拖入文件类内容的可靠性提示（FR-012）：移动端会话首次拖入文件类内容时弹出。
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
    // 演示虚拟设备（仅演示分支存在）：不参与真实发送，弹出场景菜单选择模拟场景；
    // 拦截先于暂存内容检查（发送场景使用内置演示文件清单，无需用户暂存内容）
    if (isDemoDevice(device.fingerprint)) {
      this.openDemoScenarioDialog(device);
      return;
    }
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
    let navParam: Record<string, Object> = { 'mode': 'receive' };
    this.onNavigateTo('ShareLinkPage', navParam);
  }

  // 点击"指定IP分享"菜单项：未暂存文件时居中提示，否则弹出IP输入框
  onSendByIp(): void {
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

  // ── 演示场景菜单（仅演示分支存在）：B 类 CustomContentDialogV2，样板同文本弹窗 ──

  // 打开演示场景菜单：记录目标设备供弹窗展示昵称，场景触发后由菜单回调关闭
  private openDemoScenarioDialog(device: DiscoveredDevice): void {
    this.demoScenarioDevice = device;
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.demoScenarioDialog();
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

  // 关闭场景菜单并清理目标设备状态（选中/取消共用）
  private closeDemoScenarioDialog(): void {
    this.closeActiveDialog();
    this.demoScenarioDevice = undefined;
  }

  @Builder
  demoScenarioDialog() {
    if (this.demoScenarioDevice !== undefined) {
      DemoScenarioSheet({
        device: this.demoScenarioDevice,
        onScenario: (type: DemoScenarioType) => {
          let target = this.demoScenarioDevice;
          this.closeDemoScenarioDialog();
          if (target !== undefined) {
            triggerScenario(target, type);
          }
        },
        // 语言经 setLocale 持久化后冷启动生效，此处仅关闭菜单（重启应用后按新语言截图）
        onLanguage: () => {
          this.closeDemoScenarioDialog();
        },
        onCancel: () => {
          this.closeDemoScenarioDialog();
        }
      })
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

  // 内容选择按钮 GridItem（文件/文档/文本/图片/视频/音频/压缩包共用形态；粘贴为安全控件特例，不在此列）
  // 设备多列栅格（附近/收藏列表共用）：GridRow 按窗口宽度断点切换列数（sm/md 单列、lg 2 列、xl 3 列），
  // 高度由内容撑起，可嵌套在页面 Scroll 内（Grid 组件不自适应高度，故不使用 Grid+columnsTemplate）。
  // isFavorite 为固定字面量（非状态），数据源在体内按 @Trace 依赖求值，刷新行为与内联写法一致
  build() {
    // 根容器：Stack 包裹既有 Scroll，作为发送页整体拖放目标（allowDrop 声明支持的 UTD 类型），
    // 悬停时叠加高亮遮罩提示；遮罩不拦截触摸（HitTestMode.None），不影响正常滚动与点击
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll(this.scroller) {
        Column() {
          if (!this.viewModel.serverReady) {
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

          // 服务器重启警告横幅
          if (this.viewModel.serverNeedsRestart) {
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
  }
}
