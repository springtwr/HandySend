import { DesignTokens } from '../../common/DesignTokens';
import { SettingsViewModel } from '../../viewmodel/SettingsViewModel';
import { WebPortError, isEligibleWebInterface } from '../../model/WebAddress';
import { NetworkInterface, NetworkType } from '../../model/Types';
import { networkTypeLabel, networkTypeSymbol } from '../../utils/NetworkPresentation';
import { networkSettingsViewModel } from '../../viewmodel/NetworkSettingsViewModel';
import { getSheetWidth, isWideWidth } from '../../common/Breakpoints';
import { EmptyState } from '../../components/EmptyState';
import {
  AdvancedDialogV2Button,
  CustomContentDialogV2,
  promptAction,
  uiObserver
} from '@kit.ArkUI';
import { getStringSync } from '../../utils/ResourceUtil';

/**
 * WebSettingsSection.ets — 网页传输设置分组：发送 / 接收两个允许开关，
 * 以及网页独立的加密传输、访问密码、网络接口与端口。
 *
 * 两方向开关与面板内启停按钮、发送页菜单勾选双向同步；
 * 加密/密码/端口变更需要重启网页服务，有活跃网页会话时先二次确认；
 * 接口筛选只影响地址展示，不重启服务。
 * 数据经 @Param 绑定父组件 VM，命令直调 VM（View → ViewModel）。
 */
@ComponentV2
export struct WebSettingsSection {
  @Require @Param viewModel: SettingsViewModel
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local private isShowInterfaceSheet: boolean = false
  @Local private sheetInterfaces: Array<NetworkInterface> = []
  // 弹窗内编辑的白/黑名单：黑名单优先，未列出的接口按类型取默认
  @Local private localWhitelist: Array<string> = []
  @Local private localBlacklist: Array<string> = []
  // 高级设置展开状态（加密传输 / 端口 / 网络接口）
  @Local private isAdvancedExpanded: boolean = false
  @Local private pendingPin: string = ''
  @Local private pendingPort: string = ''
  private activeDialogId: number = -1

  // ── 访问密码弹窗 ──

  private openPinDialog(): void {
    this.pendingPin = this.viewModel.webPin;
    let options: promptAction.CustomDialogOptions = {
      builder: () => {
        this.pinDialog();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(options)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
      });
  }

  @Builder
  pinDialog() {
    CustomContentDialogV2({
      primaryTitle: $r('app.string.web_pin_label'),
      contentBuilder: () => {
        this.pinContent();
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
            let pin: string = this.pendingPin;
            this.closeActiveDialog();
            this.viewModel.setWebPinValue(pin);
          }
        })
      ]
    })
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  pinContent() {
    Column({ space: DesignTokens.space.sm }) {
      TextInput({ text: this.pendingPin })
        .borderRadius(DesignTokens.radius.max)
        .id('settings_web_pin_input')
        .onChange((value: string) => {
          this.pendingPin = value;
        })
    }
    .width('100%')
  }

  // ── 端口弹窗 ──

  private openPortDialog(): void {
    this.pendingPort = String(this.viewModel.webPort);
    let options: promptAction.CustomDialogOptions = {
      builder: () => {
        this.portDialog();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(options)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
      });
  }

  private showPortError(error: WebPortError): void {
    let message: Resource = error === WebPortError.conflict ?
      $r('app.string.web_port_conflict') : $r('app.string.web_port_invalid');
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  @Builder
  portDialog() {
    CustomContentDialogV2({
      primaryTitle: $r('app.string.web_port_label'),
      contentBuilder: () => {
        this.portContent();
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
            let raw: string = this.pendingPort;
            let error: WebPortError = this.viewModel.validateWebPortValue(raw);
            if (error !== WebPortError.none) {
              this.showPortError(error);
              return;
            }
            this.closeActiveDialog();
            if (!this.viewModel.setWebPortValue(raw)) {
              this.showPortError(WebPortError.invalid);
            }
          }
        })
      ]
    })
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  portContent() {
    Column({ space: DesignTokens.space.sm }) {
      TextInput({ text: this.pendingPort })
        .type(InputType.Number)
        .borderRadius(DesignTokens.radius.max)
        .id('settings_web_port_input')
        .onChange((value: string) => {
          this.pendingPort = value;
        })
    }
    .width('100%')
  }

  private closeActiveDialog(): void {
    if (this.activeDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.activeDialogId);
      this.activeDialogId = -1;
    }
  }

  // ── 网络接口多选弹窗 ──

  // 当前可配置的网页接口：具备可用 IPv4，同一接口多 IP 只保留一行
  private buildSheetInterfaces(): Array<NetworkInterface> {
    let sorted: Array<NetworkInterface> = networkSettingsViewModel.sortInterfaces(
      this.viewModel.getLocalInterfacesList());
    let result: Array<NetworkInterface> = [];
    for (let i = 0; i < sorted.length; i++) {
      if (!isEligibleWebInterface(sorted[i])) {
        continue;
      }
      let exists: boolean = false;
      for (let k = 0; k < result.length; k++) {
        if (result[k].name === sorted[i].name) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        result.push(sorted[i]);
      }
    }
    return result;
  }

  private openInterfaceSheet(): void {
    // VPN/隧道接口变化不触发系统网络事件：打开前主动枚举一次
    this.viewModel.refreshLocalInterfaces();
    this.sheetInterfaces = this.buildSheetInterfaces();
    this.localWhitelist = this.viewModel.webInterfaceNames.slice();
    this.localBlacklist = this.viewModel.webInterfaceBlacklistNames.slice();
    this.isShowInterfaceSheet = true;
  }

  // 判断接口当前是否启用：黑名单优先，其次白名单，两者都未列出时按类型取默认
  private isInterfaceEnabled(name: string, type: NetworkType): boolean {
    return networkSettingsViewModel.isInterfaceEnabled(name, type, this.localWhitelist, this.localBlacklist);
  }

  // 开关与 LocalSend 同口径：开=从黑名单移除并写白名单；关=从白名单移除并写黑名单
  private setInterfaceEnabled(name: string, enabled: boolean): void {
    if (enabled) {
      this.localBlacklist = networkSettingsViewModel.removeFromList(this.localBlacklist, name);
      if (!networkSettingsViewModel.isInList(name, this.localWhitelist)) {
        this.localWhitelist.push(name);
      }
    } else {
      this.localWhitelist = networkSettingsViewModel.removeFromList(this.localWhitelist, name);
      if (!networkSettingsViewModel.isInList(name, this.localBlacklist)) {
        this.localBlacklist.push(name);
      }
    }
  }

  // 刷新接口列表：保留弹窗内未保存的白/黑名单，新接口按类型取默认
  private refreshWebInterfaces(): void {
    this.viewModel.refreshLocalInterfaces();
    this.sheetInterfaces = this.buildSheetInterfaces();
  }

  private enabledInterfaceCount(): number {
    let count: number = 0;
    for (let i = 0; i < this.sheetInterfaces.length; i++) {
      if (this.isInterfaceEnabled(this.sheetInterfaces[i].name, this.sheetInterfaces[i].type)) {
        count++;
      }
    }
    return count;
  }

  // 按生效状态比较（忽略默认项是否被显式写进白/黑名单）
  private hasUnsavedInterfaceChanges(): boolean {
    for (let i = 0; i < this.sheetInterfaces.length; i++) {
      let netIf = this.sheetInterfaces[i];
      let current: boolean = this.isInterfaceEnabled(netIf.name, netIf.type);
      let saved: boolean = networkSettingsViewModel.isInterfaceEnabled(netIf.name, netIf.type,
        this.viewModel.webInterfaceNames, this.viewModel.webInterfaceBlacklistNames);
      if (current !== saved) {
        return true;
      }
    }
    return false;
  }

  @Builder
  interfaceSheetBuilder() {
    Column() {
      // 接口列表卡片（与 LocalSend 网络接口弹窗同款布局）
      if (this.sheetInterfaces.length === 0) {
        EmptyState({
          mainText: $r('app.string.network_interface_empty'),
          useCard: true
        })
      } else {
        Column() {
          ForEach(this.sheetInterfaces, (netIf: NetworkInterface, index: number) => {
            Column() {
              Row({ space: DesignTokens.space.sm }) {
                // 网络类型图标
                SymbolGlyph(networkTypeSymbol(netIf.type))
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

                    // 默认网络徽标只对启用的接口展示，与开关状态保持同口径
                    if (netIf.isDefault && this.isInterfaceEnabled(netIf.name, netIf.type)) {
                      Text($r('app.string.network_default_indicator'))
                        .fontSize(DesignTokens.font.captionM)
                        .fontColor($r('app.color.accent_blue'))
                    }
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.isInterfaceEnabled(netIf.name, netIf.type) })
                  .onChange((isOn: boolean) => {
                    this.setInterfaceEnabled(netIf.name, isOn);
                  })
                  .id('settings_web_interface_toggle')
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

              if (index < this.sheetInterfaces.length - 1) {
                Divider().color($r('app.color.border_light'))
              }
            }
            .width('100%')
          }, (netIf: NetworkInterface) => netIf.name + netIf.ip)
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
          this.refreshWebInterfaces();
        })
        .id('settings_web_interface_refresh_btn')

      Button($r('app.string.save'))
        .width('100%')
        .height(DesignTokens.size.thumbSm)
        .type(ButtonType.Normal)
        .backgroundColor($r('app.color.accent_blue'))
        .fontColor($r('app.color.text_on_color'))
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.md })
        .onClick(() => {
          if (this.sheetInterfaces.length > 0 && this.enabledInterfaceCount() === 0) {
            this.getUIContext().getPromptAction().showToast({
              message: $r('app.string.web_interface_none'),
              duration: 2000
            });
            return;
          }
          this.viewModel.setWebInterfacesValue(this.localWhitelist, this.localBlacklist);
          this.isShowInterfaceSheet = false;
        })
        .id('settings_web_interface_save_btn')
    }
    .width('100%')
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
  }

  // ── 行内展示文案 ──

  private portDescText(): ResourceStr {
    if (!this.viewModel.webPortFallback || this.viewModel.webActualPort <= 0) {
      return $r('app.string.web_port_desc');
    }
    return getStringSync(this.getUIContext(), $r('app.string.web_port_fallback_value'))
      .replace('%d', String(this.viewModel.webActualPort))
      .replace('%d', String(this.viewModel.webPort));
  }

  build() {
    Column() {
      // 卡片（标题由设置分组统一渲染）
      Column() {
        // 网页发送允许开关：关闭时撤下已挂载的分享文件（进行中下载先确认）
        Row() {
          Text($r('app.string.web_send_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.viewModel.webSendAllowed })
            .onChange((isOn: boolean) => {
              this.viewModel.setWebSendAllowedValue(isOn);
            })
            .id('settings_web_send_toggle')
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.web_send_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })

        // 网页接收允许开关：关闭时关闭浏览器上传入口（进行中上传先确认）
        Row() {
          Text($r('app.string.web_receive_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.viewModel.webReceiveAllowed })
            .onChange((isOn: boolean) => {
              this.viewModel.setWebReceiveAllowedValue(isOn);
            })
            .id('settings_web_receive_toggle')
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.web_receive_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })

        // 访问密码：留空表示不启用
        Row() {
          Text($r('app.string.web_pin_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Row({ space: DesignTokens.space.xxs }) {
            Text(this.viewModel.webPin.length > 0 ? '****' : $r('app.string.pin_set_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
            SymbolGlyph($r('sys.symbol.chevron_forward'))
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor([$r('app.color.text_secondary')])
          }
          .justifyContent(FlexAlign.End)
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.openPinDialog();
        })
        .id('settings_web_pin_entry')

        Text($r('app.string.web_pin_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })

        // 高级设置（可展开列表：点击标题行展开/收起）
        Row() {
          Text($r('app.string.advanced_settings_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          SymbolGlyph(this.isAdvancedExpanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.subtitleL)
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
        .id('settings_web_advanced_entry')

        if (this.isAdvancedExpanded) {
          // 加密传输：独立于 LocalSend 的加密传输
          Row() {
            Text($r('app.string.web_https_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.viewModel.webHttpsEnabled })
              .onChange((isOn: boolean) => {
                this.viewModel.setWebHttpsEnabledValue(isOn);
              })
              .id('settings_web_https_toggle')
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)

          Text($r('app.string.web_https_desc'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .alignSelf(ItemAlign.Start)
            .margin({ bottom: DesignTokens.space.tiny })

          // 端口：默认 53310，可自定义；被占用时回退临时端口并提示
          Row() {
            Text($r('app.string.web_port_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Row({ space: DesignTokens.space.xxs }) {
              Text(String(this.viewModel.webPort))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_tertiary'))
              SymbolGlyph($r('sys.symbol.chevron_forward'))
                .fontSize(DesignTokens.font.subtitleL)
                .fontColor([$r('app.color.text_secondary')])
            }
            .justifyContent(FlexAlign.End)
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openPortDialog();
          })
          .id('settings_web_port_entry')

          Text(this.portDescText())
            .fontSize(DesignTokens.font.bodyS)
            .fontColor(this.viewModel.webPortFallback ? $r('app.color.warning_orange') :
              $r('app.color.text_secondary'))
            .alignSelf(ItemAlign.Start)
            .margin({ bottom: DesignTokens.space.tiny })

          // 网络接口：多选，只影响地址展示
          Row() {
            Text($r('app.string.web_interface_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            SymbolGlyph($r('sys.symbol.chevron_forward'))
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor([$r('app.color.text_secondary')])
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openInterfaceSheet();
          })
          .id('settings_web_interface_entry')
        }
      }
      .width('100%')
      .padding({
        left: DesignTokens.space.lg,
        right: DesignTokens.space.lg,
        top: DesignTokens.space.md,
        bottom: DesignTokens.space.md
      })
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      .margin({ top: DesignTokens.space.sm })
    }
    .width('100%')
    .bindSheet($$this.isShowInterfaceSheet, this.interfaceSheetBuilder(), {
      height: SheetSize.FIT_CONTENT,
      width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
      preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
      blurStyle: BlurStyle.Regular,
      title: {
        title: $r('app.string.web_interface_label'),
        subtitle: $r('app.string.web_interface_desc')
      },
      showClose: true,
      onWillDismiss: (dismissSheetAction: DismissSheetAction) => {
        if (this.hasUnsavedInterfaceChanges()) {
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
                dismissSheetAction.dismiss();
              }
            }
          });
        } else {
          dismissSheetAction.dismiss();
        }
      }
    })
  }
}
