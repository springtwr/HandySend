/**
 * SendMethodZone.ets — 发送页方式区
 *
 * 网页图标直接进入「网页传输」面板；
 * 「其它方式」保留菜单入口（指定 IP 等）。
 * 网页服务运行中时网页图标右上角叠绿点（overlay 不占纵向空间）。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { TransferMethodDescriptor, TransferMethodGroup } from '../../model/transfer/Registries';
import { listMethodsByGroup } from '../../service/transfer/TransferMethodRegistry';

/** 方式区参数：网页服务运行中时其入口图标叠绿点（overlay 零高度）。 */
export interface SendMethodZoneOptions {
  isWebActive: boolean
  onOpenWeb: () => void
  onOpenPortal: () => void
}

/** 方式菜单项：单个入口的可点击条目。 */
@Builder
function methodItem(descriptor: TransferMethodDescriptor) {
  MenuItem({
    content: descriptor.label
  })
  .enabled(descriptor.available())
  .onClick(() => {
    descriptor.action();
  })
}

/** 「其它方式」组菜单（指定 IP 等）。 */
@Builder
function otherMenu() {
  Menu() {
    Repeat(listMethodsByGroup(TransferMethodGroup.other))
      .each((ri: RepeatItem<TransferMethodDescriptor>) => {
        methodItem(ri.item)
      })
      .key((item: TransferMethodDescriptor) => item.key)
  }
}

/** 发送页方式区：网页 / 其它方式两个图标入口 + 刷新按钮（调用方同行等距）。 */
@Builder
export function SendMethodZone(options: SendMethodZoneOptions) {
  // 两个方式入口与刷新按钮使用同一间距（space.md），使右侧图标行整体等距对齐
  Row({ space: DesignTokens.space.md }) {
    // 网页方式入口：点击直接进入网页传输面板；服务运行时图标右上角叠绿点
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
    .onClick(() => {
      options.onOpenWeb();
    })
    .accessibilityGroup(true)
    .id('send_method_web')

    // 在线服务入口：进入站点导航页
    Stack() {
      SymbolGlyph($r('sys.symbol.icloud'))
        .fontSize(DesignTokens.font.titleM)
        .fontColor([$r('app.color.text_primary')])
    }
    .responseRegion({
      x: -12,
      y: -12,
      width: 48,
      height: 48
    })
    .onClick(() => {
      options.onOpenPortal();
    })
    .accessibilityGroup(true)
    .id('send_method_portal')

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
