import {
  DialogService
} from '../../service/DialogService';
import {
  DesignTokens
} from '../../common/DesignTokens';
import {
  SettingsViewModel
} from '../../viewmodel/SettingsViewModel';

// 接收与分享设置分组（从 SettingsContent 拆出）。
// 数据经 @Param 绑定父组件 VM，命令直调 VM（View → ViewModel）。
@ComponentV2
export struct ReceiveSettingsSection {
  @Require @Param viewModel: SettingsViewModel

  build() {
    Column() {
Column() {
  Text($r('app.string.receive_settings'))
    .fontSize(DesignTokens.font.subtitleM)
    .fontWeight(FontWeight.Medium)
    .fontColor($r('app.color.text_primary'))
    .alignSelf(ItemAlign.Start)

  // 自动保存三段式选择器
  Row() {
    Text($r('app.string.auto_save_title'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
  .alignItems(VerticalAlign.Center)

  Row({ space: 0 }) {
    Row() {
      Text($r('app.string.auto_save_off'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor(this.viewModel.autoSaveMode === 'off' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
        .fontWeight(this.viewModel.autoSaveMode === 'off' ? FontWeight.Bold : FontWeight.Normal)
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ top: 8, bottom: 8 })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .backgroundColor(this.viewModel.autoSaveMode === 'off' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
    .borderRadius({ topLeft: DesignTokens.radius.md, bottomLeft: DesignTokens.radius.md })
    .onClick(() => {
      this.viewModel.setAutoSaveMode('off');
      this.viewModel.setAutoSaveMode('off');
    })

    Row() {
      Text($r('app.string.auto_save_favorites'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor(this.viewModel.autoSaveMode === 'paired' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
        .fontWeight(this.viewModel.autoSaveMode === 'paired' ? FontWeight.Bold : FontWeight.Normal)
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ top: 8, bottom: 8 })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .backgroundColor(this.viewModel.autoSaveMode === 'paired' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
    .onClick(() => {
      if (this.viewModel.autoSaveMode !== 'paired') {
        DialogService.showAutoSaveWarning($r('app.string.auto_save_paired_warning'), () => {
          this.viewModel.setAutoSaveMode('paired');
          this.viewModel.setAutoSaveMode('paired');
        });
      }
    })

    Row() {
      Text($r('app.string.auto_save_on'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor(this.viewModel.autoSaveMode === 'on' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
        .fontWeight(this.viewModel.autoSaveMode === 'on' ? FontWeight.Bold : FontWeight.Normal)
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ top: 8, bottom: 8 })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .backgroundColor(this.viewModel.autoSaveMode === 'on' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
    .borderRadius({ topRight: DesignTokens.radius.md, bottomRight: DesignTokens.radius.md })
    .onClick(() => {
      if (this.viewModel.autoSaveMode !== 'on') {
        DialogService.showAutoSaveWarning($r('app.string.auto_save_on_warning'), () => {
          this.viewModel.setAutoSaveMode('on');
          this.viewModel.setAutoSaveMode('on');
        });
      }
    })
  }
  .width('100%')

  // PIN
  Row() {
    Text($r('app.string.receive_pin_label'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    if (this.viewModel.receivePin.length > 0) {
      Text('****')
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_tertiary'))
    } else {
      Text($r('app.string.pin_set_label'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_tertiary'))
    }
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)
  .onClick(() => {
    DialogService.showInputDialog($r('app.string.receive_pin_label'), this.viewModel.receivePin, (value: string) => {
      this.viewModel.setReceivePinValue(value);
    });
  })

  Text($r('app.string.receive_pin_desc'))
    .fontSize(DesignTokens.font.bodyS)
    .fontColor($r('app.color.text_secondary'))
    .margin({ bottom: DesignTokens.space.xs })

  // 自动完成
  Row() {
    Text($r('app.string.auto_finish_label'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Toggle({ type: ToggleType.Switch, isOn: this.viewModel.autoFinish })
      .onChange((isOn: boolean) => {
        this.viewModel.setAutoFinishEnabled(isOn);
        this.viewModel.setAutoFinishEnabled(isOn);
      })
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)

  Text($r('app.string.auto_finish_desc'))
    .fontSize(DesignTokens.font.bodyS)
    .fontColor($r('app.color.text_secondary'))
    .margin({ bottom: DesignTokens.space.xs })

  // 保存到相册
  Row() {
    Text($r('app.string.save_to_gallery_label'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Toggle({ type: ToggleType.Switch, isOn: this.viewModel.saveToGallery })
      .onChange((isOn: boolean) => {
        this.viewModel.setGallerySaveEnabled(isOn);
        this.viewModel.setGallerySaveEnabled(isOn);
      })
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)

  // 保存到历史
  Row() {
    Text($r('app.string.save_to_history_label'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Toggle({ type: ToggleType.Switch, isOn: this.viewModel.saveToHistory })
      .onChange((isOn: boolean) => {
        this.viewModel.setHistorySaveEnabled(isOn);
        this.viewModel.setHistorySaveEnabled(isOn);
      })
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)

  Text($r('app.string.save_to_history_desc'))
    .fontSize(DesignTokens.font.bodyS)
    .fontColor($r('app.color.text_secondary'))
    .margin({ bottom: DesignTokens.space.xs })
}
.padding(DesignTokens.space.lg)
.borderRadius(DesignTokens.radius.lg)
.backgroundColor($r('app.color.card_background'))
.border({ width: 1, color: $r('app.color.border_light') })
.margin({ top: DesignTokens.space.lg })

// ── 常规设置 ──
Column() {
  Text($r('app.string.settings_general'))
    .fontSize(DesignTokens.font.subtitleM)
    .fontWeight(FontWeight.Medium)
    .fontColor($r('app.color.text_primary'))
    .alignSelf(ItemAlign.Start)

  Row() {
    Text($r('app.string.hide_share_by_link'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Toggle({ type: ToggleType.Switch, isOn: this.viewModel.hideShareByLink })
      .onChange((isOn: boolean) => {
        this.viewModel.setHideShareByLink(isOn);
        this.viewModel.setHideShareByLink(isOn);
      })
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)

  Row() {
    Text($r('app.string.silent_receive_label'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Toggle({ type: ToggleType.Switch, isOn: this.viewModel.silentReceive })
      .onChange((isOn: boolean) => {
        this.viewModel.setSilentReceiveEnabled(isOn);
        this.viewModel.setSilentReceiveEnabled(isOn);
      })
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)


}
.padding(DesignTokens.space.lg)
.borderRadius(DesignTokens.radius.lg)
.backgroundColor($r('app.color.card_background'))
.border({ width: 1, color: $r('app.color.border_light') })
.margin({ top: DesignTokens.space.md })

    }
    .width('100%')
  }
}
