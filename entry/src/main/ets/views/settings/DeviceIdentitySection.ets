import { deviceInfo } from '@kit.BasicServicesKit';
import { getSystemDeviceName } from '../../utils/AliasGenerator';
import { DeviceTypeOption } from '../../components/settings/SettingsTypes';
import { DesignTokens } from '../../common/DesignTokens';
import { getSheetWidth, isWideWidth } from '../../common/Breakpoints';
import { SettingsViewModel } from '../../viewmodel/SettingsViewModel';
import { CustomContentDialogV2, AdvancedDialogV2Button, promptAction, uiObserver } from '@kit.ArkUI';

// 设备通用信息分区（原「网络与设备身份」中的身份部分）：别名 / 设备类型 / 设备型号。
// 标题由设置分组统一渲染，本分区只提供卡片内容。
@ComponentV2
export struct DeviceIdentitySection {
  // 系统宽度断点（随窗口尺寸变化自动刷新，设备类型半屏弹窗宽度断点化用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Require @Param viewModel: SettingsViewModel
  @Local isShowDeviceTypeSheet: boolean = false
  // 通用输入弹窗（B 类 CustomContentDialogV2）状态
  @Local inputDialogTitle: string = ''
  @Local inputDialogValue: string = ''
  // 通用输入确认回调（打开时暂存，确认时执行）
  private inputDialogCallback: (value: string) => void = (_value: string) => {
  }
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1
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
    this.openInputDialog($r('app.string.input_alias_title'), this.viewModel.customAlias, (value: string) => {
      this.viewModel.setAlias(value);
    });
  }

  private showDeviceTypeDialog(): void {
    this.isShowDeviceTypeSheet = true;
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
        .id('settings_identity_input_dialog_input')
        .onChange((value: string) => {
          this.inputDialogValue = value;
        })
    }
    .width('100%')
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
                .id('settings_device_type_option')

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
      // 设备名称，带骰子随机和系统名称按钮
      Row() {
        Text($r('app.string.input_alias_title'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        // 值区不伸展（图标 + 文本紧贴、整体靠右）：标签占剩余宽度把值区推到右端，
        // 名称超出宽度上限时截断，避免长名称把标签挤出屏幕
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
            .id('settings_alias_random_btn')

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
            .id('settings_alias_system_btn')

          Text(this.viewModel.customAlias || this.getDefaultAlias())
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '62%' })
        }
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.showAliasDialog();
      })
      .id('settings_alias_entry')

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
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

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
      .id('settings_device_type_entry')
      .bindSheet($$this.isShowDeviceTypeSheet, this.deviceTypeSheetBuilder(), {
        height: SheetSize.MEDIUM,
        width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
        // 宽屏（lg/xl）以居中弹窗呈现，窄屏保持底部弹窗（与手机行为一致）
        preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
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

    // 此处不再设顶部外边距：它原本承担「分组标题与卡片之间的间隔」，
    // 而本分组已不渲染分组标题、卡片顶部间距由页内容器统一提供；
    // 若将来恢复本分组的标题渲染，需在此恢复顶部外边距
  }
}
