import {
  deviceInfo
} from '@kit.BasicServicesKit';
import {
  DeviceTypeOption
} from '../../components/settings/SettingsTypes';
import {
  DialogService
} from '../../service/DialogService';
import {
  DesignTokens
} from '../../common/DesignTokens';
import {
  SettingsViewModel
} from '../../viewmodel/SettingsViewModel';
import {
  NetworkInterface,
  NetworkType
} from '../../model/Types';

// 网络与设备身份设置分组（服务器状态/昵称/设备类型/设备型号/高级设置，从 SettingsContent 拆出）。
@ComponentV2
export struct NetworkSettingsSection {
  @Require @Param viewModel: SettingsViewModel
  @Local isRestarting: boolean = false
  @Local isShowNetworkInterfaceSheet: boolean = false
  @Local localWhitelist: Array<string> = []
  @Local localBlacklist: Array<string> = []
  @Local localInterfaces: Array<NetworkInterface> = []
  @Local isShowDeviceTypeSheet: boolean = false

  private deviceTypeOptions: Array<DeviceTypeOption> = [
    { value: 'mobile', label: $r('app.string.device_type_mobile'), icon: $r('app.media.ic_device_mobile') },
    { value: 'desktop', label: $r('app.string.device_type_desktop'), icon: $r('app.media.ic_device_desktop') },
    { value: 'web', label: $r('app.string.device_type_web'), icon: $r('app.media.ic_device_web') },
    { value: 'headless', label: $r('app.string.device_type_headless'), icon: $r('app.media.ic_device_headless') },
    { value: 'server', label: $r('app.string.device_type_server'), icon: $r('app.media.ic_device_server') },
    { value: 'tablet', label: $r('app.string.device_type_tablet'), icon: $r('app.media.ic_device_tablet') }
  ]

  private getDefaultAlias(): string {
    return deviceInfo.manufacture + ' ' + deviceInfo.productModel;
  }

  private getCurrentDeviceTypeOption(): DeviceTypeOption {
    for (let i = 0; i < this.deviceTypeOptions.length; i++) {
      if (this.deviceTypeOptions[i].value === this.viewModel.customDeviceType) {
        return this.deviceTypeOptions[i];
      }
    }
    return this.deviceTypeOptions[0];
  }

  private showAliasDialog(): void {
    DialogService.showInputDialog($r('app.string.input_alias_title'), this.viewModel.customAlias, (value: string) => {
      this.viewModel.setAlias(value);
    });
  }

  private showModelDialog(): void {
    DialogService.showInputDialog($r('app.string.input_model_title'), this.viewModel.customDeviceModel, (value: string) => {
      this.viewModel.setDeviceModel(value);
    });
  }

  private showDeviceTypeDialog(): void {
    this.isShowDeviceTypeSheet = true;
  }

  private showEncryptionNotice(): void {
    DialogService.showEncryptionNotice(() => {
      this.viewModel.setEncryptionEnabled(false);
    });
  }

  // 运行异步服务器操作，附带至少 800ms 的加载动画
  private runServerAction(action: () => Promise<string | void>): void {
    this.isRestarting = true;
    let startTime = Date.now();
    action().then(() => {
      let remaining = 800 - (Date.now() - startTime);
      if (remaining > 0) {
        setTimeout(() => { this.isRestarting = false; }, remaining);
      } else {
        this.isRestarting = false;
      }
    }).catch(() => {
      this.isRestarting = false;
    });
  }

  // 解析逗号分隔文本为字符串数组
  private parseList(text: string): Array<string> {
    if (text.length === 0) {
      return [];
    }
    let normalized = text.replace(new RegExp('，', 'g'), ',').replace(new RegExp('\\n', 'g'), ',');
    let parts = normalized.split(',');
    let result: Array<string> = [];
    for (let i = 0; i < parts.length; i++) {
      let trimmed = parts[i].trim();
      if (trimmed.length > 0) {
        result.push(trimmed);
      }
    }
    return result;
  }

  // 检查弹窗内容是否有未保存的修改
  private hasUnsavedChanges(): boolean {
    let savedWhitelist = this.parseList(this.viewModel.networkWhitelist);
    let savedBlacklist = this.parseList(this.viewModel.networkBlacklist);
    if (savedWhitelist.length !== this.localWhitelist.length) {
      return true;
    }
    if (savedBlacklist.length !== this.localBlacklist.length) {
      return true;
    }
    for (let i = 0; i < savedWhitelist.length; i++) {
      if (savedWhitelist[i] !== this.localWhitelist[i]) {
        return true;
      }
    }
    for (let i = 0; i < savedBlacklist.length; i++) {
      if (savedBlacklist[i] !== this.localBlacklist[i]) {
        return true;
      }
    }
    return false;
  }

  // 判断网络类型是否在白名单中（黑名单优先：类型同时在黑名单中视为不在白名单）
  private isTypeWhitelisted(type: string): boolean {
    if (this.isTypeBlacklisted(type)) {
      return false;
    }
    for (let i = 0; i < this.localWhitelist.length; i++) {
      if (this.localWhitelist[i] === type) {
        return true;
      }
    }
    return false;
  }

  // 判断网络类型是否在黑名单中
  private isTypeBlacklisted(type: string): boolean {
    for (let i = 0; i < this.localBlacklist.length; i++) {
      if (this.localBlacklist[i] === type) {
        return true;
      }
    }
    return false;
  }

  // 从数组中移除指定元素
  private removeFromList(list: Array<string>, item: string): Array<string> {
    let result: Array<string> = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i] !== item) {
        result.push(list[i]);
      }
    }
    return result;
  }

  // 默认白名单类型：WiFi + 以太网
  private readonly DEFAULT_WHITELIST_TYPES: Array<string> = [NetworkType.wifi, NetworkType.ethernet];

  // 默认黑名单类型：蜂窝 + 未知
  private readonly DEFAULT_BLACKLIST_TYPES: Array<string> = [NetworkType.cellular, NetworkType.unknown];

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

  // 根据 NetworkType 获取对应的标签资源
  private getNetworkTypeLabel(type: NetworkType): Resource {
    if (type === NetworkType.wifi) {
      return $r('app.string.network_type_wifi');
    } else if (type === NetworkType.cellular) {
      return $r('app.string.network_type_cellular');
    } else if (type === NetworkType.ethernet) {
      return $r('app.string.network_type_ethernet');
    } else {
      return $r('app.string.network_type_unknown');
    }
  }

  // 判断接口列表是否为空（无接口或仅有 0.0.0.0）
  private isInterfaceListEmpty(): boolean {
    if (this.localInterfaces.length === 0) {
      return true;
    }
    if (this.localInterfaces.length === 1 && this.localInterfaces[0].ip === '0.0.0.0') {
      return true;
    }
    return false;
  }

  // 网络类型排序优先级：WiFi > 以太网 > 未知 > 蜂窝（蜂窝基本不存在局域网传输场景）
  private getNetworkTypePriority(type: NetworkType): number {
    if (type === NetworkType.wifi) {
      return 0;
    } else if (type === NetworkType.ethernet) {
      return 1;
    } else if (type === NetworkType.unknown) {
      return 2;
    } else {
      // cellular 排最低
      return 3;
    }
  }

  // 对接口列表按优先级排序
  private sortInterfaces(interfaces: Array<NetworkInterface>): Array<NetworkInterface> {
    let sorted: Array<NetworkInterface> = [];
    for (let i = 0; i < interfaces.length; i++) {
      sorted.push(interfaces[i]);
    }
    for (let i = 0; i < sorted.length - 1; i++) {
      for (let j = i + 1; j < sorted.length; j++) {
        if (this.getNetworkTypePriority(sorted[i].type) > this.getNetworkTypePriority(sorted[j].type)) {
          let temp = sorted[i];
          sorted[i] = sorted[j];
          sorted[j] = temp;
        }
      }
    }
    return sorted;
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
            .padding({ left: DesignTokens.space.lg, right: DesignTokens.space.lg, top: 14, bottom: 14 })
        }
        .width('100%')
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(DesignTokens.radius.lg)
        .border({ width: 1, color: $r('app.color.border_light') })
      } else {
        Column() {
          ForEach(this.localInterfaces, (netIf: NetworkInterface, index: number) => {
            Column() {
              Row({ space: DesignTokens.space.sm }) {
                // 网络类型图标
                SymbolGlyph(this.getNetworkTypeSymbol(netIf.type))
                  .fontSize(22)
                  .fontColor([$r('app.color.text_primary')])

                // IP 地址 + 网络类型标签
                Column({ space: 2 }) {
                  Text(netIf.ip)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor($r('app.color.text_primary'))
                    .fontWeight(FontWeight.Medium)

                  Text(this.getNetworkTypeLabel(netIf.type))
                    .fontSize(DesignTokens.font.captionM)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                // Toggle 开关：开=白名单（允许扫描），关=黑名单（不扫描）
                // 同一网络类型的所有接口联动
                Toggle({ type: ToggleType.Switch, isOn: this.isTypeWhitelisted(netIf.type) })
                  .onChange((isOn: boolean) => {
                    let typeStr = netIf.type;
                    if (isOn) {
                      // 打开：从黑名单移到白名单
                      this.localBlacklist = this.removeFromList(this.localBlacklist, typeStr);
                      if (!this.isTypeWhitelisted(typeStr)) {
                        this.localWhitelist.push(typeStr);
                      }
                    } else {
                      // 关闭：从白名单移到黑名单
                      this.localWhitelist = this.removeFromList(this.localWhitelist, typeStr);
                      if (!this.isTypeBlacklisted(typeStr)) {
                        this.localBlacklist.push(typeStr);
                      }
                    }
                  })
              }
              .width('100%')
              .padding({ left: DesignTokens.space.lg, right: DesignTokens.space.lg, top: 14, bottom: 14 })
              .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
              .alignItems(VerticalAlign.Center)

              if (index < this.localInterfaces.length - 1) {
                Divider().color($r('app.color.border_light'))
              }
            }
            .width('100%')
          }, (netIf: NetworkInterface) => netIf.ip)
        }
        .width('100%')
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(DesignTokens.radius.lg)
        .border({ width: 1, color: $r('app.color.border_light') })
      }

      // 保存按钮
      Button($r('app.string.save'))
        .width('100%')
        .height(DesignTokens.hotspot.minSize)
        .type(ButtonType.Normal)
        .backgroundColor($r('app.color.accent_blue'))
        .fontColor($r('app.color.text_on_color'))
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.lg })
        .onClick(() => {
          // 白名单/黑名单存储网络类型（如 wifi,ethernet），而非精确 IP
          this.viewModel.setNetworkWhitelistValue(this.localWhitelist.join(','));
          this.viewModel.setNetworkBlacklistValue(this.localBlacklist.join(','));
          this.isShowNetworkInterfaceSheet = false;
        })
    }
    .width('100%')
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
  }

  // 设备类型半屏弹窗：系统标题 + 列表选择，选中项高亮
  @Builder
  deviceTypeSheetBuilder(): void {
    Column() {
      // 卡片容器：列表项 + Divider 分隔线
      Column() {
        List({ space: 0 }) {
          ForEach(this.deviceTypeOptions, (item: DeviceTypeOption, index: number) => {
            ListItem() {
              Column() {
                Row({ space: DesignTokens.space.sm }) {
                  Image(item.icon)
                    .width(22)
                    .height(22)
                    .fillColor(this.viewModel.customDeviceType === item.value ? $r('app.color.accent_blue') : $r('app.color.text_primary'))

                  Text(item.label)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor(this.viewModel.customDeviceType === item.value ? $r('app.color.accent_blue') : $r('app.color.text_primary'))
                    .fontWeight(this.viewModel.customDeviceType === item.value ? FontWeight.Bold : FontWeight.Normal)
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: DesignTokens.space.lg, right: DesignTokens.space.lg, top: 14, bottom: 14 })
                .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
                .alignItems(VerticalAlign.Center)
                .borderRadius(DesignTokens.radius.md)
                .onClick(() => {
                  this.viewModel.setDeviceType(item.value);
                  this.isShowDeviceTypeSheet = false;
                })

                if (index < this.deviceTypeOptions.length - 1) {
                  Divider().color($r('app.color.border_light'))
                }
              }
              .width('100%')
            }
          }, (item: DeviceTypeOption) => item.value)
        }
        .width('100%')
      }
      .width('100%')
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: 1, color: $r('app.color.border_light') })
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
              .width(20)
              .height(20)
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
        }
        .width('100%')
        .padding(DesignTokens.space.md)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.warning_bg'))
        .border({ width: 1, color: $r('app.color.warning_orange') })
        .margin({ top: DesignTokens.space.md })
      }

      Column() {
        Text($r('app.string.settings_network'))
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .alignSelf(ItemAlign.Start)

        // 服务器状态（顶层第一项）
        Row() {
          if (this.isRestarting) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color($r('app.color.text_secondary'))
              .margin({ right: DesignTokens.space.xs })
          }
          Text(this.viewModel.serverReady ? $r('app.string.server_status_running') : $r('app.string.server_status_offline'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor(this.viewModel.serverReady ? $r('app.color.success_green') : $r('app.color.text_secondary'))
            .layoutWeight(1)

          Row({ space: DesignTokens.space.xs }) {
            if (!this.viewModel.serverReady) {
              Button($r('app.string.start_server'))
                .fontSize(DesignTokens.font.bodyS)
                .height(28)
                .fontColor($r('app.color.text_on_color'))
                .backgroundColor($r('app.color.accent_blue'))
                .borderRadius(DesignTokens.radius.max)
                .enabled(!this.isRestarting)
                .onClick(() => {
                  this.runServerAction(() => this.viewModel.startServer());
                })
            } else {
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
              Button($r('app.string.stop_server'))
                .fontSize(DesignTokens.font.bodyS)
                .height(28)
                .fontColor($r('app.color.text_on_color'))
                .backgroundColor($r('app.color.danger_red'))
                .borderRadius(DesignTokens.radius.max)
                .enabled(!this.isRestarting)
                .onClick(() => {
                  this.runServerAction(() => this.viewModel.stopServer());
                })
            }
          }
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)

        // 设备名称，带骰子随机和系统名称按钮
        Row() {
          Text($r('app.string.input_alias_title'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Row({ space: DesignTokens.space.xs }) {
            // 骰子按钮响应区域→48vp
            SymbolGlyph($r('sys.symbol.shuffle'))
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor([$r('app.color.text_primary')])
              .responseRegion({ x: -8, y: -8, width: 48, height: 48 })
              .onClick(() => {
                this.viewModel.randomizeAlias();
              })

            // 系统名称按钮响应区域→48vp
            SymbolGlyph($r('sys.symbol.computer_fill'))
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor([$r('app.color.text_primary')])
              .responseRegion({ x: -8, y: -8, width: 48, height: 48 })
              .onClick(() => {
                this.viewModel.useSystemAlias();
              })

            Text(this.viewModel.customAlias || this.getDefaultAlias())
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.showAliasDialog();
        })

        // 设备类型
        Row() {
          Text($r('app.string.select_device_type_title'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Row({ space: 6 }) {
            Image(this.getCurrentDeviceTypeOption().icon)
              .width(DesignTokens.font.subtitleL)
              .height(DesignTokens.font.subtitleL)
              .fillColor($r('app.color.text_primary'))

            Text(this.getCurrentDeviceTypeOption().label)
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))

            SymbolGlyph($r('sys.symbol.chevron_forward'))
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor([$r('app.color.text_secondary')])
              .margin({ left: DesignTokens.space.xs })
          }
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.showDeviceTypeDialog();
        })
        .bindSheet($$this.isShowDeviceTypeSheet, this.deviceTypeSheetBuilder(), {
          height: SheetSize.MEDIUM,
          preferType: SheetType.BOTTOM,
          width: 480,
          blurStyle: BlurStyle.Regular,
          title: {
            title: $r('app.string.select_device_type_title'),
            subtitle: ""
          },
          showClose: true
        })

        // 设备型号
        Row() {
          Text($r('app.string.input_model_title'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Row() {
            Text(this.viewModel.customDeviceModel || deviceInfo.productModel)
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.showModelDialog();
        })

        // 高级设置开关
        Row() {
          Text($r('app.string.advanced_settings_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.viewModel.advancedSettings })
            .onChange((isOn: boolean) => {
              this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
                this.viewModel.setAdvancedSettingsEnabled(isOn);
              });
            })
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.advanced_settings_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.xs })

        // 高级设置（开关打开时显示）
        if (this.viewModel.advancedSettings) {
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
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
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

          Text($r('app.string.encrypted_transfer_desc'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .alignSelf(ItemAlign.Start)
            .margin({ bottom: DesignTokens.space.xs })

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
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            DialogService.showInputDialog($r('app.string.port_label'), this.viewModel.port.toString(), (value: string) => {
              this.viewModel.setPortValue(value);
            });
          })

          if (this.viewModel.port !== 53317) {
           Text($r('app.string.port_warning'))
              .fontSize(DesignTokens.font.captionM)
              .fontColor($r('app.color.warning_orange'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: DesignTokens.space.xs })
          }

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
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            DialogService.showInputDialog($r('app.string.multicast_group_label'), this.viewModel.multicastGroup, (value: string) => {
              this.viewModel.setMulticastGroupValue(value);
            });
          })

          if (this.viewModel.multicastGroup !== '224.0.0.167') {
            Text($r('app.string.multicast_warning'))
              .fontSize(DesignTokens.font.captionM)
              .fontColor($r('app.color.warning_orange'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: DesignTokens.space.xs })
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
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            DialogService.showInputDialog($r('app.string.discovery_timeout_label'), this.viewModel.discoveryTimeout.toString(), (value: string) => {
              this.viewModel.setDiscoveryTimeoutValue(value);
            });
          })

          // 网络接口（替代原白名单/黑名单两行，点击弹出半屏弹窗）
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
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            // 打开弹窗前将本地临时状态初始化为当前保存值
            this.localInterfaces = this.sortInterfaces(this.viewModel.getLocalInterfacesList());
            let savedWhitelist = this.parseList(this.viewModel.networkWhitelist);
            let savedBlacklist = this.parseList(this.viewModel.networkBlacklist);
            if (savedWhitelist.length === 0 && savedBlacklist.length === 0) {
              // 首次使用：WiFi/以太网默认白名单，其他默认黑名单
              this.localWhitelist = this.DEFAULT_WHITELIST_TYPES.slice();
              this.localBlacklist = this.DEFAULT_BLACKLIST_TYPES.slice();
            } else {
              // 已有配置：恢复保存的网络类型列表
              this.localWhitelist = savedWhitelist;
              this.localBlacklist = savedBlacklist;
            }
            this.isShowNetworkInterfaceSheet = true;
          })
          .bindSheet($$this.isShowNetworkInterfaceSheet, this.networkInterfaceSheetBuilder(), {
            height: SheetSize.MEDIUM,
            preferType: SheetType.BOTTOM,
            width: 480,
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
      .padding(DesignTokens.space.lg)
      .borderRadius(DesignTokens.radius.lg)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: 1, color: $r('app.color.border_light') })
      .margin({ top: DesignTokens.space.md })
    }
    .width('100%')
  }
}
