import { DesignTokens } from '../../common/DesignTokens';
import { SettingsViewModel } from '../../viewmodel/SettingsViewModel';

// 通用（接收与发送）分区：自动完成 / 保存到相册 / 保存到历史 / 自动清空选中文件。
// 标题由设置分组统一渲染，本分区只提供卡片内容。
@ComponentV2
export struct GeneralSettingsSection {
  @Require @Param viewModel: SettingsViewModel

  build() {
    Column() {
      // 自动完成
      Row() {
        Text($r('app.string.auto_finish_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.autoFinish })
          .onChange((isOn: boolean) => {
            this.viewModel.setAutoFinishEnabled(isOn);
          })
          .id('settings_auto_finish_toggle')
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.auto_finish_desc'))
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

      // 保存到历史
      Row() {
        Text($r('app.string.save_to_history_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.saveToHistory })
          .onChange((isOn: boolean) => {
            this.viewModel.setHistorySaveEnabled(isOn);
          })
          .id('settings_history_save_toggle')
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.save_to_history_desc'))
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

        Row({ space: DesignTokens.space.tiny }) {
          Text(this.viewModel.notificationGranted ? $r('app.string.permission_status_granted') :
            $r('app.string.permission_status_not_granted'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor(this.viewModel.notificationGranted ? $r('app.color.text_tertiary') :
              $r('app.color.warning_orange'))

          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.titleS)
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

      // 蓝牙权限：展示系统授权状态，未授予时点击申请，被拒后引导到系统权限设置
      Row() {
        Text($r('app.string.permission_bluetooth_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Row({ space: DesignTokens.space.tiny }) {
          Text(this.viewModel.bluetoothGranted ? $r('app.string.permission_status_granted') :
            $r('app.string.permission_status_not_granted'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor(this.viewModel.bluetoothGranted ? $r('app.color.text_tertiary') :
              $r('app.color.warning_orange'))

          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.titleS)
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
    .margin({ top: DesignTokens.space.sm })
  }
}
