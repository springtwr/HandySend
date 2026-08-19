import { common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';
import { DialogService } from '../service/DialogService';
import { getLanguageDisplayName } from '../utils/LanguageUtil';
import { SettingsViewModel } from '../viewmodel/SettingsViewModel';
import { ReceiveSettingsSection } from '../views/settings/ReceiveSettingsSection';
import { AppearanceSettingsSection } from '../views/settings/AppearanceSettingsSection';
import { NetworkSettingsSection } from '../views/settings/NetworkSettingsSection';

@ComponentV2
export struct SettingsContent {
  @Local viewModel: SettingsViewModel = new SettingsViewModel();
  @Local isShowSheet: boolean = false
  @Local sheetMode: string = '' // '' | 'feedback' | 'about'
  @Event onScrollDelta: (deltaY: number, absY: number) => void = (_deltaY: number, _absY: number) => {}
  private scroller: Scroller = new Scroller()


  aboutToAppear(): void {
    this.viewModel.loadInitialData();
    this.viewModel.subscribe();

    // Apply saved theme color mode on appear
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let appCtx = context.getApplicationContext();
      if (this.viewModel.theme === 'light') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (this.viewModel.theme === 'dark') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (_e) {
      // Ignore if context not available
    }
  }

  aboutToDisappear(): void {
    this.viewModel.unsubscribe();
  }


  @Builder
  sheetContentBuilder(): void {
    if (this.sheetMode === 'feedback') {
      this.feedbackSheetBuilder();
    } else if (this.sheetMode === 'about') {
      this.aboutSheetBuilder();
    }
  }

  @Builder
  feedbackSheetBuilder(): void {
    Column() {
      Text($r('app.string.feedback_desc'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: DesignTokens.space.xl, bottom: DesignTokens.space.lg })

      Button($r('app.string.feedback_appgallery'))
        .width('100%')
        .height(DesignTokens.hotspot.minSize)
        .type(ButtonType.Normal)
        .backgroundColor($r('app.color.accent_blue'))
        .fontColor($r('app.color.text_on_color'))
        .borderRadius(DesignTokens.radius.md)
        .onClick(() => {
          let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          let bundleName = context.abilityInfo.bundleName;
          let deepLink = `store://appgallery.huawei.com/app/detail?id=${bundleName}&action=write-review`;
          let want: Want = {
            action: 'ohos.want.action.appdetail',
            uri: deepLink
          };
          context.startAbility(want).catch((_e: BusinessError) => {
            // AppGallery may not be available (e.g. on emulator)
          });
        })

      Button($r('app.string.feedback_repo'))
        .width('100%')
        .height(DesignTokens.hotspot.minSize)
        .type(ButtonType.Normal)
        .backgroundColor($r('app.color.page_background'))
        .fontColor($r('app.color.text_primary'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.xl })
        .onClick(() => {
          let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          context.openLink('https://gitcode.com/springtwr/HandySend/issues').catch((_e: Object) => {
            // Browser may not be available
          });
        })
    }
    .padding({ left: DesignTokens.space.lg, right: DesignTokens.space.lg })
  }

  @Builder
  aboutSheetBuilder(): void {
    Column() {
      Text($r('app.string.about_description'))
        .fontSize(DesignTokens.font.subtitleM)
        .fontColor($r('app.color.text_primary'))
        .lineHeight(22)
        .width('100%')
        .margin({ top: DesignTokens.space.xl, bottom: DesignTokens.space.lg })

      // Version info card
      Column() {
        Row() {
          Text($r('app.string.about_handysend_version'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          Text(this.viewModel.handySendVersion)
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Medium)
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)

        Divider().color($r('app.color.border_light'))

        Row() {
          Text($r('app.string.about_localsend_version'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          Text(this.viewModel.localsendVersion)
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Medium)
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)

        Divider().color($r('app.color.border_light'))

        Row() {
          Text($r('app.string.about_protocol_version'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          Text('v' + this.viewModel.protocolVersion)
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Medium)
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding(DesignTokens.space.lg)
      .borderRadius(DesignTokens.radius.lg)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: 1, color: $r('app.color.border_light') })

      // Repository URLs card
      Column() {
        Column() {
          Text($r('app.string.about_project_url_title'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ bottom: DesignTokens.space.xs })

          Text('https://gitcode.com/springtwr/HandySend')
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.ip_blue_text'))
            .fontWeight(FontWeight.Medium)
            .padding(DesignTokens.space.sm)
            .width('100%')
            .backgroundColor($r('app.color.accent_blue_bg'))
            .borderRadius(DesignTokens.radius.md)
            .onClick(() => {
              let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
              context.openLink('https://gitcode.com/springtwr/HandySend').catch((_e: Object) => {});
            })
        }
        .width('100%')

        Divider().color($r('app.color.border_light'))
          .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.md })

        Column() {
          Text($r('app.string.about_localsend_url_title'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ bottom: DesignTokens.space.xs })

          Text('https://github.com/localsend/localsend')
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.ip_blue_text'))
            .fontWeight(FontWeight.Medium)
            .padding(DesignTokens.space.sm)
            .width('100%')
            .backgroundColor($r('app.color.accent_blue_bg'))
            .borderRadius(DesignTokens.radius.md)
            .onClick(() => {
              let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
              context.openLink('https://github.com/localsend/localsend').catch((_e: Object) => {});
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(DesignTokens.space.lg)
      .borderRadius(DesignTokens.radius.lg)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: 1, color: $r('app.color.border_light') })
      .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.xl })
    }
    .padding({ left: DesignTokens.space.lg, right: DesignTokens.space.lg })
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // ── Receive settings section ──
          ReceiveSettingsSection({ viewModel: this.viewModel })

        // ── Appearance settings ──
          AppearanceSettingsSection({ viewModel: this.viewModel })

        // ── Server restart warning banner ──
          NetworkSettingsSection({ viewModel: this.viewModel })

        // ── Debug log toggle ──
        Column() {
          Row() {
            Column() {
              Text($r('app.string.debug_log_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
              Text($r('app.string.debug_log_desc'))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.viewModel.debugLogEnabled })
              .selectedColor($r('app.color.accent_blue'))
              .onChange((isOn: boolean) => {
                this.viewModel.setDebugLogEnabled(isOn);
              })
          }
          .width('100%')
          .padding({ top: DesignTokens.space.md, bottom: DesignTokens.space.md })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
        }
        .padding(DesignTokens.space.lg)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.md })

        // ── About ──
        Column() {
          Text($r('app.string.about_title'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .alignSelf(ItemAlign.Start)

          Row() {
            Text($r('app.string.feedback_title'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Text('\u203A')
              .fontSize(DesignTokens.font.titleS)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: DesignTokens.space.md, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.sheetMode = 'feedback';
            this.isShowSheet = true;
          })

          Row() {
            Text($r('app.string.about_card_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Text('\u203A')
              .fontSize(DesignTokens.font.titleS)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.sheetMode = 'about';
            this.isShowSheet = true;
          })
        }
        .padding(DesignTokens.space.lg)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.xl })
        .bindSheet($$this.isShowSheet, this.sheetContentBuilder(), { height: SheetSize.FIT_CONTENT, showClose: false })
      }
      .width('100%')
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: 80 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onDidScroll((_xOffset: number, yOffset: number) => {
      let offset = this.scroller.currentOffset();
      this.onScrollDelta(yOffset, offset.yOffset);
    })
    .onScrollEdge((edge: Edge) => {
      if (edge === Edge.Top) {
        this.onScrollDelta(-999, 0);
      }
    })
  }
}
