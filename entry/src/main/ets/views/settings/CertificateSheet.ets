import { DesignTokens } from '../../common/DesignTokens';
import { CertificateViewModel } from '../../viewmodel/CertificateViewModel';
import { AlertDialogV2, AdvancedDialogV2Button, promptAction } from '@kit.ArkUI';

// @Builder 按引用传递所需的参数类（对象字面量需显式类型，禁止匿名对象）
// 按值传递时状态变量变化不会触发 @Builder 内部 UI 刷新，因此封装为对象传参。
class CertificatePemBlockParam {
  label: ResourceStr = ''
  pem: string = ''
}

// 证书半屏弹窗内容：三段 PEM（证书/公钥/私钥）展示 + 重置证书。
// 自持视图模型，弹窗打开时加载安全上下文。
@ComponentV2
export struct CertificateSheet {
  @Local viewModel: CertificateViewModel = new CertificateViewModel()
  // 当前打开的确认弹窗 id（关闭时使用）
  private activeDialogId: number = -1

  aboutToAppear(): void {
    this.viewModel.loadCertificate();
  }

  // 弹出确认框，确认后才执行证书重置
  private openResetCertConfirmDialog(): void {
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.resetCertConfirmDialog();
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

  // 确认后执行重置：成功 toast，失败区分「传输进行中」与一般失败
  private async performResetCertificate(): Promise<void> {
    let success: boolean = await this.viewModel.resetCertificate();
    if (success) {
      this.showToast($r('app.string.reset_cert_success'));
    } else {
      let message: ResourceStr = this.viewModel.resetBlockedByBusy ?
        $r('app.string.reset_cert_busy') : $r('app.string.reset_cert_failed');
      this.showToast(message);
    }
  }

  private showToast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_e) {
      // 忽略
    }
  }

  @Builder
  resetCertConfirmDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.reset_certificate_button'),
      content: $r('app.string.reset_cert_confirm_content'),
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_cancel'),
        action: () => {
          this.closeActiveDialog();
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_confirm'),
        action: () => {
          this.closeActiveDialog();
          this.performResetCertificate();
        }
      })
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  securityPemBlock(param: CertificatePemBlockParam) {
    Column() {
      Text(param.label)
        .fontSize(DesignTokens.font.bodyM)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      if (param.pem.length > 0) {
        // PEM 为多行短文本（每行 ≤64 字符）
        Column() {
          Text(param.pem)
            .fontSize(DesignTokens.font.captionM)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .wordBreak(WordBreak.BREAK_ALL)
            .copyOption(CopyOptions.LocalDevice)
        }
        .width('100%')
        .backgroundColor($r('app.color.page_background'))
        .borderRadius(DesignTokens.radius.md)
        .padding(DesignTokens.space.sm)
        .margin({ top: DesignTokens.space.xxs })
      } else {
        Text('-')
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: DesignTokens.space.xxs })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.sm })
  }

  build() {
    // 内容区用 Scroll 承载长 PEM，保证任意弹窗高度下三段文本完整可达
    Scroll() {
      Column({ space: DesignTokens.space.sm }) {
        this.securityPemBlock({ label: $r('app.string.certificate_label'), pem: this.viewModel.certPem })
        this.securityPemBlock({ label: $r('app.string.public_key_label'), pem: this.viewModel.publicKeyPem })
        this.securityPemBlock({ label: $r('app.string.private_key_label'), pem: this.viewModel.privateKeyPem })

        Button($r('app.string.reset_certificate_button'))
          .width('100%')
          .height(DesignTokens.size.thumbSm)
          .backgroundColor($r('app.color.danger_red'))
          .fontColor($r('app.color.text_on_color'))
          .borderRadius(DesignTokens.radius.md)
          .margin({ top: DesignTokens.space.sm })
          .onClick(() => {
            // 弹确认框，确认后才执行证书重置
            this.openResetCertConfirmDialog();
          })
          .id('settings_reset_certificate_btn')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: DesignTokens.space.md,
        right: DesignTokens.space.md,
        bottom: DesignTokens.space.lg
      })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
  }
}
