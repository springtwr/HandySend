/**
 * PortalPage.ets — 在线服务入口页。
 *
 * 卡片网格：每个预设或用户添加的站点一张卡片，最后一张卡片为添加入口。
 * 点击卡片进入站点浏览页；长按卡片删除；标题栏菜单可恢复默认站点。
 *
 * 页面不承载下载进度与浏览内容，站点数据由 PortalSiteRepository 维护。
 */

import { uiObserver, promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  HdsNavDestination,
  HdsNavigationMenuContentOptions,
  HdsNavigationMenuItemOptions,
  HdsNavDestinationTitleMode
} from '@kit.UIDesignKit';
import { buildImmersiveTitleBar } from '../common/ImmersiveTitleBar';
import { DesignTokens } from '../common/DesignTokens';
import { getPageContentMaxWidth, getPageMargin, getSheetWidth, isWideWidth } from '../common/Breakpoints';
import { PortalViewModel } from '../viewmodel/PortalViewModel';
import {
  PortalSite,
  PORTAL_BADGE_LARGE_FILE,
  PORTAL_BADGE_LOGIN,
  PORTAL_BADGE_P2P,
  PORTAL_BADGE_TEMPORARY
} from '../model/PortalSite';
import { PortalSiteCard } from '../views/PortalSiteCard';
import { getAppContext } from '../service/repository/AppCore';
import { acceptPortalRisk, isPortalRiskAccepted } from '../service/repository/PortalSiteRepository';
import { getStringSync } from '../utils/ResourceUtil';

@ComponentV2
export struct PortalPage {
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local private viewModel: PortalViewModel = new PortalViewModel();
  @Local private isNavigatingBack: boolean = false;
  @Local private showSheet: boolean = false;
  // 当前半模态内容：add 添加站点，edit 编辑站点，help 使用说明
  @Local private sheetType: string = 'add';
  @Local private editingSiteId: string = '';
  @Local private inputName: string = '';
  @Local private inputUrl: string = '';
  @Local private inputNeedLogin: boolean = false;
  @Local private inputLargeFile: boolean = false;
  @Local private inputTemporary: boolean = false;
  @Local private inputP2p: boolean = false;
  @Local private errorText: string = '';
  private pathStack: NavPathStack = new NavPathStack();
  private scroller: Scroller = new Scroller();
  private riskDialogId: number = -1;

  aboutToAppear(): void {
    this.viewModel.load();
  }

  aboutToDisappear(): void {
    this.viewModel.unload();
    this.closeRiskDialog();
  }

  /** 首次进入：强制确认第三方站点风险；点外部与返回键视为不同意并退出。 */
  private openRiskDialog(): void {
    let options: promptAction.CustomDialogOptions = {
      builder: (): void => {
        this.riskContent()
      },
      alignment: DialogAlignment.Center,
      width: '88%',
      autoCancel: false,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
        this.pathStack.pop();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(options)
      .then((id: number): void => {
        this.riskDialogId = id;
      })
      .catch((_e: Error): void => {
        // 弹窗打开失败不阻塞页面，避免用户无法进入功能
      });
  }

  private closeRiskDialog(): void {
    if (this.riskDialogId < 0) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().closeCustomDialog(this.riskDialogId);
    } catch (_e) {
    }
    this.riskDialogId = -1;
  }

  private acceptRisk(): void {
    acceptPortalRisk();
    this.closeRiskDialog();
  }

  private declineRisk(): void {
    this.closeRiskDialog();
    this.pathStack.pop();
  }

  onBackPress(): boolean {
    if (this.isNavigatingBack) {
      return true;
    }
    this.isNavigatingBack = true;
    this.pathStack.pop();
    return true;
  }

  private getContentMaxWidth(): Length {
    return getPageContentMaxWidth(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType);
  }

  private toast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
    } catch (_e) {
      // 提示展示失败不影响主流程
    }
  }

  /** 标题栏菜单：使用说明（右上角常驻）与恢复默认（溢出菜单）。 */
  private buildTitleMenu(): HdsNavigationMenuContentOptions {
    let helpItem: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.questionmark_circle'),
        label: $r('app.string.portal_help'),
        action: (): void => {
          this.sheetType = 'help';
          this.showSheet = true;
        }
      }
    };
    let restore: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.arrow_clockwise'),
        label: $r('app.string.portal_restore_default'),
        action: (): void => {
          this.confirmRestore();
        }
      }
    };
    return { value: [helpItem, restore], maxCount: 2 };
  }

  /** 删除确认：预设删除后日常同步不复活，恢复默认才回来。 */
  private confirmDelete(site: PortalSite): void {
    let message: string = getStringSync(this.getUIContext(), $r('app.string.portal_delete_message'))
      .replace('%s', site.name);
    this.getUIContext().getPromptAction().showDialog({
      title: $r('app.string.portal_delete_title'),
      message: message,
      buttons: [
        {
          text: $r('app.string.portal_cancel'),
          color: $r('app.color.text_secondary')
        },
        {
          text: $r('app.string.portal_delete_confirm'),
          color: $r('app.color.stop_red')
        }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index === 1) {
        this.viewModel.remove(site.id);
        this.toast($r('app.string.portal_removed'));
      }
    }).catch((_e: Error): void => {
    });
  }

  /** 恢复默认确认：会重新拉取远程配置并复活已删除的预设，保留用户站点。 */
  private confirmRestore(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: $r('app.string.portal_restore_title'),
      message: $r('app.string.portal_restore_message'),
      buttons: [
        {
          text: $r('app.string.portal_cancel'),
          color: $r('app.color.text_secondary')
        },
        {
          text: $r('app.string.portal_restore_default'),
          color: $r('app.color.accent_blue')
        }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index === 1) {
        this.restoreDefaults();
      }
    }).catch((_e: Error): void => {
    });
  }

  private restoreDefaults(): void {
    let ok: boolean = this.viewModel.restoreDefaults();
    this.toast(ok ? $r('app.string.portal_restore_success') : $r('app.string.portal_restore_failed'));
  }

  /** 打开前确认；确认后交给系统浏览器，应用不承载网页内容。 */
  private openSite(site: PortalSite): void {
    let template: string = getStringSync(this.getUIContext(),
      $r('app.string.portal_open_confirm_message'));
    let message: string = template.replace('%s', site.name).replace('%s', site.url);
    this.getUIContext().getPromptAction().showDialog({
      title: $r('app.string.portal_open_confirm_title'),
      message: message,
      buttons: [
        {
          text: $r('app.string.portal_cancel'),
          color: $r('app.color.text_secondary')
        },
        {
          text: $r('app.string.portal_open_confirm_action'),
          color: $r('app.color.accent_blue')
        }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index === 1) {
        this.launchBrowser(site.url);
      }
    }).catch((_e: Error): void => {
    });
  }

  /** 交给系统浏览器打开站点地址。 */
  private launchBrowser(url: string): void {
    let context: common.UIAbilityContext | undefined = getAppContext();
    if (context === undefined) {
      this.toast($r('app.string.portal_open_failed'));
      return;
    }
    let want: Want = {
      action: 'ohos.want.action.viewData',
      uri: url
    };
    context.startAbility(want).catch((_e: Error): void => {
      this.toast($r('app.string.portal_open_failed'));
    });
  }

  private resetAddForm(): void {
    this.inputName = '';
    this.inputUrl = '';
    this.inputNeedLogin = false;
    this.inputLargeFile = false;
    this.inputTemporary = false;
    this.inputP2p = false;
    this.editingSiteId = '';
    this.errorText = '';
  }

  /** 长按卡片：打开编辑表单，预填当前站点。 */
  private openEdit(site: PortalSite): void {
    this.sheetType = 'edit';
    this.editingSiteId = site.id;
    this.inputName = site.name;
    this.inputUrl = site.url;
    this.inputNeedLogin = site.badges.indexOf(PORTAL_BADGE_LOGIN) >= 0;
    this.inputLargeFile = site.badges.indexOf(PORTAL_BADGE_LARGE_FILE) >= 0;
    this.inputTemporary = site.badges.indexOf(PORTAL_BADGE_TEMPORARY) >= 0;
    this.inputP2p = site.badges.indexOf(PORTAL_BADGE_P2P) >= 0;
    this.errorText = '';
    this.showSheet = true;
  }

  private submitForm(): void {
    let result: string;
    if (this.sheetType === 'edit') {
      result = this.viewModel.update(this.editingSiteId, this.inputName, this.inputUrl,
        this.inputNeedLogin, this.inputLargeFile, this.inputP2p, this.inputTemporary);
    } else {
      result = this.viewModel.add(this.inputName, this.inputUrl,
        this.inputNeedLogin, this.inputLargeFile, this.inputP2p, this.inputTemporary);
    }
    if (result.length === 0) {
      this.showSheet = false;
      this.resetAddForm();
      this.toast($r('app.string.portal_saved'));
      return;
    }
    if (result === 'name') {
      this.errorText = getStringSync(this.getUIContext(), $r('app.string.portal_name_required'));
    } else if (result === 'url') {
      this.errorText = getStringSync(this.getUIContext(), $r('app.string.portal_invalid_url'));
    } else if (result === 'full') {
      this.errorText = getStringSync(this.getUIContext(), $r('app.string.portal_limit_reached'));
    } else if (result === 'notfound') {
      this.errorText = getStringSync(this.getUIContext(), $r('app.string.portal_site_missing'));
    } else {
      this.errorText = getStringSync(this.getUIContext(), $r('app.string.portal_duplicate_url'));
    }
  }

  /** 当前半模态标题。 */
  private sheetTitle(): ResourceStr {
    if (this.sheetType === 'help') {
      return $r('app.string.portal_help');
    }
    if (this.sheetType === 'edit') {
      return $r('app.string.portal_edit_title');
    }
    return $r('app.string.portal_add_title');
  }

  @Builder
  addCard() {
    Column({ space: DesignTokens.space.xxs }) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(DesignTokens.font.titleM)
        .fontColor([$r('app.color.accent_blue')])
      Text($r('app.string.portal_add'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .constraintSize({ minHeight: 96 })
    .justifyContent(FlexAlign.Center)
    .borderRadius(DesignTokens.radius.lg)
    .backgroundColor($r('app.color.card_background'))
    .border({
      width: DesignTokens.component.borderSlim,
      color: $r('app.color.border_light'),
      style: BorderStyle.Dashed
    })
    .onClick((): void => {
      this.sheetType = 'add';
      this.resetAddForm();
      this.showSheet = true;
    })
    .id('portal_add_card')
  }

  @Builder
  addSheet() {
    Column({ space: DesignTokens.space.md }) {
      Column({ space: DesignTokens.space.tiny }) {
        Text($r('app.string.portal_name_label'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ text: this.inputName, placeholder: $r('app.string.portal_name_placeholder') })
          .height(44)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string): void => {
            this.inputName = value;
            this.errorText = '';
          })
          .id('portal_name_input')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: DesignTokens.space.tiny }) {
        Text($r('app.string.portal_url_label'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ text: this.inputUrl, placeholder: $r('app.string.portal_url_placeholder') })
          .height(44)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string): void => {
            this.inputUrl = value;
            this.errorText = '';
          })
          .id('portal_url_input')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Row() {
        Text($r('app.string.portal_need_login'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.inputNeedLogin })
          .onChange((isOn: boolean): void => {
            this.inputNeedLogin = isOn;
          })
          .id('portal_need_login_toggle')
      }
      .width('100%')
      .constraintSize({ minHeight: 44 })
      .alignItems(VerticalAlign.Center)

      Row() {
        Text($r('app.string.portal_large_file'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.inputLargeFile })
          .onChange((isOn: boolean): void => {
            this.inputLargeFile = isOn;
          })
          .id('portal_large_file_toggle')
      }
      .width('100%')
      .constraintSize({ minHeight: 44 })
      .alignItems(VerticalAlign.Center)

      Row() {
        Text($r('app.string.portal_badge_temporary'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.inputTemporary })
          .onChange((isOn: boolean): void => {
            this.inputTemporary = isOn;
          })
          .id('portal_temporary_toggle')
      }
      .width('100%')
      .constraintSize({ minHeight: 44 })
      .alignItems(VerticalAlign.Center)

      Row() {
        Text($r('app.string.portal_badge_p2p'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.inputP2p })
          .onChange((isOn: boolean): void => {
            this.inputP2p = isOn;
          })
          .id('portal_p2p_toggle')
      }
      .width('100%')
      .constraintSize({ minHeight: 44 })
      .alignItems(VerticalAlign.Center)

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.stop_red'))
          .width('100%')
      }

      Row({ space: DesignTokens.space.sm }) {
        Button($r('app.string.portal_cancel'))
          .layoutWeight(1)
          .height(DesignTokens.size.thumbSm)
          .fontSize(DesignTokens.font.bodyM)
          .backgroundColor($r('app.color.card_background'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => {
            this.showSheet = false;
            this.resetAddForm();
          })
        Button($r('app.string.portal_save'))
          .layoutWeight(1)
          .height(DesignTokens.size.thumbSm)
          .fontSize(DesignTokens.font.bodyM)
          .onClick((): void => {
            this.submitForm();
          })
          .id('portal_save_btn')
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })
    }
    .width('100%')
    .padding({
      left: DesignTokens.space.lg,
      right: DesignTokens.space.lg,
      bottom: DesignTokens.space.lg
    })
    .alignItems(HorizontalAlign.Start)
  }

  /** 使用说明条目：圆点 + 正文；indent 用于徽标子项缩进，bold 用于分组标题。 */
  @Builder
  helpItem(text: ResourceStr, indent: boolean = false, bold: boolean = false) {
    Row({ space: DesignTokens.space.sm }) {
      Circle({ width: 4, height: 4 })
        .fill($r('app.color.accent_blue'))
        .margin({ top: bold ? 8 : 7 })
      Text(text)
        .fontSize(DesignTokens.font.bodyM)
        .fontWeight(bold ? FontWeight.Medium : FontWeight.Normal)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: indent ? DesignTokens.space.md : 0 })
    .alignItems(VerticalAlign.Top)
  }

  /** 使用说明内容：通用说明 + 徽标含义。 */
  @Builder
  helpContent() {
    Scroll() {
      Column({ space: DesignTokens.space.md }) {
        this.helpItem($r('app.string.portal_help_1'))
        this.helpItem($r('app.string.portal_help_2'))
        this.helpItem($r('app.string.portal_help_3'))
        this.helpItem($r('app.string.portal_help_4'))

        this.helpItem($r('app.string.portal_help_5'), false, true)

        Column({ space: DesignTokens.space.sm }) {
          this.helpItem($r('app.string.portal_help_5_1'), true)
          this.helpItem($r('app.string.portal_help_5_2'), true)
          this.helpItem($r('app.string.portal_help_5_3'), true)
          this.helpItem($r('app.string.portal_help_5_4'), true)
        }
        .width('100%')
      }
      .width('100%')
      .padding({
        left: DesignTokens.space.lg,
        right: DesignTokens.space.lg,
        bottom: DesignTokens.space.lg
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  sheetContent() {
    if (this.sheetType === 'help') {
      this.helpContent()
    } else {
      this.addSheet()
    }
  }

  /** 首次进入的风险声明：三条要点 + 不同意/同意并继续。 */
  @Builder
  riskContent() {
    Column({ space: DesignTokens.space.md }) {
      Text($r('app.string.portal_risk_title'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Text($r('app.string.portal_risk_intro'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      this.helpItem($r('app.string.portal_risk_1'))
      this.helpItem($r('app.string.portal_risk_2'))
      this.helpItem($r('app.string.portal_risk_3'))

      Row({ space: DesignTokens.space.sm }) {
        Button($r('app.string.portal_risk_decline'))
          .layoutWeight(1)
          .height(DesignTokens.size.thumbSm)
          .fontSize(DesignTokens.font.bodyM)
          .backgroundColor($r('app.color.card_background'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => {
            this.declineRisk();
          })
        Button($r('app.string.portal_risk_accept'))
          .layoutWeight(1)
          .height(DesignTokens.size.thumbSm)
          .fontSize(DesignTokens.font.bodyM)
          .onClick((): void => {
            this.acceptRisk();
          })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })
    }
    .width('100%')
    .padding(DesignTokens.space.lg)
    .borderRadius(DesignTokens.radius.lg)
    .backgroundColor($r('app.color.card_background'))
  }

  build() {
    HdsNavDestination() {
      Column() {
        Column() {
          List({ space: DesignTokens.space.sm, scroller: this.scroller }) {
            ForEach(this.viewModel.sites, (site: PortalSite) => {
              ListItem() {
                PortalSiteCard({
                  site: site,
                  onOpen: (target: PortalSite): void => {
                    this.openSite(target);
                  },
                  onEdit: (target: PortalSite): void => {
                    this.openEdit(target);
                  },
                  onDelete: (target: PortalSite): void => {
                    this.confirmDelete(target);
                  }
                })
              }
            }, (site: PortalSite) => site.id + '|' + site.url + '|' + site.badges.join(','))
            ListItem() {
              this.addCard()
            }
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .padding({
            left: getPageMargin(this.breakpointInfo.widthBreakpoint),
            right: getPageMargin(this.breakpointInfo.widthBreakpoint),
            top: DesignTokens.space.md,
            bottom: DesignTokens.space.xl
          })
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: this.getContentMaxWidth() })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .titleBar(buildImmersiveTitleBar({
      title: $r('app.string.portal_title'),
      menu: this.buildTitleMenu()
    }))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.showSheet, this.sheetContent(), {
      height: this.sheetType === 'help' ? SheetSize.MEDIUM : SheetSize.FIT_CONTENT,
      width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
      preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
      dragBar: true,
      showClose: true,
      title: {
        title: this.sheetTitle()
      }
    })
    .onBackPressed((): boolean => {
      return this.onBackPress();
    })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
      if (!isPortalRiskAccepted()) {
        this.openRiskDialog();
      }
    })
  }
}

// 路由表引用：PortalPageBuilder(name, param)
@Builder
export function PortalPageBuilder(_name: string, _param: Object) {
  PortalPage()
}
