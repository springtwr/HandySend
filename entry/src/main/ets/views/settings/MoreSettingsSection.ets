import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AlertDialogV2, AdvancedDialogV2Button, promptAction, uiObserver } from '@kit.ArkUI';
import {
  DesignTokens
} from '../../common/DesignTokens';
import {
  getSheetWidth, isWideWidth
} from '../../common/Breakpoints';
import { copyText } from '../../utils/ClipboardUtil';
import { getStringSync } from '../../utils/ResourceUtil';
import { getDeviceType } from '../../service/repository/DeviceRepository';
import {
  SettingsViewModel
} from '../../viewmodel/SettingsViewModel';

// 更多设置分组（关于/反馈/评价/赞助/诊断日志/恢复默认）。
// 关于/反馈/评价/赞助半屏弹窗直接绑定在本组件，各自独立。

// 反馈收件邮箱：邮箱路径统一写入收件人，避免用户手填出错
const FEEDBACK_MAIL_ADDRESS: string = 'springtwr@qq.com';

@ComponentV2
export struct MoreSettingsSection {
  // 系统宽度断点（随窗口尺寸变化自动刷新，半屏弹窗宽度断点化用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Require @Param viewModel: SettingsViewModel
  @Local isShowFeedbackSheet: boolean = false
  @Local isShowAboutSheet: boolean = false
  @Local isShowSponsorSheet: boolean = false
  @Local isShowRateSheet: boolean = false
  // 当前打开的 A 类弹窗 id（接触开发者弹窗关闭时使用）
  private activeDialogId: number = -1
  // 打开诊断日志页意图：本组件不持有导航栈，经此上抛由持有栈的页面执行
  @Event onOpenDiagnosticLogs: () => void = () => {
  }

  @Builder
  feedbackSheetBuilder(): void {
    Column() {
      Column() {
        // 邮箱
        Row() {
          Image($r('app.media.ic_more_email'))
            .width(DesignTokens.font.subtitleM)
            .height(DesignTokens.font.subtitleM)

          Text($r('app.string.feedback_email'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .margin({ left: DesignTokens.space.sm })

          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.subtitleL)
            .fontColor([$r('app.color.text_secondary')])
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
        .onClick(() => {
          this.openContactDeveloperDialog();
        })
        .id('settings_feedback_email_entry')

        Divider().color($r('app.color.border_light'))

        // 代码仓库
        Row() {
          Image($r('app.media.ic_more_git'))
            .width(DesignTokens.font.subtitleM)
            .height(DesignTokens.font.subtitleM)

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
        .padding({
          left: DesignTokens.space.lg,
          right: DesignTokens.space.lg,
          top: DesignTokens.space.md,
          bottom: DesignTokens.space.md
        })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
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
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    }
    .width('100%')
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
  }

  @Builder
  sponsorSheetBuilder(): void {
    Column() {
      Column() {
        Text($r('app.string.sponsor_message'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.lg })
      }
      .width('100%')
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      .padding({
        left: DesignTokens.space.lg,
        right: DesignTokens.space.lg,
        top: DesignTokens.space.md,
        bottom: DesignTokens.space.md
      })

      Button($r('app.string.sponsor_go'))
        .width('100%')
        .backgroundColor($r('app.color.accent_blue_bg'))
        .fontColor($r('app.color.ip_blue_text'))
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.lg, bottom: DesignTokens.space.xl })
        .onClick(() => {
          let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          context.openLink('https://ifdian.net/a/springtwr').catch((_e: Object) => {
            // 浏览器可能不可用
          });
        })
        .id('settings_sponsor_go_btn')
    }
    .width('100%')
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
  }

  @Builder
  rateSheetBuilder(): void {
    Column() {
      Column() {
        Text($r('app.string.rate_message'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.lg })
      }
      .width('100%')
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      .padding({
        left: DesignTokens.space.lg,
        right: DesignTokens.space.lg,
        top: DesignTokens.space.md,
        bottom: DesignTokens.space.md
      })

      Button($r('app.string.rate_go'))
        .width('100%')
        .backgroundColor($r('app.color.accent_blue_bg'))
        .fontColor($r('app.color.ip_blue_text'))
        .borderRadius(DesignTokens.radius.md)
        .margin({ top: DesignTokens.space.lg, bottom: DesignTokens.space.xl })
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
        .id('settings_rate_go_btn')
    }
    .width('100%')
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
  }

  /** 设备类型取值（mobile / desktop / tablet）转展示文案，与「本机信息」同一套资源。 */
  private deviceTypeText(): string {
    let type: string = getDeviceType();
    let res: Resource = $r('app.string.device_type_mobile');
    if (type === 'desktop') {
      res = $r('app.string.device_type_desktop');
    } else if (type === 'tablet') {
      res = $r('app.string.device_type_tablet');
    }
    return getStringSync(this.getUIContext(), res);
  }

  /** 反馈邮件标题：固定主题，便于收件方在邮件列表里识别。 */
  private buildFeedbackMailSubject(): string {
    return getStringSync(this.getUIContext(), $r('app.string.feedback_mail_subject'));
  }

  /**
   * 反馈邮件正文：先留出填写位置，再附定位所需的版本与设备类型，最后列出可选补充项。
   * 可选段落只保留空行，由用户自行补内容。
   */
  private buildFeedbackMailBody(): string {
    let ui = this.getUIContext();
    let versionLine = getStringSync(ui, $r('app.string.feedback_mail_body_version'))
      .replace('%s', this.viewModel.handySendVersion);
    let deviceLine = getStringSync(ui, $r('app.string.feedback_mail_body_device'))
      .replace('%s', this.deviceTypeText());
    let lines: Array<string> = [
      getStringSync(ui, $r('app.string.feedback_mail_body_intro')),
      '',
      '',
      getStringSync(ui, $r('app.string.feedback_mail_body_meta_title')),
      versionLine,
      deviceLine,
      '',
      getStringSync(ui, $r('app.string.feedback_mail_body_steps')),
      '',
      getStringSync(ui, $r('app.string.feedback_mail_body_screenshots')),
      '',
      getStringSync(ui, $r('app.string.feedback_mail_body_logs'))
    ];
    return lines.join('\n');
  }

  /**
   * 邮箱反馈：先按系统邮件扩展面板拉起（安装多个邮件应用时由用户在面板中选择），
   * 面板不可用（无接入 ComposeMail 的邮件应用）时回退 mailto 隐式拉起默认邮件应用。
   */
  private openFeedbackMail(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let subject: string = this.buildFeedbackMailSubject();
    let body: string = this.buildFeedbackMailBody();
    let wantParam: Record<string, Object> = {
      'sceneType': 1,
      // 邮件类扩展面板要求字符串参数统一 encodeURI 编码
      'email': [encodeURI(FEEDBACK_MAIL_ADDRESS)],
      'subject': encodeURI(subject),
      'body': encodeURI(body)
    };
    let callback: common.AbilityStartCallback = {
      onError: () => {
      },
      onResult: () => {
      }
    };
    context.startAbilityByType('mail', wantParam, callback).catch((_e: BusinessError) => {
      let want: Want = {
        action: 'ohos.want.action.sendToData',
        // query 段用 encodeURIComponent：正文含换行与中文，且需转义 & 与 =
        uri: `mailto:${FEEDBACK_MAIL_ADDRESS}?subject=${encodeURIComponent(subject)}` +
          `&body=${encodeURIComponent(body)}`
      };
      context.startAbility(want).catch((_err: BusinessError) => {
        // 设备可能未安装邮件应用
      });
    });
  }

  // ── DialogV2 弹窗：联系开发者（A 类 AlertDialogV2） ──

  private openContactDeveloperDialog(): void {
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.contactDeveloperDialog();
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

  private closeActiveDialog(): void {
    if (this.activeDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.activeDialogId);
      this.activeDialogId = -1;
    }
  }

  @Builder
  contactDeveloperDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.contact_developer_title'),
      content: FEEDBACK_MAIL_ADDRESS,
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.contact_developer_copy'),
        action: () => {
          if (copyText(FEEDBACK_MAIL_ADDRESS)) {
            this.getUIContext()
              .getPromptAction()
              .showToast({ message: $r('app.string.copy_success'), duration: 1500 });
          }
          this.closeActiveDialog();
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.contact_developer_send'),
        action: () => {
          this.closeActiveDialog();
          this.openFeedbackMail();
        }
      })
    })
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
        .padding({
          left: DesignTokens.space.lg,
          right: DesignTokens.space.lg,
          top: DesignTokens.space.sm,
          bottom: DesignTokens.space.sm
        })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
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
        .padding({
          left: DesignTokens.space.lg,
          right: DesignTokens.space.lg,
          top: DesignTokens.space.sm,
          bottom: DesignTokens.space.sm
        })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
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
        .padding({
          left: DesignTokens.space.lg,
          right: DesignTokens.space.lg,
          top: DesignTokens.space.sm,
          bottom: DesignTokens.space.sm
        })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .borderRadius(DesignTokens.radius.lg)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })

      // 仓库地址卡片
      Column() {
        Column() {
          Text($r('app.string.about_project_url_title'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ bottom: DesignTokens.space.tiny })

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
              context.openLink('https://gitcode.com/springtwr/HandySend').catch((_e: Object) => {
              });
            })
            .gesture(
              LongPressGesture().onAction(() => {
                if (copyText('https://gitcode.com/springtwr/HandySend')) {
                  this.getUIContext()
                    .getPromptAction()
                    .showToast({ message: $r('app.string.copy_success'), duration: 1500 });
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
            .margin({ bottom: DesignTokens.space.tiny })

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
              context.openLink('https://github.com/localsend/localsend').catch((_e: Object) => {
              });
            })
            .gesture(
              LongPressGesture().onAction(() => {
                if (copyText('https://github.com/localsend/localsend')) {
                  this.getUIContext()
                    .getPromptAction()
                    .showToast({ message: $r('app.string.copy_success'), duration: 1500 });
                }
              })
            )
        }
        .width('100%')
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
      .margin({ top: DesignTokens.space.lg, bottom: DesignTokens.space.xl })
    }
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
  }

  build() {
    Column() {
      // 卡片（标题由设置分组统一渲染）
      Column() {
        // 关于（首行：承载卡片上边距）
        Row() {
          Text($r('app.string.about_card_label'))
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
          this.isShowAboutSheet = true;
        })
        .id('settings_about_entry')
        .bindSheet($$this.isShowAboutSheet, this.aboutSheetBuilder(), {
          height: SheetSize.FIT_CONTENT,
          width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
          // 宽屏（lg/xl）以居中弹窗呈现，窄屏保持底部弹窗（与手机行为一致）
          preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
          blurStyle: BlurStyle.Regular,
          title: {
            title: $r('app.string.about_card_label'),
            subtitle: $r('app.string.about_description')
          },
          showClose: true
        })

        // 评价
        Column() {
          Row() {
            Text($r('app.string.rate_label'))
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

          Text($r('app.string.rate_hint'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .alignSelf(ItemAlign.Start)
            .margin({ bottom: DesignTokens.space.tiny })
        }
        .width('100%')
        .onClick(() => {
          this.isShowRateSheet = true;
        })
        .id('settings_rate_entry')
        .bindSheet($$this.isShowRateSheet, this.rateSheetBuilder(), {
          height: SheetSize.MEDIUM,
          width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
          preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
          blurStyle: BlurStyle.Regular,
          title: {
            title: $r('app.string.rate_label'),
            subtitle: $r('app.string.rate_description')
          },
          showClose: true
        })

        // 反馈
        Row() {
          Text($r('app.string.feedback_title'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.subtitleL)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width('100%')
        .padding({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.isShowFeedbackSheet = true;
        })
        .id('settings_feedback_entry')
        .bindSheet($$this.isShowFeedbackSheet, this.feedbackSheetBuilder(), {
          height: SheetSize.MEDIUM,
          width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
          // 宽屏（lg/xl）以居中弹窗呈现，窄屏保持底部弹窗（与手机行为一致）
          preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
          blurStyle: BlurStyle.Regular,
          title: {
            title: $r('app.string.feedback_title'),
            subtitle: $r('app.string.feedback_desc')
          },
          showClose: true
        })

        // 赞助
        Row() {
          Text($r('app.string.sponsor_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.subtitleL)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width('100%')
        .padding({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.isShowSponsorSheet = true;
        })
        .id('settings_sponsor_entry')
        .bindSheet($$this.isShowSponsorSheet, this.sponsorSheetBuilder(), {
          height: SheetSize.MEDIUM,
          width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
          preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
          blurStyle: BlurStyle.Regular,
          title: {
            title: $r('app.string.sponsor_label'),
            subtitle: $r('app.string.sponsor_description')
          },
          showClose: true
        })

        // 诊断日志（带箭头的导航入口行）
        Row() {
          Text($r('app.string.diagnostic_logs_title'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.font.subtitleL)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width('100%')
        .padding({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.onOpenDiagnosticLogs();
        })
        .id('settings_diagnostic_logs_entry')

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
                action: () => {
                }
              },
              secondaryButton: {
                value: $r('app.string.dialog_confirm'),
                action: () => {
                  this.viewModel.restoreDefaults();
                }
              }
            });
          })
          .id('settings_restore_defaults_btn')
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
    .width('100%')
  }
}
