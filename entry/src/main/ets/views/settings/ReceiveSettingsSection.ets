import {
  DesignTokens
} from '../../common/DesignTokens';
import {
  SettingsViewModel
} from '../../viewmodel/SettingsViewModel';
import {
  TabSegmentButtonV2,
  SegmentButtonV2Items,
  AlertDialogV2,
  CustomContentDialogV2,
  AdvancedDialogV2Button,
  promptAction
} from '@kit.ArkUI';

// 自动确认模式枚举固定顺序：与 segmentedItems 下标一一对应
const AUTO_CONFIRM_VALUES: Array<string> = ['off', 'paired', 'on'];

// 接收与分享设置分组（从 SettingsContent 拆出）。
// 数据经 @Param 绑定父组件 VM，命令直调 VM（View → ViewModel）。
@ComponentV2
export struct ReceiveSettingsSection {
  @Require @Param viewModel: SettingsViewModel
  // 受控选中的分段下标：始终与 viewModel.autoConfirmMode 对齐，
  // 确认弹窗被取消时回退到此值，保证高亮与真实状态一致
  @Local selectedIndex: number = 0;
  // 待确认的自动确认模式（paired/on），确认后落地
  @Local pendingAutoConfirmMode: string = ''
  // 待编辑的 PIN 值（B 类输入弹窗内容区）
  @Local pendingPinValue: string = ''
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1

  // 监听真实模式变化（如"恢复默认"重置为 off），同步分段高亮
  @Monitor('viewModel.autoConfirmMode')
  onAutoConfirmModeChange(): void {
    this.selectedIndex = this.getAutoConfirmIndex();
  }

  // 官方分段按钮（TabSegmentButtonV2）：自动确认请求三选一（关 / 收藏 / 开）
  private segmentedItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: $r('app.string.auto_confirm_off') },
    { text: $r('app.string.auto_confirm_favorites') },
    { text: $r('app.string.auto_confirm_on') }
  ]);

  // 当前自动确认模式对应的分段下标
  private getAutoConfirmIndex(): number {
    for (let i = 0; i < AUTO_CONFIRM_VALUES.length; i++) {
      if (AUTO_CONFIRM_VALUES[i] === this.viewModel.autoConfirmMode) {
        return i;
      }
    }
    return 0; // 默认 off
  }

  // 切换自动确认模式：off 直接生效；paired/on 需先弹确认，取消则回退高亮
  private applyAutoConfirm(index: number): void {
    let next = AUTO_CONFIRM_VALUES[index];
    if (next === this.viewModel.autoConfirmMode) {
      // 点击当前已选项：无需变更，复位高亮（防止控件视觉停留）
      this.selectedIndex = index;
      return;
    }
    if (next === 'off') {
      this.viewModel.setAutoConfirmMode('off');
      this.selectedIndex = index;
      return;
    }
    // paired / on：先弹确认，确认回调里才落地；取消时把高亮回退到真实值
    this.pendingAutoConfirmMode = next;
    this.openAutoConfirmDialog();
    // 暂不更新 selectedIndex，等确认结果；若取消，下方复位
    this.selectedIndex = this.getAutoConfirmIndex();
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
          this.selectedIndex = this.getAutoConfirmIndex();
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
  }

  @Builder
  pinInputContent() {
    Column({ space: DesignTokens.space.sm }) {
      TextInput({ text: this.pendingPinValue })
        .borderRadius(DesignTokens.radius.max)
        .onChange((value: string) => {
          this.pendingPinValue = value;
        })
    }
    .width('100%')
  }

  build() {
    Column() {
      // 卡片外标题（左上角左对齐）
      Column() {
        Text($r('app.string.receive_settings'))
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .margin({ top: DesignTokens.space.card })

      // 卡片（标题在外）
      Column() {
        // 自动确认请求（三选一，使用官方 SegmentButton 分段控件）
        Row() {
          Text($r('app.string.auto_confirm_title'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .alignItems(VerticalAlign.Center)

        TabSegmentButtonV2({
          items: this.segmentedItems,
          selectedIndex: this.selectedIndex,
          $selectedIndex: (index: number) => {
            this.applyAutoConfirm(index);
          },
          enableStateAnimation: true
        })
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
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.openPinInputDialog();
        })

        Text($r('app.string.receive_pin_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })

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
