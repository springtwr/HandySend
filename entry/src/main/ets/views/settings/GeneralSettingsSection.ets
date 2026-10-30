import { DesignTokens } from '../../common/DesignTokens';
import { SettingsViewModel } from '../../viewmodel/SettingsViewModel';
import { getSystemDeviceName } from '../../utils/AliasGenerator';
import { CustomContentDialogV2, AdvancedDialogV2Button, promptAction } from '@kit.ArkUI';

// 通用（接收与发送）分区：设备名称 / 允许后台接收 / 保存到相册 / 自动清空选中文件 / 通知与「设备发现和连接」权限。
// 本分区是设置页首张卡片，不渲染分组标题，卡片内容直接作为内容区首元素。
@ComponentV2
export struct GeneralSettingsSection {
  @Require @Param viewModel: SettingsViewModel
  // 设备名称输入弹窗（B 类 CustomContentDialogV2）状态
  @Local inputDialogTitle: string = ''
  @Local inputDialogValue: string = ''
  // 输入确认回调（打开弹窗时暂存，确认时执行）
  private inputDialogCallback: (value: string) => void = (_value: string) => {
  }
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1

  private getDefaultAlias(): string {
    return getSystemDeviceName();
  }

  private showAliasDialog(): void {
    this.openInputDialog($r('app.string.input_alias_title'), this.viewModel.customAlias, (value: string) => {
      this.viewModel.setAlias(value);
    });
  }

  // ── DialogV2 弹窗：通用输入（B 类 CustomContentDialogV2） ──

  private openInputDialog(title: ResourceStr, defaultValue: string, callback: (value: string) => void): void {
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

      // 允许后台接收：仅控制无传输时的 5 分钟空闲保活，传输中始终保活
      Row() {
        Text($r('app.string.background_receive_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.backgroundReceive })
          .onChange((isOn: boolean) => {
            this.viewModel.setBackgroundReceiveValue(isOn);
          })
          .id('settings_background_receive_toggle')
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.background_receive_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: DesignTokens.space.tiny })

      // 保存到相册
      Row() {
        Text($r('app.string.save_to_gallery_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.saveToGallery })
          .onChange((isOn: boolean) => {
            this.viewModel.setGallerySaveEnabled(isOn);
          })
          .id('settings_gallery_save_toggle')
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.save_to_gallery_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: DesignTokens.space.tiny })

      // 自动清空选中文件
      Row() {
        Text($r('app.string.auto_clear_staged_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.autoClearStaged })
          .onChange((isOn: boolean) => {
            this.viewModel.setAutoClearStagedAfterSendEnabled(isOn);
          })
          .id('settings_auto_clear_staged_toggle')
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.auto_clear_staged_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: DesignTokens.space.tiny })

      // 通知权限：展示系统授权状态，未开启时点击申请，被拒后引导到系统通知设置
      Row() {
        Text($r('app.string.permission_notification_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Row({ space: DesignTokens.space.xxs }) {
          Text(this.viewModel.notificationGranted ? $r('app.string.permission_status_granted') :
            $r('app.string.permission_status_not_granted'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor(this.viewModel.notificationGranted ? $r('app.color.text_tertiary') :
              $r('app.color.warning_orange'))

          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.subtitleL)
            .fontColor([$r('app.color.text_secondary')])
        }
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.viewModel.applyNotificationPermission();
      })
      .id('settings_notification_permission_entry')

      Text($r('app.string.permission_notification_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: DesignTokens.space.tiny })

      // 设备发现和连接（蓝牙权限）：展示系统授权状态，未授予时点击申请，被拒后引导到系统权限设置，
      // 已授予时跳转系统设置的本应用详情页以便关闭
      Row() {
        Text($r('app.string.permission_bluetooth_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Row({ space: DesignTokens.space.xxs }) {
          Text(this.viewModel.bluetoothGranted ? $r('app.string.permission_status_granted') :
            $r('app.string.permission_status_not_granted'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor(this.viewModel.bluetoothGranted ? $r('app.color.text_tertiary') :
              $r('app.color.warning_orange'))

          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.subtitleL)
            .fontColor([$r('app.color.text_secondary')])
        }
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.viewModel.applyBluetoothPermission();
      })
      .id('settings_bluetooth_permission_entry')

      Text($r('app.string.permission_bluetooth_check_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
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
    .borderRadius(DesignTokens.radius.lg)
    .backgroundColor($r('app.color.card_background'))
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })

    // 本卡片是设置页首元素，不设顶部外边距：顶部间距由页内容器统一提供
  }
}
