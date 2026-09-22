import {
  DesignTokens
} from '../../common/DesignTokens';
import {
  getSheetWidth, isWideWidth
} from '../../common/Breakpoints';
import {
  SettingsViewModel
} from '../../viewmodel/SettingsViewModel';
import {
  NetworkInterface, NetworkType
} from '../../viewmodel/SettingsViewModel';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { networkTypeLabel } from '../../utils/NetworkPresentation';
import { networkSettingsViewModel } from '../../viewmodel/NetworkSettingsViewModel';
import { DEFAULT_PORT, DEFAULT_MULTICAST_GROUP } from '../../model/SettingsDefaults';
import { ReceiveSettingsSection } from './ReceiveSettingsSection';
import { SendSettingsSection } from './SendSettingsSection';
import { AlertDialogV2, CustomContentDialogV2, AdvancedDialogV2Button, promptAction, uiObserver } from '@kit.ArkUI';

const logger = getLogger(LogDomains.NETWORK, 'HandySend:NetworkSettings', '网络设置');

// LocalSend 协议设置分组（单卡片）：服务器状态 → 自动确认请求 → 接收 PIN 码 →
// 自动确认下载请求 → 高级设置（加密传输/端口/创建校验和/组播组/发现超时/网络接口）。
// 接口排序/比较、白名单编辑、脏状态检测等业务逻辑已下沉至 networkSettingsViewModel。
@ComponentV2
export struct NetworkSettingsSection {
  // 系统宽度断点（随窗口尺寸变化自动刷新，半屏弹窗宽度断点化用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Require @Param viewModel: SettingsViewModel
  @Local isRestarting: boolean = false
  @Local isShowNetworkInterfaceSheet: boolean = false
  @Local localWhitelist: Array<string> = []
  @Local localBlacklist: Array<string> = []
  @Local localInterfaces: Array<NetworkInterface> = []
  // 高级设置展开状态（可展开列表：点击标题行展开/收起）
  @Local isAdvancedExpanded: boolean = false
  // 通用输入弹窗（B 类 CustomContentDialogV2）状态
  @Local inputDialogTitle: string = ''
  @Local inputDialogValue: string = ''
  // 通用输入确认回调（打开时暂存，确认时执行）
  private inputDialogCallback: (value: string) => void = (_value: string) => {
  }
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1

  // 监听接口列表版本变化，弹窗开着时自动刷新。
  // 仅在接口数据实际变化时刷新，避免 notifyChange 触发的 interfaceListVersion 递增
  // （可能源于设备发现、传输进度等与接口无关的变化）导致无意义重刷。
  @Monitor('viewModel.interfaceListVersion')
  onInterfaceListVersionChange(): void {
    if (this.isShowNetworkInterfaceSheet) {
      let currentInterfaces = networkSettingsViewModel.sortInterfaces(this.viewModel.getLocalInterfacesList());
      if (!this.interfacesEqual(this.localInterfaces, currentInterfaces)) {
        this.applySheetInterfaces(currentInterfaces);
      }
    }
  }

  // 比较两组接口是否相同（按排序后顺序逐项比较 name+ip+type+isDefault）
  private interfacesEqual(a: Array<NetworkInterface>, b: Array<NetworkInterface>): boolean {
    return networkSettingsViewModel.interfacesEqual(a, b);
  }

  // 刷新弹窗中的接口列表：重新枚举接口 + 处理新接口默认 Toggle 状态。
  // 注意：不清理消失接口——保留在白/黑名单中，接口回来时自动恢复状态；
  // hasUnsavedChanges 的 activeListsEqual 只比较活跃接口，不会因消失接口误报。
  private refreshSheetInterfaces(): void {
    // 重新枚举接口（VPN/隧道接口变化不触发系统网络事件，
    // 需要用户点击刷新按钮才能捕获）。
    this.viewModel.refreshLocalInterfaces();
    let newInterfaces = networkSettingsViewModel.sortInterfaces(this.viewModel.getLocalInterfacesList());
    this.applySheetInterfaces(newInterfaces);
  }

  // 将排序后的接口列表应用到弹窗状态，处理新接口的默认 Toggle 分配
  private applySheetInterfaces(newInterfaces: Array<NetworkInterface>): void {
    logger.debug('刷新后接口: [' +
      newInterfaces.map((i: NetworkInterface) => i.name + '(' + i.ip + ')').join(', ') + ']');

    // 收集当前白/黑名单中已有的接口名
    let knownNames: Set<string> = new Set();
    for (let i = 0; i < this.localWhitelist.length; i++) {
      knownNames.add(this.localWhitelist[i]);
    }
    for (let i = 0; i < this.localBlacklist.length; i++) {
      knownNames.add(this.localBlacklist[i]);
    }

    // 检查新接口中是否有未见过的接口名，按默认规则添加
    let addedCount = 0;
    for (let i = 0; i < newInterfaces.length; i++) {
      let name = newInterfaces[i].name;
      if (name.length > 0 && !knownNames.has(name)) {
        if (newInterfaces[i].type === NetworkType.wifi || newInterfaces[i].type === NetworkType.ethernet) {
          this.localWhitelist.push(name);
        } else {
          this.localBlacklist.push(name);
        }
        knownNames.add(name);
        addedCount++;
      }
    }
    if (addedCount > 0) {
      logger.debug('新增 ' + addedCount + ' 个接口（按默认规则分配）');
    }
    this.localInterfaces = newInterfaces;
    logger.debug(
      '最终白名单: [' + this.localWhitelist.join(', ') + '] 黑名单: [' + this.localBlacklist.join(', ') +
        ']');
  }

  private showEncryptionNotice(): void {
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.encryptionNoticeDialog();
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

  // ── DialogV2 弹窗：加密传输关闭确认（A 类 AlertDialogV2） ──

  @Builder
  encryptionNoticeDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.encryption_notice_title'),
      content: $r('app.string.encryption_notice_message'),
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_cancel'),
        action: () => {
          this.closeActiveDialog();
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_confirm'),
        action: () => {
          this.viewModel.setEncryptionEnabled(false);
          this.closeActiveDialog();
        }
      })
    })
  }

  // ── DialogV2 弹窗：通用输入（B 类 CustomContentDialogV2） ──

  private openInputDialog(title: ResourceStr, defaultValue: string, callback: (value: string) => void): void {
    // 将 Resource 标题解析为字符串（CustomContentDialogV2 primaryTitle 支持 ResourceStr，直接透传）
    this.inputDialogTitle = typeof title === 'string' ? title : this.resolveTitleString(title);
    this.inputDialogValue = defaultValue;
    this.inputDialogCallback = callback;
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.inputDialog();
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

  private resolveTitleString(res: Resource): string {
    let ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return '';
    }
    try {
      return ctx.resourceManager.getStringSync(res.id);
    } catch (_e) {
      return '';
    }
  }

  private closeActiveDialog(): void {
    if (this.activeDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.activeDialogId);
      this.activeDialogId = -1;
    }
  }

  @Builder
  inputDialog() {
    CustomContentDialogV2({
      primaryTitle: this.inputDialogTitle,
      contentBuilder: () => {
        this.inputDialogContent();
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
          action: () => {
            this.inputDialogCallback(this.inputDialogValue);
            this.closeActiveDialog();
          }
        })
      ]
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  inputDialogContent() {
    Column({ space: DesignTokens.space.sm }) {
      TextInput({ text: this.inputDialogValue })
        .borderRadius(DesignTokens.radius.max)
        .id('settings_input_dialog_input')
        .onChange((value: string) => {
          this.inputDialogValue = value;
        })
    }
    .width('100%')
  }

  // 运行异步服务器操作，附带至少 800ms 的加载动画
  private runServerAction(action: () => Promise<string | void>): void {
    this.isRestarting = true;
    let startTime = Date.now();
    action().then(() => {
      let remaining = 800 - (Date.now() - startTime);
      if (remaining > 0) {
        setTimeout(() => {
          this.isRestarting = false;
        }, remaining);
      } else {
        this.isRestarting = false;
      }
    }).catch(() => {
      this.isRestarting = false;
    });
  }

  // 解析逗号分隔文本为字符串数组
  private parseList(text: string): Array<string> {
    return networkSettingsViewModel.parseList(text);
  }

  // 检查弹窗内容是否有未保存的修改（业务逻辑在 NetworkSettingsViewModel）
  private hasUnsavedChanges(): boolean {
    return networkSettingsViewModel.hasUnsavedChanges(this.viewModel.networkWhitelist,
      this.viewModel.networkBlacklist, this.localWhitelist, this.localBlacklist, this.localInterfaces);
  }

  // 判断接口是否在白名单中（黑名单优先：接口同时在黑名单中视为不在白名单）
  private isInterfaceWhitelisted(name: string): boolean {
    return networkSettingsViewModel.isInterfaceWhitelisted(name, this.localWhitelist, this.localBlacklist);
  }

  // 判断接口是否在黑名单中
  private isInterfaceBlacklisted(name: string): boolean {
    return networkSettingsViewModel.isInterfaceBlacklisted(name, this.localBlacklist);
  }

  // 从数组中移除指定元素
  private removeFromList(list: Array<string>, item: string): Array<string> {
    return networkSettingsViewModel.removeFromList(list, item);
  }

  // 根据 NetworkType 获取对应的 SymbolGlyph 资源名
  private getNetworkTypeSymbol(type: NetworkType): Resource {
    if (type === NetworkType.wifi) {
      return $r('sys.symbol.wifi');
    } else if (type === NetworkType.cellular) {
      return $r('sys.symbol.signal');
    } else if (type === NetworkType.unknown) {
      return $r('sys.symbol.questionmark_circle_fill');
    } else {
      // 以太网使用通用设备图标
      return $r('sys.symbol.computer_fill');
    }
  }

  // 判断接口列表是否为空（无接口或仅有 0.0.0.0）
  private isInterfaceListEmpty(): boolean {
    return networkSettingsViewModel.isInterfaceListEmpty(this.localInterfaces);
  }

  // 网络接口半屏弹窗：接口列表卡片 + Toggle 开关 + 保存按钮
  @Builder
  networkInterfaceSheetBuilder(): void {
    Column() {
      // 接口列表卡片
      if (this.isInterfaceListEmpty()) {
        // 空状态
        Column() {
          Text($r('app.string.network_interface_empty'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
            .padding({
              left: DesignTokens.space.lg,
              right: DesignTokens.space.lg,
              top: DesignTokens.space.md,
              bottom: DesignTokens.space.md
            })
        }
        .width('100%')
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(DesignTokens.radius.lg)
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      } else {
        Column() {
          ForEach(this.localInterfaces, (netIf: NetworkInterface, index: number) => {
            Column() {
              Row({ space: DesignTokens.space.sm }) {
                // 网络类型图标
                SymbolGlyph(this.getNetworkTypeSymbol(netIf.type))
                  .fontSize(DesignTokens.size.iconSm)
                  .fontColor([$r('app.color.text_primary')])

                // 接口名 + IP 地址 + 网络类型标签
                Column({ space: 2 }) {
                  Text(netIf.name.length > 0 ? netIf.name : netIf.ip)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor($r('app.color.text_primary'))
                    .fontWeight(FontWeight.Medium)

                  if (netIf.name.length > 0) {
                    Text(netIf.ip)
                      .fontSize(DesignTokens.font.captionM)
                      .fontColor($r('app.color.text_secondary'))
                  }

                  Row({ space: DesignTokens.space.xxs }) {
                    Text(networkTypeLabel(netIf.type))
                      .fontSize(DesignTokens.font.captionM)
                      .fontColor($r('app.color.text_tertiary'))

                    if (netIf.isDefault) {
                      Text($r('app.string.network_default_indicator'))
                        .fontSize(DesignTokens.font.captionM)
                        .fontColor($r('app.color.accent_blue'))
                    }
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                // Toggle 开关：开=白名单（允许扫描），关=黑名单（不扫描）
                // 每个接口独立控制
                Toggle({ type: ToggleType.Switch, isOn: this.isInterfaceWhitelisted(netIf.name) })
                  .onChange((isOn: boolean) => {
                    let name = netIf.name;
                    logger.debug(name + ': ' + (isOn ? '白名单' : '黑名单'));
                    if (isOn) {
                      // 打开：从黑名单移到白名单
                      this.localBlacklist = this.removeFromList(this.localBlacklist, name);
                      if (!this.isInterfaceWhitelisted(name)) {
                        this.localWhitelist.push(name);
                      }
                    } else {
                      // 关闭：从白名单移到黑名单
                      this.localWhitelist = this.removeFromList(this.localWhitelist, name);
                      if (!this.isInterfaceBlacklisted(name)) {
                        this.localBlacklist.push(name);
                      }
                    }
                    logger.debug('白名单: [' + this.localWhitelist.join(', ') + '] 黑名单: [' +
                      this.localBlacklist.join(', ') + ']');
                  })
                  .id('settings_interface_toggle')
              }
              .width('100%')
              .padding({
                left: DesignTokens.space.lg,
                right: DesignTokens.space.lg,
                top: DesignTokens.space.md,
                bottom: DesignTokens.space.md
              })
              .constraintSize({ minHeight: DesignTokens.size.thumbSm })
              .alignItems(VerticalAlign.Center)

              if (index < this.localInterfaces.length - 1) {
                Divider().color($r('app.color.border_light'))
              }
            }
            .width('100%')
          }, (netIf: NetworkInterface) => netIf.ip + netIf.name)
        }
        .width('100%')
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(DesignTokens.radius.lg)
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      }

      // 刷新按钮（次要操作，与卡片风格一致）
      Button($r('app.string.refresh'))
        .width('100%')
        .height(DesignTokens.size.thumbSm)
        .type(ButtonType.Normal)
        .backgroundColor($r('app.color.card_background'))
        .fontColor($r('app.color.accent_blue_text'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.md })
        .onClick(() => {
          logger.debug('手动刷新接口列表');
          this.refreshSheetInterfaces();
        })
        .id('settings_interface_refresh_btn')

      // 保存按钮
      Button($r('app.string.save'))
        .width('100%')
        .height(DesignTokens.size.thumbSm)
        .type(ButtonType.Normal)
        .backgroundColor($r('app.color.accent_blue'))
        .fontColor($r('app.color.text_on_color'))
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.md })
        .onClick(() => {
          // 白名单/黑名单存储接口名（如 wlan0,eth0），而非精确 IP
          // 保存后自动重启 discovery，无需手动重启服务器
          logger.debug(
            '白名单: [' + this.localWhitelist.join(', ') + '] 黑名单: [' + this.localBlacklist.join(', ') + ']');
          this.viewModel.saveNetworkListsAndApply(this.localWhitelist.join(','), this.localBlacklist.join(','));
          this.isShowNetworkInterfaceSheet = false;
        })
        .id('settings_interface_save_btn')
    }
    .width('100%')
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
  }

  build() {
    Column() {
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
            .height(28)
            .fontColor($r('app.color.text_on_color'))
            .backgroundColor($r('app.color.accent_blue'))
            .borderRadius(DesignTokens.radius.max)
            .enabled(!this.isRestarting)
            .onClick(() => {
              this.runServerAction(() => this.viewModel.restartServer());
            })
            .id('settings_server_restart_banner_btn')
        }
        .width('100%')
        .padding(DesignTokens.space.md)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.warning_bg'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.warning_orange') })
        .margin({ top: DesignTokens.space.md })
      }

      // 网络警告横幅（服务器运行中时显示）
      // 没有网络连接优先级高于接口关闭
      if (this.viewModel.noWifiWarning && this.viewModel.serverReady) {
        Row({ space: DesignTokens.space.tiny }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor([$r('app.color.warning_orange')])
          Text($r('app.string.no_wifi_warning'))
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
      } else if (this.viewModel.allInterfacesDisabled && this.viewModel.serverReady) {
        Row({ space: DesignTokens.space.tiny }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor([$r('app.color.warning_orange')])
          Text($r('app.string.all_interfaces_disabled_warning'))
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

      // 卡片（标题由设置分组统一渲染）
      Column() {
        // 服务器状态（顶层第一项）
        Row() {
          if (this.isRestarting) {
            LoadingProgress()
              .width(DesignTokens.size.iconXs)
              .height(DesignTokens.size.iconXs)
              .color($r('app.color.text_secondary'))
              .margin({ right: DesignTokens.space.tiny })
          }
          Text(this.viewModel.serverReady ? $r('app.string.server_status_running') :
            $r('app.string.server_status_offline'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor(this.viewModel.serverReady ? $r('app.color.success_green') : $r('app.color.text_secondary'))
            .layoutWeight(1)
            .id('settings_server_status')

          Row({ space: DesignTokens.space.tiny }) {
            if (!this.viewModel.serverReady) {
              Button($r('app.string.start_server'))
                .fontSize(DesignTokens.font.bodyS)
                .height(DesignTokens.size.inlineButton)
                .fontColor($r('app.color.text_on_color'))
                .backgroundColor($r('app.color.accent_blue'))
                .borderRadius(DesignTokens.radius.max)
                .enabled(!this.isRestarting)
                .onClick(() => {
                  this.runServerAction(() => this.viewModel.startServer());
                })
                .id('settings_server_start_btn')
            } else {
              Button($r('app.string.restart_server'))
                .fontSize(DesignTokens.font.bodyS)
                .height(DesignTokens.size.inlineButton)
                .fontColor($r('app.color.text_on_color'))
                .backgroundColor($r('app.color.accent_blue'))
                .borderRadius(DesignTokens.radius.max)
                .enabled(!this.isRestarting)
                .onClick(() => {
                  this.runServerAction(() => this.viewModel.restartServer());
                })
                .id('settings_server_restart_btn')
              Button($r('app.string.stop_server'))
                .fontSize(DesignTokens.font.bodyS)
                .height(DesignTokens.size.inlineButton)
                .fontColor($r('app.color.text_on_color'))
                .backgroundColor($r('app.color.danger_red'))
                .borderRadius(DesignTokens.radius.max)
                .enabled(!this.isRestarting)
                .onClick(() => {
                  this.runServerAction(() => this.viewModel.stopServer());
                })
                .id('settings_server_stop_btn')
            }
          }
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        // 请求确认（自动确认请求三选一 + 接收 PIN 码）
        ReceiveSettingsSection({ viewModel: this.viewModel })

        // 下载请求（自动确认下载请求）
        SendSettingsSection({ viewModel: this.viewModel })

        // 高级设置（可展开列表：点击标题行展开/收起）
        Row() {
          Text($r('app.string.advanced_settings_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          SymbolGlyph(this.isAdvancedExpanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.titleS)
            .fontColor([$r('app.color.text_tertiary')])
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
            this.isAdvancedExpanded = !this.isAdvancedExpanded;
          });
        })
        .id('settings_advanced_entry')

        // 高级设置项（展开时显示）
        if (this.isAdvancedExpanded) {
          // 加密传输（高级设置首项，关闭时保留确认弹窗）
          Row() {
            Text($r('app.string.encrypted_transfer'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.viewModel.encryptedTransfer })
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            if (this.viewModel.encryptedTransfer) {
              // 当前开启：关闭前显示确认
              this.showEncryptionNotice();
            } else {
              // 当前关闭：直接打开
              this.viewModel.setEncryptionEnabled(true);
            }
          })
          .id('settings_encryption_entry')

          Text($r('app.string.encrypted_transfer_desc'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .alignSelf(ItemAlign.Start)
            .margin({ bottom: DesignTokens.space.tiny })

          // 端口
          Row() {
            Text($r('app.string.port_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Text(this.viewModel.port.toString())
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openInputDialog($r('app.string.port_label'), this.viewModel.port.toString(), (value: string) => {
              this.viewModel.setPortValue(value);
            });
          })
          .id('settings_port_entry')

          if (this.viewModel.port !== DEFAULT_PORT) {
            Text($r('app.string.port_warning'))
              .fontSize(DesignTokens.font.captionM)
              .fontColor($r('app.color.warning_orange'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: DesignTokens.space.tiny })
          }

          // 创建校验和（发送前计算 SHA-256，创建与校验联动，单一开关）
          Row() {
            Text($r('app.string.create_checksums_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.viewModel.createChecksums })
              .onChange((isOn: boolean) => {
                this.viewModel.setChecksumsEnabled(isOn);
              })
              .id('settings_checksums_toggle')
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)

          Text($r('app.string.checksum_create_desc'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .alignSelf(ItemAlign.Start)
            .margin({ bottom: DesignTokens.space.tiny })

          // 组播组
          Row() {
            Text($r('app.string.multicast_group_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Text(this.viewModel.multicastGroup)
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openInputDialog($r('app.string.multicast_group_label'), this.viewModel.multicastGroup,
              (value: string) => {
                this.viewModel.setMulticastGroupValue(value);
              });
          })
          .id('settings_multicast_entry')

          if (this.viewModel.multicastGroup !== DEFAULT_MULTICAST_GROUP) {
            Text($r('app.string.multicast_warning'))
              .fontSize(DesignTokens.font.captionM)
              .fontColor($r('app.color.warning_orange'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: DesignTokens.space.tiny })
          }

          // 发现超时
          Row() {
            Text($r('app.string.discovery_timeout_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Text(this.viewModel.discoveryTimeout.toString())
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openInputDialog($r('app.string.discovery_timeout_label'), this.viewModel.discoveryTimeout.toString(),
              (value: string) => {
                this.viewModel.setDiscoveryTimeoutValue(value);
              });
          })
          .id('settings_discovery_timeout_entry')

          // 网络接口（点击弹出半屏弹窗）
          Row() {
            Text($r('app.string.network_interface_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            SymbolGlyph($r('sys.symbol.chevron_forward'))
              .fontSize(DesignTokens.font.titleS)
              .fontColor([$r('app.color.text_secondary')])
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            // 打开弹窗前刷新接口列表——VPN/隧道等接口变化不会触发系统网络事件，
            // 必须在用户查看时主动枚举才能保证列表最新
            this.viewModel.refreshLocalInterfaces();
            // 将本地临时状态初始化为当前保存值
            this.localInterfaces = networkSettingsViewModel.sortInterfaces(this.viewModel.getLocalInterfacesList());
            let savedWhitelist = this.parseList(this.viewModel.networkWhitelist);
            let savedBlacklist = this.parseList(this.viewModel.networkBlacklist);
            logger.debug('接口: [' +
              this.localInterfaces.map((i: NetworkInterface) => i.name + '(' + i.ip + ')').join(', ') + ']');
            logger.debug(
              '存储白名单: [' + savedWhitelist.join(', ') + '] 黑名单: [' + savedBlacklist.join(', ') +
                ']');
            // 恢复保存的白/黑名单，再统一调用 applySheetInterfaces 将不在保存值中的活跃接口
            // 按默认规则纳入本地列表（wifi/ethernet → 白名单，其他 → 黑名单，空名接口跳过）。
            // 由此本地列表与 hasUnsavedChanges() 计算的期望状态对称，未做任何修改直接关闭时不再误报。
            this.localWhitelist = savedWhitelist;
            this.localBlacklist = savedBlacklist;
            this.applySheetInterfaces(this.localInterfaces);
            this.isShowNetworkInterfaceSheet = true;
          })
          .id('settings_network_interface_entry')
          .bindSheet($$this.isShowNetworkInterfaceSheet, this.networkInterfaceSheetBuilder(), {
            height: SheetSize.FIT_CONTENT,
            width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
            // 宽屏（lg/xl）以居中弹窗呈现，窄屏保持底部弹窗（与手机行为一致）
            preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
            blurStyle: BlurStyle.Regular,
            title: {
              title: $r('app.string.network_interface_label'),
              subtitle: $r('app.string.network_interface_desc')
            },
            showClose: true,
            keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL,
            onWillDismiss: (dismissSheetAction: DismissSheetAction) => {
              if (this.hasUnsavedChanges()) {
                // 有未保存修改时，弹窗确认是否丢弃
                this.getUIContext().showAlertDialog({
                  message: $r('app.string.unsaved_changes_message'),
                  autoCancel: true,
                  alignment: DialogAlignment.Bottom,
                  primaryButton: {
                    value: $r('app.string.dialog_cancel'),
                    action: () => {
                      // 取消关闭，弹窗保持打开
                    }
                  },
                  secondaryButton: {
                    enabled: true,
                    defaultFocus: true,
                    style: DialogButtonStyle.HIGHLIGHT,
                    value: $r('app.string.discard'),
                    action: () => {
                      // 用户选择丢弃，关闭弹窗
                      dismissSheetAction.dismiss();
                    }
                  }
                });
              } else {
                // 无修改，直接关闭
                dismissSheetAction.dismiss();
              }
            }
          })
        }
      }
      .width('100%')
      .padding({
        left: DesignTokens.space.lg,
        right: DesignTokens.space.lg,
        top: DesignTokens.space.md,
        bottom: DesignTokens.space.md
      })
      .borderRadius(DesignTokens.radius.lg)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      .margin({ top: DesignTokens.space.sm })
    }
    .width('100%')
  }
}
