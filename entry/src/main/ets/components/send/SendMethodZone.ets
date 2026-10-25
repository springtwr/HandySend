/**
 * SendMethodZone.ets — 发送页方式区
 *
 * 「不经设备发现的其它发起/接收方式」的两个图标菜单入口，由方式注册表驱动：
 * 「网页」（网页发送 / 网页接收）与「其它方式」（指定 IP 等）。
 * 网页发送要求先有内容、网页接收即开即用，故各自独立入口。
 * 新增方式仍无需修改发送页。
 *
 * 该区域无自身状态、仅组合既有 UI 片段，故实现为全局 @Builder（而非自定义组件），
 * 避免为纯结构引入额外的组件实例开销。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { TransferMethodDescriptor, TransferMethodGroup } from '../../model/transfer/Registries';
import { listMethodsByGroup } from '../../service/transfer/TransferMethodRegistry';

// 中文菜单文案较短，可略窄于系统默认两栅格；其他语言保留默认宽度避免折行
const WEB_METHOD_MENU_WIDTH: number = 150;

/** 方式区参数：网页服务运行中时其入口图标叠绿点（overlay 零高度）；
 * 网页两项按方向开关出示末尾勾选（勾选表达允许意向，不表达传输中）。 */
export interface SendMethodZoneOptions {
  isWebActive: boolean
  webSendActive: boolean
  webReceiveActive: boolean
  // 中文界面收紧网页菜单宽度；其他语言沿用系统默认宽度
  webMenuCompact: boolean
}

/** 方式菜单项：单个入口的可点击条目（活跃方向末尾出系统勾选）。
 * 注意：`endIcon` 不支持 symbol 图标，symbol 必须走 `symbolEndIcon`
 *（传 `SymbolGlyphModifier`），否则勾选静默不显示。
 * `tightEnd` 为真时把条目右缘向菜单内边距借 4vp，收紧勾选右侧留白。 */
@Builder
function methodItem(descriptor: TransferMethodDescriptor, checked: boolean, tightEnd: boolean) {
  MenuItem({
    content: descriptor.label,
    symbolEndIcon: checked ? new SymbolGlyphModifier($r('sys.symbol.checkmark')) : undefined
  })
  .enabled(descriptor.available())
  .margin({ right: tightEnd ? -DesignTokens.space.xxs : 0 })
  .onClick(() => {
    descriptor.action();
  })
}

/** 「网页」组菜单项（网页发送 / 网页接收，活跃方向带勾选）。 */
@Builder
function webMenuItems(options: SendMethodZoneOptions) {
  Repeat(listMethodsByGroup(TransferMethodGroup.web))
    .each((ri: RepeatItem<TransferMethodDescriptor>) => {
      methodItem(ri.item, ri.item.key === 'web-send' ? options.webSendActive :
        (ri.item.key === 'web-receive' ? options.webReceiveActive : false), true)
    })
    .key((item: TransferMethodDescriptor) => item.key)
}

/** 「网页」组菜单（中文界面略窄以收紧勾选间距，其他语言沿用默认宽度）。 */
@Builder
function webMenu(options: SendMethodZoneOptions) {
  if (options.webMenuCompact) {
    Menu() {
      webMenuItems(options)
    }
    .width(WEB_METHOD_MENU_WIDTH)
  } else {
    Menu() {
      webMenuItems(options)
    }
  }
}

/** 「其它方式」组菜单（指定 IP 等）。 */
@Builder
function otherMenu() {
  Menu() {
    Repeat(listMethodsByGroup(TransferMethodGroup.other))
      .each((ri: RepeatItem<TransferMethodDescriptor>) => {
        methodItem(ri.item, false, false)
      })
      .key((item: TransferMethodDescriptor) => item.key)
  }
}

/** 发送页方式区：网页 / 其它方式两个图标入口 + 刷新按钮（调用方同行等距）。 */
@Builder
export function SendMethodZone(options: SendMethodZoneOptions) {
  // 两个方式入口与刷新按钮使用同一间距（space.md），使右侧图标行整体等距对齐
  Row({ space: DesignTokens.space.md }) {
    // 网页方式入口：worldclock 图标 + 网页发送/接收菜单；
    // 服务运行时图标右上角叠绿点（overlay，不占纵向空间；常驻节点按透明度显隐）
    Stack() {
      SymbolGlyph($r('sys.symbol.worldclock'))
        .fontSize(DesignTokens.font.titleM)
        .fontColor([$r('app.color.text_primary')])

      Circle({ width: DesignTokens.size.badgeDot, height: DesignTokens.size.badgeDot })
        .fill($r('app.color.success_green'))
        .stroke($r('app.color.page_background'))
        .strokeWidth(DesignTokens.size.badgeRing)
        .offset({ x: DesignTokens.space.tiny, y: -DesignTokens.space.tiny })
        .opacity(options.isWebActive ? 1 : 0)
    }
    .responseRegion({
      x: -12,
      y: -12,
      width: 48,
      height: 48
    })
    .bindMenu(webMenu(options))
    .accessibilityGroup(true)
    .id('send_method_web')

    // 其它方式入口：图标 + 指定 IP 等菜单
    SymbolGlyph($r('sys.symbol.ellipsis_circle'))
      .fontSize(DesignTokens.font.titleM)
      .fontColor([$r('app.color.text_primary')])
      .responseRegion({
        x: -12,
        y: -12,
        width: 48,
        height: 48
      })
      .bindMenu(otherMenu)
      .accessibilityGroup(true)
      .id('send_method_entry')
  }
  .alignItems(VerticalAlign.Center)
}
