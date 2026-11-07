import {
  DesignTokens
} from '../../common/DesignTokens';
import {
  getSheetWidth, isWideWidth
} from '../../common/Breakpoints';
import {
  SettingsViewModel
} from '../../viewmodel/SettingsViewModel';
import {
  AlertDialogV2,
  CustomContentDialogV2,
  AdvancedDialogV2Button,
  promptAction,
  uiObserver
} from '@kit.ArkUI';
import { DEFAULT_AUTO_CONFIRM_MODE } from '../../model/SettingsDefaults';
import { subscribeOverlayClose, unsubscribeOverlayClose } from '../../utils/OverlayCloseBus';

interface AutoConfirmOption {
  value: string
  label: Resource
  // 选项行为说明，含文本消息的自动复制行为
  desc: Resource
}

// 自动确认模式选项：顺序即弹窗列表顺序
const AUTO_CONFIRM_OPTIONS: Array<AutoConfirmOption> = [
  {
    value: 'off',
    label: $r('app.string.auto_confirm_off'),
    desc: $r('app.string.auto_confirm_off_desc')
  },
  {
    value: 'paired',
    label: $r('app.string.auto_confirm_favorites'),
    desc: $r('app.string.auto_confirm_favorites_desc')
  },
  {
    value: 'on',
    label: $r('app.string.auto_confirm_on'),
    desc: $r('app.string.auto_confirm_on_desc')
  }
];

// 接收与分享设置分组（从 SettingsContent 拆出）。
// 数据经 @Param 绑定父组件 VM，命令直调 VM（View → ViewModel）。
@ComponentV2
export struct ReceiveSettingsSection {
  // 系统宽度断点（随窗口尺寸变化自动刷新，半屏弹窗宽度断点化用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Require @Param viewModel: SettingsViewModel
  @Local isShowAutoConfirmSheet: boolean = false
  // 待确认的自动确认模式（paired/on），确认后落地
  @Local pendingAutoConfirmMode: string = ''
  // 待编辑的 PIN 值（B 类输入弹窗内容区）
  @Local pendingPinValue: string = ''
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1
  // 新传输直达详情前的弹层收起：本组件只处理自己打开的弹层
  private overlayCloseCallback: () => void = (): void => {
    this.isShowAutoConfirmSheet = false;
    this.closeActiveDialog();
  }

  aboutToAppear(): void {
    subscribeOverlayClose(this.overlayCloseCallback);
  }

  aboutToDisappear(): void {
    unsubscribeOverlayClose(this.overlayCloseCallback);
  }

  // 当前自动确认模式的显示名
  private getAutoConfirmLabel(): ResourceStr {
    for (let i = 0; i < AUTO_CONFIRM_OPTIONS.length; i++) {
      if (AUTO_CONFIRM_OPTIONS[i].value === this.viewModel.autoConfirmMode) {
        return AUTO_CONFIRM_OPTIONS[i].label;
      }
    }
    // 回退项由默认值常量驱动（常量未登记时取首项，与首个选项一致）
    for (let i = 0; i < AUTO_CONFIRM_OPTIONS.length; i++) {
      if (AUTO_CONFIRM_OPTIONS[i].value === DEFAULT_AUTO_CONFIRM_MODE as string) {
        return AUTO_CONFIRM_OPTIONS[i].label;
      }
    }
    return AUTO_CONFIRM_OPTIONS[0].label;
  }

  // 切换自动确认模式：off 直接生效；paired/on 需先弹确认
  private applyAutoConfirm(next: string): void {
    if (next === this.viewModel.autoConfirmMode) {
      return;
    }
    if (next === 'off') {
      this.viewModel.setAutoConfirmMode('off');
      return;
    }
    // paired / on：先弹确认，确认回调里才落地
    this.pendingAutoConfirmMode = next;
    this.openAutoConfirmDialog();
  }

  // 自动确认请求半屏弹窗：系统标题 + 卡片列表，选中项仅文字高亮
  @Builder
  autoConfirmSheetBuilder(): void {
    Column() {
      // 卡片容器：列表项 + Divider 分隔线
      Column() {
        List({ space: 0 }) {
          ForEach(AUTO_CONFIRM_OPTIONS, (item: AutoConfirmOption, index: number) => {
            ListItem() {
              Column() {
                Column({ space: DesignTokens.space.tiny }) {
                  Text(item.label)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor(this.viewModel.autoConfirmMode === item.value ? $r('app.color.accent_blue') :
                      $r('app.color.text_primary'))
                    .fontWeight(
                      this.viewModel.autoConfirmMode === item.value ? FontWeight.Bold : FontWeight.Normal)

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
                  this.applyAutoConfirm(item.value);
                })
                .id('settings_auto_confirm_option')

                if (index < AUTO_CONFIRM_OPTIONS.length - 1) {
                  Divider().color($r('app.color.border_light'))
                }
              }
              .width('100%')
            }
          }, (item: AutoConfirmOption) => item.value)
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

  // ── DialogV2 弹窗：自动确认警告（A 类 ConfirmDialogV2） ──

  private openAutoConfirmDialog(): void {
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.autoConfirmWarningDialog();
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
  autoConfirmWarningDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.auto_confirm_title'),
      content: this.pendingAutoConfirmMode === 'paired' ? $r('app.string.auto_confirm_paired_warning') :
        $r('app.string.auto_confirm_on_warning'),
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_cancel'),
        action: () => {
          this.closeActiveDialog();
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_confirm'),
        action: () => {
          this.viewModel.setAutoConfirmMode(this.pendingAutoConfirmMode);
          this.closeActiveDialog();
        }
      })
    })
  }

  // ── DialogV2 弹窗：PIN 输入（B 类 CustomContentDialogV2） ──

  private openPinInputDialog(): void {
    this.pendingPinValue = this.viewModel.receivePin;
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.pinInputDialog();
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

  @Builder
  pinInputDialog() {
    CustomContentDialogV2({
      primaryTitle: $r('app.string.receive_pin_label'),
      contentBuilder: () => {
        this.pinInputContent();
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
            this.viewModel.setReceivePinValue(this.pendingPinValue);
            this.closeActiveDialog();
          }
        })
      ]
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  pinInputContent() {
    Column({ space: DesignTokens.space.sm }) {
      TextInput({ text: this.pendingPinValue })
        .borderRadius(DesignTokens.radius.max)
        .id('settings_pin_input')
        .onChange((value: string) => {
          this.pendingPinValue = value;
        })
    }
    .width('100%')
  }

  build() {
    Column() {
      // 自动确认请求入口（半屏弹窗三选一）
      Row() {
        Text($r('app.string.auto_confirm_title'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Row() {
          Text(this.getAutoConfirmLabel())
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
      .onClick(() => {
        this.isShowAutoConfirmSheet = true;
      })
      .id('settings_auto_confirm_entry')
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
      .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.openPinInputDialog();
      })
      .id('settings_pin_entry')

      Text($r('app.string.receive_pin_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: DesignTokens.space.tiny })
    }
    .width('100%')
  }
}
