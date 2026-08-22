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
import {
  LANGUAGE_LIST, LanguageOption
} from '../../common/LanguageConstants';
import { TabSegmentButtonV2, SegmentButtonV2Items } from '@ohos.arkui.advanced.SegmentButtonV2';

// 主题模式枚举固定顺序：与 segmentedItems 下标一一对应
const THEME_VALUES: Array<string> = ['light', 'dark', 'system'];

// 外观设置分组（主题/动画/语言，从 SettingsContent 拆出）。
@ComponentV2
export struct AppearanceSettingsSection {
  @Require @Param viewModel: SettingsViewModel
  @Local isShowLanguageSheet: boolean = false

  // 官方分段按钮（TabSegmentButtonV2）：主题模式三选一（浅色 / 深色 / 系统）
  private segmentedItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: $r('app.string.theme_light') },
    { text: $r('app.string.theme_dark') },
    { text: $r('app.string.theme_system') }
  ]);

  // 当前主题对应的分段下标
  private getThemeIndex(): number {
    for (let i = 0; i < THEME_VALUES.length; i++) {
      if (THEME_VALUES[i] === this.viewModel.theme) {
        return i;
      }
    }
    return 2; // 默认 system
  }

  // 切换主题：仅在新值与当前值不同时生效，避免初始化回灌时重复调用系统 API
  private applyTheme(index: number): void {
    let next = THEME_VALUES[index];
    if (next === this.viewModel.theme) {
      return;
    }
    this.viewModel.setThemeMode(next);
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (next === 'light') {
        context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (next === 'dark') {
        context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (_e) {
    }
  }

  // 语言半屏弹窗：系统标题 + 卡片列表，选中项仅文字高亮
  @Builder
  languageSheetBuilder(): void {
    Column() {
      // 卡片容器：列表项 + Divider 分隔线（还原 LanguagePage 卡片风格）
      Column() {
        List({ space: 0 }) {
          ForEach(LANGUAGE_LIST, (item: LanguageOption, index: number) => {
            ListItem() {
              Column() {
                Row() {
                  Text(item.label)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor(
                      this.viewModel.locale === item.value ? $r('app.color.accent_blue') : $r('app.color.text_primary'))
                    .fontWeight(this.viewModel.locale === item.value ? FontWeight.Bold : FontWeight.Normal)
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({
                  left: DesignTokens.space.lg,
                  right: DesignTokens.space.lg,
                  top: 14,
                  bottom: 14
                })
                .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
                .alignItems(VerticalAlign.Center)
                .onClick(() => {
                  this.viewModel.setLocaleValue(item.value);
                  this.isShowLanguageSheet = false;
                })

                if (index < LANGUAGE_LIST.length - 1) {
                  Divider().color($r('app.color.border_light'))
                }
              }
              .width('100%')
            }
          }, (item: LanguageOption) => item.value)
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
      Text($r('app.string.appearance_settings'))
        .fontSize(DesignTokens.font.subtitleM)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .alignSelf(ItemAlign.Start)

      // 主题模式（三选一，使用官方 SegmentButton 分段控件）
      Row() {
        Text($r('app.string.theme_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
      .alignItems(VerticalAlign.Center)

      TabSegmentButtonV2({
        items: this.segmentedItems,
        selectedIndex: this.getThemeIndex(),
        $selectedIndex: (index: number) => {
          this.applyTheme(index);
        },
        enableStateAnimation: true
      })
        .width('100%')

      // 动画开关
      Row() {
        Text($r('app.string.animations_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.enableAnimations })
          .onChange((isOn: boolean) => {
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
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: DesignTokens.space.xs })

      // 滚动时隐藏页签开关
      Row() {
        Text($r('app.string.hide_tab_bar_on_scroll_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.hideTabBarOnScroll })
          .onChange((isOn: boolean) => {
            this.viewModel.setHideTabBarOnScrollEnabled(isOn);
          })
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
      .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.hide_tab_bar_on_scroll_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: DesignTokens.space.xs })

      // 语言选择入口（半屏弹窗）
      Row() {
        Text($r('app.string.language_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Row() {
          Text(this.viewModel.locale.length === 0 ? $r('app.string.language_system') :
            getLanguageDisplayName(this.viewModel.locale))
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
        this.isShowLanguageSheet = true;
      })
      .bindSheet($$this.isShowLanguageSheet, this.languageSheetBuilder(), {
        height: SheetSize.MEDIUM,
        preferType: SheetType.BOTTOM,
        width: 480,
        blurStyle: BlurStyle.Regular,
        title: {
          title: $r('app.string.language_title'),
          subtitle: ''
        },
        showClose: true,
        keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL
      })
    }
    .width('100%')
    .padding(DesignTokens.space.lg)
    .borderRadius(DesignTokens.radius.lg)
    .backgroundColor($r('app.color.card_background'))
    .border({ width: 1, color: $r('app.color.border_light') })
    .margin({ top: DesignTokens.space.md })
  }
}
