import { DesignTokens } from '../../common/DesignTokens';
import { SettingsViewModel } from '../../viewmodel/SettingsViewModel';
import {
  MtaSelectableBrand,
  mtaSelectableBrands,
  resolveMtaBrandDisplayName,
  resolveMtaBrandIcon
} from '../../model/mta/MtaBrandRegistry';
import { getSheetWidth, isWideWidth } from '../../common/Breakpoints';
import {
  AdvancedDialogV2Button,
  AlertDialogV2,
  promptAction,
  uiObserver
} from '@kit.ArkUI';
import { subscribeOverlayClose, unsubscribeOverlayClose } from '../../utils/OverlayCloseBus';

interface MtaAutoConfirmOption {
  value: string
  label: Resource
  desc: Resource
}

// MTA 自动确认模式选项：顺序即弹窗列表顺序（标签复用 LocalSend 同名项，描述为互传专属）
const MTA_AUTO_CONFIRM_OPTIONS: Array<MtaAutoConfirmOption> = [
  {
    value: 'off',
    label: $r('app.string.auto_confirm_off'),
    desc: $r('app.string.mta_auto_confirm_off_desc')
  },
  {
    value: 'paired',
    label: $r('app.string.auto_confirm_favorites'),
    desc: $r('app.string.mta_auto_confirm_favorites_desc')
  },
  {
    value: 'on',
    label: $r('app.string.auto_confirm_on'),
    desc: $r('app.string.mta_auto_confirm_on_desc')
  }
];

// 互传联盟（MTA）设置分组：总开关 + 允许接收 + 自动确认请求 + 显示互传提醒 + 模拟品牌选择。
// 数据经 @Param 绑定父组件 VM，命令直调 VM（View → ViewModel）。
@ComponentV2
export struct MtaSettingsSection {
  // 系统宽度断点（随窗口尺寸变化自动刷新，半屏弹窗宽度断点化用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Require @Param viewModel: SettingsViewModel
  // 是否展示模拟品牌半屏弹窗
  @Local isShowBrandSheet: boolean = false
  // 是否展示自动确认模式半屏弹窗
  @Local isShowAutoConfirmSheet: boolean = false
  // 待确认的自动确认模式（paired/on），确认后落地
  @Local pendingMtaAutoConfirmMode: string = ''
  // 当前打开的确认弹窗 id（关闭时使用）
  private activeDialogId: number = -1
  // 新传输直达详情前的弹层收起：本组件只处理自己打开的弹层
  private overlayCloseCallback: () => void = (): void => {
    this.isShowBrandSheet = false;
    this.isShowAutoConfirmSheet = false;
    this.closeActiveDialog();
  }

  aboutToAppear(): void {
    subscribeOverlayClose(this.overlayCloseCallback);
  }

  aboutToDisappear(): void {
    unsubscribeOverlayClose(this.overlayCloseCallback);
  }
  // 可模拟品牌清单（构造时取一次，保证顺序稳定且避免重复计算）
  private brandOptions: Array<MtaSelectableBrand> = mtaSelectableBrands()

  // ── 自动确认请求（半屏三选一 + 高风险确认弹窗） ──

  private getMtaAutoConfirmLabel(): ResourceStr {
    for (let i = 0; i < MTA_AUTO_CONFIRM_OPTIONS.length; i++) {
      if (MTA_AUTO_CONFIRM_OPTIONS[i].value === this.viewModel.mtaAutoConfirmMode) {
        return MTA_AUTO_CONFIRM_OPTIONS[i].label;
      }
    }
    return MTA_AUTO_CONFIRM_OPTIONS[0].label;
  }

  // 切换自动确认模式：off 直接生效；paired/on 需先弹确认
  private applyMtaAutoConfirm(next: string): void {
    if (next === this.viewModel.mtaAutoConfirmMode) {
      return;
    }
    if (next === 'off') {
      this.viewModel.setMtaAutoConfirmModeValue('off');
      return;
    }
    this.pendingMtaAutoConfirmMode = next;
    this.openMtaAutoConfirmDialog();
  }

  private openMtaAutoConfirmDialog(): void {
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.mtaAutoConfirmWarningDialog();
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
  mtaAutoConfirmWarningDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.auto_confirm_title'),
      content: this.pendingMtaAutoConfirmMode === 'paired' ?
        $r('app.string.mta_auto_confirm_paired_warning') : $r('app.string.mta_auto_confirm_on_warning'),
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_cancel'),
        action: () => {
          this.closeActiveDialog();
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_confirm'),
        action: () => {
          this.viewModel.setMtaAutoConfirmModeValue(this.pendingMtaAutoConfirmMode);
          this.closeActiveDialog();
        }
      })
    })
  }

  // 自动确认模式半屏弹窗：系统标题 + 卡片列表，选中项仅文字高亮
  @Builder
  autoConfirmSheetBuilder(): void {
    Column() {
      Column() {
        List({ space: 0 }) {
          ForEach(MTA_AUTO_CONFIRM_OPTIONS, (item: MtaAutoConfirmOption, index: number) => {
            ListItem() {
              Column() {
                Column({ space: DesignTokens.space.tiny }) {
                  Text(item.label)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor(this.viewModel.mtaAutoConfirmMode === item.value ?
                      $r('app.color.accent_blue') : $r('app.color.text_primary'))
                    .fontWeight(this.viewModel.mtaAutoConfirmMode === item.value ?
                      FontWeight.Bold : FontWeight.Normal)

                  Text(item.desc)
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_secondary'))
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({
                  left: DesignTokens.space.lg,
                  right: DesignTokens.space.lg,
                  top: DesignTokens.space.md,
                  bottom: DesignTokens.space.md
                })
                .constraintSize({ minHeight: DesignTokens.size.thumbSm })
                .onClick(() => {
                  // 先收起弹窗：高风险的 paired/on 随后弹出确认框，取消时保持原值
                  this.isShowAutoConfirmSheet = false;
                  this.applyMtaAutoConfirm(item.value);
                })
                .id('settings_mta_auto_confirm_option')

                if (index < MTA_AUTO_CONFIRM_OPTIONS.length - 1) {
                  Divider().color($r('app.color.border_light'))
                }
              }
              .width('100%')
            }
          }, (item: MtaAutoConfirmOption) => item.value)
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

  // 模拟品牌半屏弹窗：列表项 = 品牌图标 + 本地化显示名，点选即写入并关闭
  @Builder
  brandSheetBuilder(): void {
    Column() {
      // 卡片容器：列表项 + Divider 分隔线
      Column() {
        List({ space: 0 }) {
          ForEach(this.brandOptions, (item: MtaSelectableBrand, index: number) => {
            ListItem() {
              Column() {
                Row({ space: DesignTokens.space.sm }) {
                  Image(item.iconRes)
                    .width(DesignTokens.size.iconSm)
                    .height(DesignTokens.size.iconSm)

                  Text(item.displayNameRes)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor(this.viewModel.mtaSimulatedBrandId === item.canonical ? $r('app.color.accent_blue') :
                      $r('app.color.text_primary'))
                    .fontWeight(
                      this.viewModel.mtaSimulatedBrandId === item.canonical ? FontWeight.Bold : FontWeight.Normal)
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
                  this.viewModel.setMtaSimulatedBrandValue(item.canonical);
                  this.isShowBrandSheet = false;
                })
                .id('settings_mta_brand_option')

                if (index < this.brandOptions.length - 1) {
                  Divider().color($r('app.color.border_light'))
                }
              }
              .width('100%')
            }
          }, (item: MtaSelectableBrand) => `${item.canonical}`)
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
      // 卡片（标题由设置分组统一渲染）
      Column() {
        // 互传联盟总开关（卡片首行）：关闭时停用互传接收与设备发现
        Row() {
          Text($r('app.string.mta_enabled_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.viewModel.mtaEnabled })
            .onChange((isOn: boolean) => {
              this.viewModel.setMtaEnabledValue(isOn);
            })
            .id('settings_mta_enabled_toggle')
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.mta_enabled_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })

        // 允许接收（默认开启）：应用在前台时以互传联盟身份接收附近设备传输；
        // 总开关关闭时置灰
        Row() {
          Text($r('app.string.mta_receive_enabled_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.viewModel.mtaReceiveEnabled })
            .enabled(this.viewModel.mtaEnabled)
            .onChange((isOn: boolean) => {
              this.viewModel.setMtaReceiveEnabledValue(isOn);
            })
            .id('settings_mta_receive_toggle')
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        Text(this.viewModel.mtaEnabled ? $r('app.string.mta_receive_enabled_desc') :
          $r('app.string.mta_receive_disabled_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })

        // 自动确认请求（三选一）：与 LocalSend 同口径；总开关关闭时置灰
        Row() {
          Text($r('app.string.auto_confirm_title'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Row() {
            Text(this.getMtaAutoConfirmLabel())
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.End)
              .layoutWeight(1)
              .margin({ right: DesignTokens.space.xxs })
            SymbolGlyph($r('sys.symbol.chevron_forward'))
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor([$r('app.color.text_secondary')])
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.End)
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)
        .enabled(this.viewModel.mtaEnabled)
        .opacity(this.viewModel.mtaEnabled ? 1 : 0.4)
        .onClick(() => {
          this.isShowAutoConfirmSheet = true;
        })
        .id('settings_mta_auto_confirm_entry')
        .bindSheet($$this.isShowAutoConfirmSheet, this.autoConfirmSheetBuilder(), {
          height: SheetSize.MEDIUM,
          width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
          // 宽屏（lg/xl）以居中弹窗呈现，窄屏保持底部弹窗（与手机行为一致）
          preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
          blurStyle: BlurStyle.Regular,
          title: {
            title: $r('app.string.auto_confirm_title'),
            subtitle: ''
          },
          showClose: true
        })

        // 显示互传提醒（默认开启）：关闭后发送页不再显示互传相关的蓝牙/WLAN 警告横幅
        Row() {
          Text($r('app.string.mta_connection_warnings_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.viewModel.mtaConnectionWarnings })
            .onChange((isOn: boolean) => {
              this.viewModel.setMtaConnectionWarningsValue(isOn);
            })
            .id('settings_mta_connection_warnings_toggle')
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.mta_connection_warnings_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })

        // 模拟品牌：显示当前品牌图标 + 本地化显示名，点击打开半屏选择弹窗
        Row() {
          Text($r('app.string.mta_simulated_brand_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Row() {
            Image(resolveMtaBrandIcon(this.viewModel.mtaSimulatedBrandId))
              .width(DesignTokens.size.iconSm)
              .height(DesignTokens.size.iconSm)
              // 图标与品牌名之间保留较大间距，文字与箭头统一为 4vp
              .margin({ right: DesignTokens.space.tiny })

            Text(resolveMtaBrandDisplayName(this.viewModel.mtaSimulatedBrandId))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ right: DesignTokens.space.xxs })

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
          this.isShowBrandSheet = true;
        })
        .id('settings_mta_simulated_brand_entry')
        .bindSheet($$this.isShowBrandSheet, this.brandSheetBuilder(), {
          height: SheetSize.MEDIUM,
          width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
          // 宽屏（lg/xl）以居中弹窗呈现，窄屏保持底部弹窗（与手机行为一致）
          preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
          blurStyle: BlurStyle.Regular,
          title: {
            title: $r('app.string.mta_brand_picker_title'),
            subtitle: ''
          },
          showClose: true
        })

        Text($r('app.string.mta_simulated_brand_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })
      }
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
