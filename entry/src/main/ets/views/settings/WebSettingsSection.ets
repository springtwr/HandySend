import { DesignTokens } from '../../common/DesignTokens';
import { SettingsViewModel } from '../../viewmodel/SettingsViewModel';
import { WebAddress, WebPortError } from '../../model/WebAddress';
import { NetworkType } from '../../model/Types';
import { networkTypeLabel } from '../../utils/NetworkPresentation';
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
 * 以及网页独立的加密、访问 PIN、访问网卡与端口。
 *
 * 两方向开关与面板内启停按钮、发送页菜单勾选双向同步；
 * 加密/PIN/端口变更需要重启网页服务，有活跃网页会话时先二次确认；
 * 网卡筛选只影响地址展示，不重启服务。
 * 数据经 @Param 绑定父组件 VM，命令直调 VM（View → ViewModel）。
 */
@ComponentV2
export struct WebSettingsSection {
  @Require @Param viewModel: SettingsViewModel
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local private isShowInterfaceSheet: boolean = false
  @Local private sheetAddresses: Array<WebAddress> = []
  @Local private selectedInterfaceNames: Array<string> = []
  @Local private pendingPin: string = ''
  @Local private pendingPort: string = ''
  private activeDialogId: number = -1

  // ── PIN 弹窗 ──

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

  // ── 网卡多选弹窗 ──

  private openInterfaceSheet(): void {
    let all: Array<WebAddress> = this.viewModel.getAllWebAddresses();
    // 设置页按接口名多选：同一网卡多 IP 只展示一行，避免重复开关
    let unique: Array<WebAddress> = [];
    for (let i = 0; i < all.length; i++) {
      let exists: boolean = false;
      for (let k = 0; k < unique.length; k++) {
        if (unique[k].name === all[i].name) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        unique.push(all[i]);
      }
    }
    this.sheetAddresses = unique;
    let saved: Array<string> = this.viewModel.webInterfaceNames;
    if (saved.length === 0) {
      this.selectedInterfaceNames = this.allSheetNames();
    } else {
      let selected: Array<string> = [];
      for (let i = 0; i < this.sheetAddresses.length; i++) {
        if (saved.indexOf(this.sheetAddresses[i].name) >= 0) {
          selected.push(this.sheetAddresses[i].name);
        }
      }
      this.selectedInterfaceNames = selected.length > 0 ? selected : this.allSheetNames();
    }
    this.isShowInterfaceSheet = true;
  }

  private allSheetNames(): Array<string> {
    let names: Array<string> = [];
    for (let i = 0; i < this.sheetAddresses.length; i++) {
      names.push(this.sheetAddresses[i].name);
    }
    return names;
  }

  private isInterfaceSelected(name: string): boolean {
    return this.selectedInterfaceNames.indexOf(name) >= 0;
  }

  private setInterfaceSelected(name: string, selected: boolean): void {
    let next: Array<string> = [];
    for (let i = 0; i < this.selectedInterfaceNames.length; i++) {
      if (this.selectedInterfaceNames[i] !== name) {
        next.push(this.selectedInterfaceNames[i]);
      }
    }
    if (selected) {
      next.push(name);
    }
    this.selectedInterfaceNames = next;
  }

  private interfaceLabel(type: NetworkType): string {
    let label: ResourceStr = networkTypeLabel(type);
    return typeof label === 'string' ? label : getStringSync(this.getUIContext(), label);
  }

  @Builder
  interfaceSheetBuilder() {
    Column() {
      if (this.sheetAddresses.length === 0) {
        EmptyState({
          mainText: $r('app.string.network_interface_empty'),
          useCard: true
        })
      } else {
        Column() {
          ForEach(this.sheetAddresses, (address: WebAddress, index: number) => {
            Column() {
              Row({ space: DesignTokens.space.sm }) {
                Column({ space: 2 }) {
                  Text(address.name.length > 0 ? address.name : address.ip)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor($r('app.color.text_primary'))
                    .fontWeight(FontWeight.Medium)
                  Text(address.ip + ' · ' + this.interfaceLabel(address.type))
                    .fontSize(DesignTokens.font.captionM)
                    .fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.isInterfaceSelected(address.name) })
                  .onChange((isOn: boolean) => {
                    this.setInterfaceSelected(address.name, isOn);
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

              if (index < this.sheetAddresses.length - 1) {
                Divider().color($r('app.color.border_light'))
              }
            }
            .width('100%')
          }, (address: WebAddress) => address.name + address.ip)
        }
        .width('100%')
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(DesignTokens.radius.lg)
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      }

      Button($r('app.string.save'))
        .width('100%')
        .height(DesignTokens.size.thumbSm)
        .type(ButtonType.Normal)
        .backgroundColor($r('app.color.accent_blue'))
        .fontColor($r('app.color.text_on_color'))
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.md })
        .onClick(() => {
          if (this.selectedInterfaceNames.length === 0) {
            this.getUIContext().getPromptAction().showToast({
              message: $r('app.string.web_interface_none'),
              duration: 2000
            });
            return;
          }
          // 全部选中时存空数组，表示不限制（新插入的网卡也会自动纳入）
          if (this.selectedInterfaceNames.length === this.sheetAddresses.length) {
            this.viewModel.setWebInterfacesValue([]);
          } else {
            this.viewModel.setWebInterfacesValue(this.selectedInterfaceNames);
          }
          this.isShowInterfaceSheet = false;
        })
        .id('settings_web_interface_save_btn')
    }
    .width('100%')
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
  }

  // ── 行内展示文案 ──

  private interfaceValueText(): string {
    let names: Array<string> = this.viewModel.webInterfaceNames;
    if (names.length === 0) {
      return getStringSync(this.getUIContext(), $r('app.string.web_interface_all'));
    }
    return getStringSync(this.getUIContext(), $r('app.string.web_interface_selected_count'))
      .replace('%d', String(names.length));
  }

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

        // 网页加密：独立于 LocalSend 的加密传输
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

        // 网页访问 PIN：留空表示不启用
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

        // 网页访问网卡：多选，只影响地址展示
        Row() {
          Text($r('app.string.web_interface_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Row({ space: DesignTokens.space.xxs }) {
            Text(this.interfaceValueText())
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
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
          this.openInterfaceSheet();
        })
        .id('settings_web_interface_entry')

        Text($r('app.string.web_interface_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })

        // 网页端口：默认 53310，可自定义；被占用时回退并提示
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
      height: SheetSize.MEDIUM,
      width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
      preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
      blurStyle: BlurStyle.Regular,
      title: {
        title: $r('app.string.web_interface_label'),
        subtitle: ''
      },
      showClose: true
    })
  }
}
