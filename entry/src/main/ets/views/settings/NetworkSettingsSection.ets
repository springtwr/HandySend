import {
  deviceInfo
} from '@kit.BasicServicesKit';
import {
  getSystemDeviceName
} from '../../utils/AliasGenerator';
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
  NetworkInterface, NetworkType
} from '../../model/Types';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.NETWORK, 'HandySend:NetworkSettings');

// 白/黑名单分组（hasUnsavedChanges 期望状态构建用）
class WhitelistBlacklist {
  whitelist: Array<string> = []
  blacklist: Array<string> = []
}

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
  // 高级设置展开状态（可展开列表：点击标题行展开/收起）
  @Local isAdvancedExpanded: boolean = false

  // 监听接口列表版本变化，弹窗开着时自动刷新。
  // 仅在接口数据实际变化时刷新，避免 notifyChange 触发的 interfaceListVersion 递增
  // （可能源于设备发现、传输进度等与接口无关的变化）导致无意义重刷。
  @Monitor('viewModel.interfaceListVersion')
  onInterfaceListVersionChange(): void {
    if (this.isShowNetworkInterfaceSheet) {
      let currentInterfaces = this.sortInterfaces(this.viewModel.getLocalInterfacesList());
      if (!this.interfacesEqual(this.localInterfaces, currentInterfaces)) {
        this.applySheetInterfaces(currentInterfaces);
      }
    }
  }

  // 比较两组接口是否相同（按排序后顺序逐项比较 name+ip+type+isDefault）
  private interfacesEqual(a: Array<NetworkInterface>, b: Array<NetworkInterface>): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i].name !== b[i].name || a[i].ip !== b[i].ip ||
        a[i].type !== b[i].type || a[i].isDefault !== b[i].isDefault) {
        return false;
      }
    }
    return true;
  }

  // 刷新弹窗中的接口列表：重新枚举接口 + 处理新接口默认 Toggle 状态。
  // 注意：不清理消失接口——保留在白/黑名单中，接口回来时自动恢复状态；
  // hasUnsavedChanges 的 activeListsEqual 只比较活跃接口，不会因消失接口误报。
  private refreshSheetInterfaces(): void {
    // 重新枚举接口（VPN/隧道接口变化不触发系统网络事件，
    // 需要用户点击刷新按钮才能捕获）。
    this.viewModel.refreshLocalInterfaces();
    let newInterfaces = this.sortInterfaces(this.viewModel.getLocalInterfacesList());
    this.applySheetInterfaces(newInterfaces);
  }

  // 将排序后的接口列表应用到弹窗状态，处理新接口的默认 Toggle 分配
  private applySheetInterfaces(newInterfaces: Array<NetworkInterface>): void {
    logger.debug('[refreshSheet] 刷新后接口: [' +
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
      logger.debug('[refreshSheet] 新增 ' + addedCount + ' 个接口（按默认规则分配）');
    }
    this.localInterfaces = newInterfaces;
    logger.debug(
      '[refreshSheet] 最终白名单: [' + this.localWhitelist.join(', ') + '] 黑名单: [' + this.localBlacklist.join(', ') +
        ']');
  }

  private deviceTypeOptions: Array<DeviceTypeOption> = [
    { value: 'mobile', label: $r('app.string.device_type_mobile'), icon: $r('app.media.ic_device_mobile') },
    { value: 'desktop', label: $r('app.string.device_type_desktop'), icon: $r('app.media.ic_device_desktop') },
    { value: 'tablet', label: $r('app.string.device_type_tablet'), icon: $r('app.media.ic_device_tablet') }
  ]

  private getDefaultAlias(): string {
    return getSystemDeviceName();
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
  // 逻辑：计算"期望状态"——存储值中的接口保持存储状态，不在存储值中的活跃接口用默认状态——
  // 然后与 localWhitelist/localBlacklist 比较。新出现的接口用默认值不算修改。
  private hasUnsavedChanges(): boolean {
    let savedWhitelist = this.parseList(this.viewModel.networkWhitelist);
    let savedBlacklist = this.parseList(this.viewModel.networkBlacklist);

    // 计算期望状态
    let expected = new WhitelistBlacklist();
    let savedWhitelistSet: Set<string> = new Set();
    let savedBlacklistSet: Set<string> = new Set();
    for (let i = 0; i < savedWhitelist.length; i++) {
      savedWhitelistSet.add(savedWhitelist[i]);
    }
    for (let i = 0; i < savedBlacklist.length; i++) {
      savedBlacklistSet.add(savedBlacklist[i]);
    }

    // 遍历当前活跃接口，决定每个接口的"期望"状态
    for (let i = 0; i < this.localInterfaces.length; i++) {
      let name = this.localInterfaces[i].name;
      if (name.length === 0) {
        continue;
      }
      if (savedWhitelistSet.has(name)) {
        expected.whitelist.push(name);
      } else if (savedBlacklistSet.has(name)) {
        expected.blacklist.push(name);
      } else {
        // 不在存储值中：按默认规则
        if (this.localInterfaces[i].type === NetworkType.wifi ||
          this.localInterfaces[i].type === NetworkType.ethernet) {
          expected.whitelist.push(name);
        } else {
          expected.blacklist.push(name);
        }
      }
    }

    // 只比较活跃接口部分（忽略已消失接口的残留存储值）
    if (!this.activeListsEqual(this.localWhitelist, expected.whitelist)) {
      return true;
    }
    if (!this.activeListsEqual(this.localBlacklist, expected.blacklist)) {
      return true;
    }
    return false;
  }

  // 比较两个列表中"活跃接口名"是否一致（忽略不在当前接口列表中的条目）
  private activeListsEqual(a: Array<string>, b: Array<string>): boolean {
    let activeNames: Set<string> = new Set();
    for (let i = 0; i < this.localInterfaces.length; i++) {
      if (this.localInterfaces[i].name.length > 0) {
        activeNames.add(this.localInterfaces[i].name);
      }
    }
    // 收集两列表中活跃接口名的集合
    let setA: Set<string> = new Set();
    let setB: Set<string> = new Set();
    for (let i = 0; i < a.length; i++) {
      if (activeNames.has(a[i])) {
        setA.add(a[i]);
      }
    }
    for (let i = 0; i < b.length; i++) {
      if (activeNames.has(b[i])) {
        setB.add(b[i]);
      }
    }
    if (setA.size !== setB.size) {
      return false;
    }
    // 逐项比较
    let arrA = Array.from(setA);
    for (let i = 0; i < arrA.length; i++) {
      if (!setB.has(arrA[i])) {
        return false;
      }
    }
    return true;
  }

  // 比较两个字符串数组是否相等（顺序敏感）
  private listsEqual(a: Array<string>, b: Array<string>): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  // 判断接口是否在白名单中（黑名单优先：接口同时在黑名单中视为不在白名单）
  private isInterfaceWhitelisted(name: string): boolean {
    if (this.isInterfaceBlacklisted(name)) {
      return false;
    }
    for (let i = 0; i < this.localWhitelist.length; i++) {
      if (this.localWhitelist[i] === name) {
        return true;
      }
    }
    return false;
  }

  // 判断接口是否在黑名单中
  private isInterfaceBlacklisted(name: string): boolean {
    for (let i = 0; i < this.localBlacklist.length; i++) {
      if (this.localBlacklist[i] === name) {
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
                    Text(this.getNetworkTypeLabel(netIf.type))
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
                    logger.debug('[Toggle] ' + name + ': ' + (isOn ? '白名单' : '黑名单'));
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
                    logger.debug('[Toggle] 白名单: [' + this.localWhitelist.join(', ') + '] 黑名单: [' +
                      this.localBlacklist.join(', ') + ']');
                  })
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
        .fontColor($r('app.color.accent_blue'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.md })
        .onClick(() => {
          logger.debug('[refresh] 手动刷新接口列表');
          this.refreshSheetInterfaces();
        })

      // 保存按钮
      Button($r('app.string.save'))
        .width('100%')
        .height(DesignTokens.size.thumbSm)
        .type(ButtonType.Normal)
        .backgroundColor($r('app.color.accent_blue'))
        .fontColor($r('app.color.text_on_color'))
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.lg })
        .onClick(() => {
          // 白名单/黑名单存储接口名（如 wlan0,eth0），而非精确 IP
          // 保存后自动重启 discovery，无需手动重启服务器
          logger.debug(
            '[save] 白名单: [' + this.localWhitelist.join(', ') + '] 黑名单: [' + this.localBlacklist.join(', ') + ']');
          this.viewModel.saveNetworkListsAndApply(this.localWhitelist.join(','), this.localBlacklist.join(','));
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
                     .width(DesignTokens.size.iconSm)
                     .height(DesignTokens.size.iconSm)
                    .fillColor(this.viewModel.customDeviceType === item.value ? $r('app.color.accent_blue') :
                      $r('app.color.text_primary'))

                  Text(item.label)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor(this.viewModel.customDeviceType === item.value ? $r('app.color.accent_blue') :
                      $r('app.color.text_primary'))
                    .fontWeight(this.viewModel.customDeviceType === item.value ? FontWeight.Bold : FontWeight.Normal)
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({
                  left: DesignTokens.space.lg,
                  right: DesignTokens.space.lg,
                  top: 14,
                  bottom: 14
                })
                .constraintSize({ minHeight: DesignTokens.size.thumbSm })
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
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
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

      // 卡片外标题（左上角左对齐）
      Column() {
        Text($r('app.string.settings_network'))
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .margin({ top: DesignTokens.space.lg })

      // 卡片（标题在外）
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
            }
          }
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        // 设备名称，带骰子随机和系统名称按钮
        Row() {
          Text($r('app.string.input_alias_title'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Row({ space: DesignTokens.space.tiny }) {
            // 骰子按钮响应区域→48vp
            SymbolGlyph($r('sys.symbol.shuffle'))
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor([$r('app.color.text_primary')])
              .responseRegion({
                x: -8,
                y: -8,
                width: 48,
                height: 48
              })
              .onClick(() => {
                this.viewModel.randomizeAlias();
              })

            // 系统名称按钮响应区域→48vp
            SymbolGlyph($r('sys.symbol.computer_fill'))
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor([$r('app.color.text_primary')])
              .responseRegion({
                x: -8,
                y: -8,
                width: 48,
                height: 48
              })
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
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
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

           Row({ space: DesignTokens.space.tiny }) {
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
              .margin({ left: DesignTokens.space.tiny })
          }
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.showDeviceTypeDialog();
        })
        .bindSheet($$this.isShowDeviceTypeSheet, this.deviceTypeSheetBuilder(), {
          height: SheetSize.MEDIUM,
          preferType: SheetType.BOTTOM,
          width: DesignTokens.size.sheetWidth,
          blurStyle: BlurStyle.Regular,
          title: {
            title: $r('app.string.select_device_type_title'),
            subtitle: ''
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
            Text(deviceInfo.productModel)
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        // 高级设置（可展开列表：点击标题行展开/收起，替代原开关）
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
            DialogService.showInputDialog($r('app.string.port_label'), this.viewModel.port.toString(),
              (value: string) => {
                this.viewModel.setPortValue(value);
              });
          })

          if (this.viewModel.port !== 53317) {
            Text($r('app.string.port_warning'))
              .fontSize(DesignTokens.font.captionM)
              .fontColor($r('app.color.warning_orange'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: DesignTokens.space.tiny })
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
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            DialogService.showInputDialog($r('app.string.multicast_group_label'), this.viewModel.multicastGroup,
              (value: string) => {
                this.viewModel.setMulticastGroupValue(value);
              });
          })

          if (this.viewModel.multicastGroup !== '224.0.0.167') {
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
            DialogService.showInputDialog($r('app.string.discovery_timeout_label'),
              this.viewModel.discoveryTimeout.toString(), (value: string) => {
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
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            // 打开弹窗前刷新接口列表——VPN/隧道等接口变化不会触发系统网络事件，
            // 必须在用户查看时主动枚举才能保证列表最新
            this.viewModel.refreshLocalInterfaces();
            // 将本地临时状态初始化为当前保存值
            this.localInterfaces = this.sortInterfaces(this.viewModel.getLocalInterfacesList());
            let savedWhitelist = this.parseList(this.viewModel.networkWhitelist);
            let savedBlacklist = this.parseList(this.viewModel.networkBlacklist);
            logger.debug('[openSheet] 接口: [' +
              this.localInterfaces.map((i: NetworkInterface) => i.name + '(' + i.ip + ')').join(', ') + ']');
            logger.debug(
              '[openSheet] 存储白名单: [' + savedWhitelist.join(', ') + '] 黑名单: [' + savedBlacklist.join(', ') +
                ']');
            // 恢复保存的白/黑名单，再统一调用 applySheetInterfaces 将不在保存值中的活跃接口
            // 按默认规则纳入本地列表（wifi/ethernet → 白名单，其他 → 黑名单，空名接口跳过）。
            // 由此本地列表与 hasUnsavedChanges() 计算的期望状态对称，未做任何修改直接关闭时不再误报。
            this.localWhitelist = savedWhitelist;
            this.localBlacklist = savedBlacklist;
            this.applySheetInterfaces(this.localInterfaces);
            this.isShowNetworkInterfaceSheet = true;
          })
          .bindSheet($$this.isShowNetworkInterfaceSheet, this.networkInterfaceSheetBuilder(), {
            height: SheetSize.MEDIUM,
            preferType: SheetType.BOTTOM,
            width: DesignTokens.size.sheetWidth,
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
