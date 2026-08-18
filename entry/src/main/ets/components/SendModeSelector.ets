import { SendMode } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';

@Component
export struct SendModeSelector {
  @Prop currentMode: string = 'single'
  @Prop hideShareByLink: boolean = false
  onModeChange?: (mode: SendMode) => void

  build() {
    Row({ space: 0 }) {
      // Segment 1: Single target (left rounded corners)
      Row() {
        Text($r('app.string.send_mode_single'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor(this.currentMode === SendMode.single ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
          .fontWeight(this.currentMode === SendMode.single ? FontWeight.Bold : FontWeight.Normal)
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
      .backgroundColor(this.currentMode === SendMode.single ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
      .borderRadius({ topLeft: DesignTokens.radius.md, bottomLeft: DesignTokens.radius.md })
      .onClick(() => {
        this.setMode(SendMode.single);
      })

      // Segment 2: Multi-target (no rounded corners when 3 segments, right rounded when 2)
      Row() {
        Text($r('app.string.send_mode_multiple'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor(this.currentMode === SendMode.multiple ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
          .fontWeight(this.currentMode === SendMode.multiple ? FontWeight.Bold : FontWeight.Normal)
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
      .backgroundColor(this.currentMode === SendMode.multiple ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
      .borderRadius(this.hideShareByLink
        ? { topRight: DesignTokens.radius.md, bottomRight: DesignTokens.radius.md }
        : { topLeft: 0, bottomLeft: 0, topRight: 0, bottomRight: 0 })
      .onClick(() => {
        this.setMode(SendMode.multiple);
      })

      // Segment 3: Link sharing (right rounded corners, hidden when hideShareByLink)
      if (!this.hideShareByLink) {
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
        .backgroundColor(this.currentMode === SendMode.link ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
        .borderRadius({ topRight: DesignTokens.radius.md, bottomRight: DesignTokens.radius.md })
        .onClick(() => {
          this.setMode(SendMode.link);
        })
      }
    }
    .width('100%')
    .borderRadius(DesignTokens.radius.md)
    .border({ width: 1, color: $r('app.color.border_light') })
  }

  private setMode(mode: SendMode): void {
    if (this.onModeChange !== undefined) {
      this.onModeChange(mode);
    }
  }
}
