import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  DesignTokens
} from '../../common/DesignTokens';
import { copyText } from '../../utils/ClipboardUtil';
import {
  SettingsViewModel
} from '../../viewmodel/SettingsViewModel';

// 更多设置分组（反馈/关于/调试日志/恢复默认）。
// 反馈/关于半屏弹窗直接绑定在本组件，各自独立。
@ComponentV2
export struct MoreSettingsSection {
  @Require @Param viewModel: SettingsViewModel
  @Local isShowFeedbackSheet: boolean = false
  @Local isShowAboutSheet: boolean = false

  @Builder
  feedbackSheetBuilder(): void {
    Column() {
      Column() {
        // 应用市场
        Row() {
          Image($r('app.media.ic_more_appgallery'))
            .width(DesignTokens.font.subtitleM)
            .height(DesignTokens.font.subtitleM)

          Text($r('app.string.feedback_appgallery'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .margin({ left: DesignTokens.space.sm })

          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.subtitleL)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width('100%')
        .padding({ left: DesignTokens.space.lg, right: DesignTokens.space.lg, top: 14, bottom: 14 })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          let bundleName = context.abilityInfo.bundleName;
          let deepLink = `store://appgallery.huawei.com/app/detail?id=${bundleName}&action=write-review`;
          let want: Want = {
            action: 'ohos.want.action.appdetail',
            uri: deepLink
          };
          context.startAbility(want).catch((_e: BusinessError) => {
            // AppGallery 可能不可用（例如在模拟器上）
          });
        })

        Divider().color($r('app.color.border_light'))

        // 代码仓库
        Row() {
          Image($r('app.media.ic_more_git'))
            .width(DesignTokens.font.subtitleM)
            .height(DesignTokens.font.subtitleM)
            .fillColor($r('app.color.text_primary'))

          Text($r('app.string.feedback_repo'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .margin({ left: DesignTokens.space.sm })

          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.subtitleL)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width('100%')
        .padding({ left: DesignTokens.space.lg, right: DesignTokens.space.lg, top: 14, bottom: 14 })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          context.openLink('https://gitcode.com/springtwr/HandySend/issues').catch((_e: Object) => {
            // 浏览器可能不可用
          });
        })
      }
      .width('100%')
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: 1, color: $r('app.color.border_light') })
    }
    .width('100%')
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
  }

  @Builder
  aboutSheetBuilder(): void {
    Column() {
      // 版本信息卡片
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
        .padding({ left: DesignTokens.space.lg, right: DesignTokens.space.lg, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
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
        .padding({ left: DesignTokens.space.lg, right: DesignTokens.space.lg, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)

        Divider().color($r('app.color.border_light'))

        Row() {
          Text($r('app.string.about_protocol_version'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          Text(this.viewModel.protocolVersion)
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Medium)
        }
        .width('100%')
        .padding({ left: DesignTokens.space.lg, right: DesignTokens.space.lg, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
        .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .borderRadius(DesignTokens.radius.lg)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: 1, color: $r('app.color.border_light') })

      // 仓库地址卡片
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
            .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
            .textAlign(TextAlign.Center)
            .width('100%')
            .backgroundColor($r('app.color.accent_blue_bg'))
            .borderRadius(DesignTokens.radius.md)
            .onClick(() => {
              let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
              context.openLink('https://gitcode.com/springtwr/HandySend').catch((_e: Object) => {});
            })
            .gesture(
              LongPressGesture().onAction(() => {
                if (copyText('https://gitcode.com/springtwr/HandySend')) {
                  this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copy_success'), duration: 1500 });
                }
              })
            )
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
            .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
            .textAlign(TextAlign.Center)
            .width('100%')
            .backgroundColor($r('app.color.accent_blue_bg'))
            .borderRadius(DesignTokens.radius.md)
            .onClick(() => {
              let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
              context.openLink('https://github.com/localsend/localsend').catch((_e: Object) => {});
            })
            .gesture(
              LongPressGesture().onAction(() => {
                if (copyText('https://github.com/localsend/localsend')) {
                  this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copy_success'), duration: 1500 });
                }
              })
            )
        }
        .width('100%')
      }
      .width('100%')
      .padding(DesignTokens.space.lg)
      .borderRadius(DesignTokens.radius.lg)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: 1, color: $r('app.color.border_light') })
      .margin({ top: DesignTokens.space.lg, bottom: DesignTokens.space.xl })
    }
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
  }

  build() {
    Column() {
      Text($r('app.string.more_settings'))
        .fontSize(DesignTokens.font.subtitleM)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .alignSelf(ItemAlign.Start)

      // 反馈
      Row() {
        Text($r('app.string.feedback_title'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.chevron_forward'))
          .fontSize(DesignTokens.font.titleS)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
      .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.isShowFeedbackSheet = true;
      })
      .bindSheet($$this.isShowFeedbackSheet, this.feedbackSheetBuilder(), {
        height: SheetSize.MEDIUM,
        preferType: SheetType.BOTTOM,
        width: 480,
        blurStyle: BlurStyle.Regular,
        title: {
          title: $r('app.string.feedback_title'),
          subtitle: $r('app.string.feedback_desc')
        },
        showClose: true
      })

      // 关于
      Row() {
        Text($r('app.string.about_card_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.chevron_forward'))
          .fontSize(DesignTokens.font.titleS)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width('100%')
      .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
      .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.isShowAboutSheet = true;
      })
      .bindSheet($$this.isShowAboutSheet, this.aboutSheetBuilder(), {
        height: SheetSize.FIT_CONTENT,
        preferType: SheetType.BOTTOM,
        width: 480,
        blurStyle: BlurStyle.Regular,
        title: {
          title: $r('app.string.about_card_label'),
          subtitle: $r('app.string.about_description')
        },
        showClose: true
      })

      // 调试日志
      Row() {
        Text($r('app.string.debug_log_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.debugLogEnabled })
          .onChange((isOn: boolean) => {
            this.viewModel.setDebugLogEnabled(isOn);
          })
      }
      .width('100%')
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
      .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.debug_log_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: DesignTokens.space.xs })

      // 恢复默认（危险操作，需确认）
      Button($r('app.string.restore_defaults'))
        .width('100%')
        .backgroundColor($r('app.color.danger_red'))
        .fontColor($r('app.color.text_on_color'))
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.md })
        .onClick(() => {
          this.getUIContext().showAlertDialog({
            title: $r('app.string.restore_defaults'),
            message: $r('app.string.restore_defaults_confirm'),
            primaryButton: {
              value: $r('app.string.dialog_cancel'),
              action: () => {}
            },
            secondaryButton: {
              value: $r('app.string.dialog_confirm'),
              action: () => {
                this.viewModel.restoreDefaults();
              }
            }
          });
        })
    }
    .width('100%')
    .padding(DesignTokens.space.lg)
    .borderRadius(DesignTokens.radius.lg)
    .backgroundColor($r('app.color.card_background'))
    .border({ width: 1, color: $r('app.color.border_light') })
    .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.xl })
  }
}
