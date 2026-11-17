/**
 * EmptyState.ets — 公共空态
 *
 * 统一承载「列表/内容为空」的提示：主标题与副提示的字号、颜色、间距与水平居中由本组件固定，
 * 调用点只传文案、开关（是否套卡片、是否占满可用高度并垂直居中）
 * 与可选的操作入口、地址入口，样式统一由本组件维护。
 *
 * 卡片按该页条目形态跟随：条目是卡片的页面由调用点开启 useCard，条目非卡片的页面、页面背景上的整段
 * 空态与已被卡片包裹的空态保持关闭，避免出现第二层卡片与双重内边距。卡片左右内边距与条目文字对齐（16vp），
 * 上下内边距取 32vp；卡片型空态的面板最小高度统一取 `DesignTokens.size.emptyStateMinHeight`，
 * 使高度不随文案行数与窗口宽度变化。
 */

import { DesignTokens } from '../common/DesignTokens';
import { EmptyStateLink } from '../model/Types';

@ComponentV2
export struct EmptyState {
  /** 主标题文案（必填） */
  @Require @Param mainText: ResourceStr
  /** 副提示文案（可缺省，缺省时不渲染副提示） */
  @Param hintText: ResourceStr | undefined = undefined
  /** 副提示语义色（可缺省，缺省取三级文字色） */
  @Param hintColor: ResourceColor | undefined = undefined
  /** 操作入口文案（可缺省，缺省时不渲染操作入口） */
  @Param actionText: ResourceStr | undefined = undefined
  /** 操作入口图标（可缺省，缺省时不渲染图标） */
  @Param actionIcon: Resource | undefined = undefined
  /** 操作入口点击回调 */
  @Event onAction: () => void = () => {
  }
  /** 可点击地址列表（可缺省，缺省时不渲染地址区） */
  @Param links: Array<EmptyStateLink> | undefined = undefined
  /** 地址区上方的说明文案（可缺省） */
  @Param linksHint: ResourceStr | undefined = undefined
  /** 地址点击回调（携带被点击的 url，由调用点决定打开方式） */
  @Event onLinkClick: (url: string) => void = (_url: string) => {
  }
  /** 是否套用与同页条目同款的卡片（同页条目是卡片的空态开启） */
  @Param useCard: boolean = false
  /** 是否占满可用高度并垂直居中（整页空态开启） */
  @Param fillHeight: boolean = false

  /** 地址列表（缺省时为空数组，便于渲染条件判断）。 */
  private linkItems(): Array<EmptyStateLink> {
    return this.links ?? [];
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

        // 可选操作入口：浅蓝底胶囊 + 蓝色图标文字，与页面内的次级按钮同款；
        // 视觉高度 32vp，响应区纵向扩展到 48vp 以满足热区规范
        if (this.actionText !== undefined) {
          Button() {
            Row({ space: DesignTokens.space.xxs }) {
              if (this.actionIcon !== undefined) {
                SymbolGlyph(this.actionIcon)
                  .fontSize(DesignTokens.font.subtitleM)
                  .fontColor([$r('app.color.ip_blue_text')])
              }
              Text(this.actionText)
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.ip_blue_text'))
            }
            .alignItems(VerticalAlign.Center)
            .justifyContent(FlexAlign.Center)
          }
          .height(32)
          .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
          .backgroundColor($r('app.color.accent_blue_bg'))
          .borderRadius(DesignTokens.radius.max)
          .margin({ top: DesignTokens.space.xxs })
          .responseRegion({
            x: 0,
            y: -8,
            width: '100%',
            height: 48
          })
          .onClick(() => {
            this.onAction();
          })
        }

        // 可选地址区：说明文案在上，每条地址以名称在上、完整地址在下两行展示，整块可点击；
        // 说明与地址之间取极小间距，使安装提示与下载地址紧邻；长地址允许在任意字符处折行，窄屏不溢出
        if (this.linkItems().length > 0) {
          Column({ space: DesignTokens.space.mini }) {
            if (this.linksHint !== undefined) {
              Text(this.linksHint)
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Center)
            }

            ForEach(this.linkItems(), (link: EmptyStateLink, index: number) => {
              Column({ space: DesignTokens.space.mini }) {
                Text(link.label)
                  .fontSize(DesignTokens.font.bodyS)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                Text(link.url)
                  .fontSize(DesignTokens.font.bodyS)
                  .fontColor($r('app.color.ip_blue_text'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .wordBreak(WordBreak.BREAK_ALL)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              // 上下留出内边距，扩大点击范围
              .padding({ top: DesignTokens.space.xxs, bottom: DesignTokens.space.xxs })
              .onClick(() => {
                this.onLinkClick(link.url);
              })
              .id('empty_state_link_' + index)
            }, (link: EmptyStateLink) => link.url)
          }
          .width('100%')
          .margin({ top: DesignTokens.space.tiny })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      // 面板最小高度：卡片型取统一值，非卡片型不设下限（由所在容器决定），
      // 使卡片型空态面板同高，不因文案行数（窄屏折行）或有无副提示而变化
      .constraintSize({ minHeight: this.useCard ? DesignTokens.size.emptyStateMinHeight : 0 })
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
