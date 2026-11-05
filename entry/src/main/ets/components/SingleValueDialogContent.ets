/**
 * SingleValueDialogContent.ets — 完整值弹窗的内容区（跨页公用）
 *
 * 完整值文本单行居中、多行左对齐、超高可滚动，长按可选择复制。
 * 弹窗外壳（CustomContentDialogV2 + 关闭按钮）必须留在调用方 @ComponentV2 的 @Builder 方法内，
 * 以持有 V2 组件构建上下文；本组件只承载内容，避免各页重复实现文本对齐与滚动样式。
 */

import { DesignTokens } from '../common/DesignTokens';
import { resolveSingleLineTextAlign } from '../utils/TextAlignUtil';

@ComponentV2
export struct SingleValueDialogContent {
  @Param value: string = ''
  // 内容区可用宽度（vp，由文本 onAreaChange 获取，用于判定单行 / 多行对齐）
  @Local contentWidth: number = 0

  build() {
    Scroll() {
      Text(this.value)
        .width('100%')
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .textAlign(resolveSingleLineTextAlign(this.getUIContext(), this.value,
          DesignTokens.font.bodyM, this.contentWidth))
        .wordBreak(WordBreak.BREAK_ALL)
        .copyOption(CopyOptions.LocalDevice)
        .onAreaChange((_oldValue: Area, newValue: Area) => {
          // 记录内容区可用宽度（vp），供单行 / 多行对齐判定
          if (typeof newValue.width === 'number') {
            this.contentWidth = newValue.width;
          }
        })
    }
    .width('100%')
    .constraintSize({ maxHeight: 320 })
    .scrollBar(BarState.Auto)
  }
}
