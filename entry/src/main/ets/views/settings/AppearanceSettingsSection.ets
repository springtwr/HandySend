import {
  ConfigurationConstant, common
} from '@kit.AbilityKit';
import {
  DesignTokens
} from '../../common/DesignTokens';
import {
  getLanguageDisplayName
} from '../../utils/LanguageUtil';
import {
  SettingsViewModel
} from '../../viewmodel/SettingsViewModel';

// 外观设置分组（主题/动画/语言，从 SettingsContent 拆出）。
@Component
export struct AppearanceSettingsSection {
  @ObjectLink viewModel: SettingsViewModel

  build() {
Column() {
  Text($r('app.string.appearance_settings'))
    .fontSize(DesignTokens.font.subtitleM)
    .fontWeight(FontWeight.Medium)
    .fontColor($r('app.color.text_primary'))
    .alignSelf(ItemAlign.Start)

  // Theme mode
  Row() {
    Text($r('app.string.theme_label'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
  .alignItems(VerticalAlign.Center)

  Row({ space: 0 }) {
    Row() {
      Text($r('app.string.theme_light'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor(this.viewModel.theme === 'light' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
        .fontWeight(this.viewModel.theme === 'light' ? FontWeight.Bold : FontWeight.Normal)
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ top: 8, bottom: 8 })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .backgroundColor(this.viewModel.theme === 'light' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
    .borderRadius({ topLeft: DesignTokens.radius.md, bottomLeft: DesignTokens.radius.md })
    .onClick(() => {
      this.viewModel.setThemeMode('light');
      this.viewModel.setThemeMode('light');
      try {
        let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } catch (_e) {}
    })

    Row() {
      Text($r('app.string.theme_dark'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor(this.viewModel.theme === 'dark' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
        .fontWeight(this.viewModel.theme === 'dark' ? FontWeight.Bold : FontWeight.Normal)
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ top: 8, bottom: 8 })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .backgroundColor(this.viewModel.theme === 'dark' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
    .onClick(() => {
      this.viewModel.setThemeMode('dark');
      this.viewModel.setThemeMode('dark');
      try {
        let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } catch (_e) {}
    })

    Row() {
      Text($r('app.string.theme_system'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor(this.viewModel.theme === 'system' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
        .fontWeight(this.viewModel.theme === 'system' ? FontWeight.Bold : FontWeight.Normal)
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ top: 8, bottom: 8 })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .backgroundColor(this.viewModel.theme === 'system' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
    .borderRadius({ topRight: DesignTokens.radius.md, bottomRight: DesignTokens.radius.md })
    .onClick(() => {
      this.viewModel.setThemeMode('system');
      this.viewModel.setThemeMode('system');
      try {
        let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      } catch (_e) {}
    })
  }
  .width('100%')

  // Animations toggle
  Row() {
    Text($r('app.string.animations_label'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Toggle({ type: ToggleType.Switch, isOn: this.viewModel.enableAnimations })
      .onChange((isOn: boolean) => {
        this.viewModel.setAnimationsEnabled(isOn);
        this.viewModel.setAnimationsEnabled(isOn);
      })
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)

  Text($r('app.string.animations_desc'))
    .fontSize(DesignTokens.font.bodyS)
    .fontColor($r('app.color.text_secondary'))
    .margin({ bottom: DesignTokens.space.xs })

  // Language selection entry
  Row() {
    Text($r('app.string.language_label'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Row() {
      Text(this.viewModel.locale.length === 0 ? $r('app.string.language_system') : getLanguageDisplayName(this.viewModel.locale))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_tertiary'))
      Text('›')
        .fontSize(DesignTokens.font.subtitleL)
        .fontColor($r('app.color.text_secondary'))
        .margin({ left: DesignTokens.space.xs })
    }
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)
  .onClick(() => {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/LanguagePage' });
  })
}
.padding(DesignTokens.space.lg)
.borderRadius(DesignTokens.radius.lg)
.backgroundColor($r('app.color.card_background'))
.border({ width: 1, color: $r('app.color.border_light') })
.margin({ top: DesignTokens.space.md })

  }
}
