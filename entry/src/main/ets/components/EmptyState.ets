/**
 * EmptyState.ets — 公共空态
 *
 * 统一承载「列表/内容为空」的提示：主标题与副提示的字号、颜色、间距与水平居中由本组件固定，
 * 调用点只传文案与开关（是否套卡片、是否占满可用高度并垂直居中、内容区最小高度），不再各自内联样式。
 *
 * 卡片按该页条目形态跟随：条目是卡片的页面由调用点开启 useCard，条目非卡片的页面与已被卡片包裹的
 * 空态保持关闭，避免出现第二层卡片与双重内边距。卡片左右内边距与条目文字对齐（16vp），上下内边距取
 * 32vp；面板高度统一取 `DesignTokens.size.emptyStateMinHeight` 为下限，使高度不随文案行数与窗口宽度变化。
 */

import { DesignTokens } from '../common/DesignTokens';

@ComponentV2
export struct EmptyState {
  /** 主标题文案（必填） */
  @Require @Param mainText: ResourceStr
  /** 副提示文案（可缺省，缺省时不渲染副提示） */
  @Param hintText: ResourceStr | undefined = undefined
  /** 副提示语义色（可缺省，缺省取三级文字色） */
  @Param hintColor: ResourceColor | undefined = undefined
  /** 是否套用与同页条目同款的卡片（列表行级空态开启） */
  @Param useCard: boolean = false
  /** 是否占满可用高度并垂直居中（整页空态开启） */
  @Param fillHeight: boolean = false
  /**
   * 非卡片型空态的内容区最小高度（vp，可缺省）。
   * 卡片型空态的面板高度由组件统一取 `DesignTokens.size.emptyStateMinHeight`，无需调用方传入；
   * 非卡片型空态自身无卡片、处在他人卡片内，由调用方按外层卡片的内边距反推传入。
   */
  @Param minHeight: number | undefined = undefined

  /**
   * 内容区最小高度：卡片型空态的卡片即面板，统一取面板最小高度，使高度不随文案行数与窗口宽度变化；
   * 非卡片型空态由调用方给出，用于使其所在的外层卡片达到同一面板高度。
   */
  private contentMinHeight(): number {
    if (this.useCard) {
      return DesignTokens.size.emptyStateMinHeight
    }
    return this.minHeight ?? 0
  }

  build() {
    // 外层只负责占位与居中：卡片装饰落在内层，避免 fillHeight 开启时卡片被拉伸成整页高的面板
    Column() {
      Column({ space: DesignTokens.space.tiny }) {
        Text(this.mainText)
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)

        if (this.hintText !== undefined) {
          Text(this.hintText)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor(this.hintColor ?? $r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      // 面板最小高度：卡片型取统一值、非卡片型取调用方给出的内容区最小值，
      // 使各处空态面板同高，不因文案行数（窄屏折行）或有无副提示而变化
      .constraintSize({ minHeight: this.contentMinHeight() })
      .justifyContent(FlexAlign.Center)
      // 卡片内边距：左右与同页条目文字对齐（16vp），上下取 32vp；卡片高度另由上方最小高度兜底
      .padding({
        left: this.useCard ? DesignTokens.space.md : 0,
        right: this.useCard ? DesignTokens.space.md : 0,
        top: this.useCard ? DesignTokens.space.xl : 0,
        bottom: this.useCard ? DesignTokens.space.xl : 0
      })
      .backgroundColor(this.useCard ? $r('app.color.card_background') : Color.Transparent)
      .borderRadius(this.useCard ? DesignTokens.radius.lg : 0)
      .border({ width: this.useCard ? DesignTokens.component.borderSlim : 0, color: $r('app.color.border_light') })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(this.fillHeight ? FlexAlign.Center : FlexAlign.Start)
    // 占满可用高度：布局权重适用于自定义组件直接参与容器主轴分配的场景，
    // 最小高度百分比覆盖组件被通用属性包装后布局权重不参与分配的场景
    .layoutWeight(this.fillHeight ? 1 : 0)
    .constraintSize({ minHeight: this.fillHeight ? '100%' : 0 })
  }
}
