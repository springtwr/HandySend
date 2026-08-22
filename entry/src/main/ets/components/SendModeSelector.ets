import { SendMode } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';

@ComponentV2
export struct SendModeSelector {
  @Param currentMode: string = 'single'
  @Event onModeChange: (mode: SendMode) => void = (_mode: SendMode) => {
  }

  build() {
    Row({ space: 0 }) {
      // 分段 1：单目标（左侧圆角）
      Row() {
        Text($r('app.string.send_mode_single'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor(
            this.currentMode === SendMode.single ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
          .fontWeight(this.currentMode === SendMode.single ? FontWeight.Bold : FontWeight.Normal)
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
      .backgroundColor(
        this.currentMode === SendMode.single ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
      .borderRadius({ topLeft: DesignTokens.radius.md, bottomLeft: DesignTokens.radius.md })
      .onClick(() => {
        this.setMode(SendMode.single);
      })

      // 分段 2：多目标（3 段恒显示，中间段无圆角）
      Row() {
        Text($r('app.string.send_mode_multiple'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor(
            this.currentMode === SendMode.multiple ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
          .fontWeight(this.currentMode === SendMode.multiple ? FontWeight.Bold : FontWeight.Normal)
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
      .backgroundColor(
        this.currentMode === SendMode.multiple ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
      .borderRadius({
        topLeft: 0,
        bottomLeft: 0,
        topRight: 0,
        bottomRight: 0
      })
      .onClick(() => {
        this.setMode(SendMode.multiple);
      })

      // 分段 3：链接分享（右侧圆角）
      Row() {
        Text($r('app.string.send_mode_link'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor(this.currentMode === SendMode.link ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
          .fontWeight(this.currentMode === SendMode.link ? FontWeight.Bold : FontWeight.Normal)
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
      .backgroundColor(
        this.currentMode === SendMode.link ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
      .borderRadius({ topRight: DesignTokens.radius.md, bottomRight: DesignTokens.radius.md })
      .onClick(() => {
        this.setMode(SendMode.link);
      })
    }
    .width('100%')
    .borderRadius(DesignTokens.radius.md)
    .border({ width: 1, color: $r('app.color.border_light') })
  }

  private setMode(mode: SendMode): void {
    this.onModeChange(mode);
  }
}
