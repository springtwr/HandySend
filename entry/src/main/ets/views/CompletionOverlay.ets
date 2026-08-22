import { curves } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';

// 传输完成/取消结果浮层（从 MainTabFloating 拆出）。
// 纯展示 + 内部弹入动画；关闭经回调上抛。
@ComponentV2
export struct CompletionOverlay {
  @Param show: boolean = false
  @Param title: string = ''
  @Param message: string = ''
  @Event onDismiss: () => void = () => {
  }
  @Local checkScale: number = 0

  build() {
    if (this.show) {
      Column() {
        Column() {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(64)
            .fontColor([$r('app.color.success_green')])
            .scale({ x: this.checkScale, y: this.checkScale })
            .onAppear(() => {
              setTimeout(() => {
                this.getUIContext()
                  .animateTo({
                    duration: 500,
                    curve: curves.springMotion(DesignTokens.animation.springStiffness,
                      DesignTokens.animation.springDamping)
                  }, () => {
                    this.checkScale = 1;
                  });
              }, 200);
            })

          Text(this.title)
            .fontSize(DesignTokens.font.titleS)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .margin({ top: DesignTokens.space.md })

          Text(this.message)
            .fontSize(DesignTokens.font.subtitleM)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .margin({ top: DesignTokens.space.xs })

          Button($r('app.string.dialog_confirm'))
            .width('80%')
            .height(DesignTokens.hotspot.minSize)
            .fontSize(DesignTokens.font.subtitleM)
            .fontColor($r('app.color.text_on_color'))
            .backgroundColor($r('app.color.accent_blue'))
            .borderRadius(DesignTokens.radius.max)
            .margin({ top: DesignTokens.space.xl })
            .onClick(() => {
              this.onDismiss();
            })
        }
        .width('80%')
        .constraintSize({ maxWidth: 360 })
        .padding({
          top: DesignTokens.space.xl,
          bottom: 28,
          left: DesignTokens.space.lg,
          right: DesignTokens.space.lg
        })
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .shadow({ radius: 20, color: $r('app.color.shadow_color'), offsetY: 4 })
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.overlay_mask'))
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        this.onDismiss();
      })
    }
  }
}
