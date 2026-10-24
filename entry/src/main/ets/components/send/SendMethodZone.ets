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
import { TransferMethodDescriptor, TransferMethodGroup } from '../../model/transfer/Registries';
import { listMethodsByGroup } from '../../service/transfer/TransferMethodRegistry';

/** 方式区参数：网页服务运行中时其入口图标叠绿点（overlay 零高度）；
 * 网页菜单文案由父组件按方向挂载态与未终态会话数解析好传入。 */
export interface SendMethodZoneOptions {
  isWebActive: boolean
  webSendLabel: ResourceStr
  webReceiveLabel: ResourceStr
}

/** 方式菜单项：单个入口的可点击条目（网页两项用父组件解析好的文案）。 */
@Builder
function methodItem(descriptor: TransferMethodDescriptor, label: ResourceStr) {
  MenuItem({ content: label })
    .enabled(descriptor.available())
    .onClick(() => {
      descriptor.action();
    })
}

/** 「网页」组菜单（网页发送 / 网页接收，按方向带后缀）。 */
@Builder
function webMenu(options: SendMethodZoneOptions) {
  Menu() {
    Repeat(listMethodsByGroup(TransferMethodGroup.web))
      .each((ri: RepeatItem<TransferMethodDescriptor>) => {
        methodItem(ri.item, ri.item.key === 'web-send' ? options.webSendLabel :
          (ri.item.key === 'web-receive' ? options.webReceiveLabel : ri.item.label))
      })
      .key((item: TransferMethodDescriptor) => item.key)
  }
}

/** 「其它方式」组菜单（指定 IP 等）。 */
@Builder
function otherMenu() {
  Menu() {
    Repeat(listMethodsByGroup(TransferMethodGroup.other))
      .each((ri: RepeatItem<TransferMethodDescriptor>) => {
        methodItem(ri.item, ri.item.label)
      })
      .key((item: TransferMethodDescriptor) => item.key)
  }
}

/** 发送页方式区：网页 / 其它方式两个图标入口 + 刷新按钮（调用方同行等距）。 */
@Builder
export function SendMethodZone(options: SendMethodZoneOptions) {
  // 两个方式入口与刷新按钮使用同一间距（space.md），使右侧图标行整体等距对齐
  Row({ space: DesignTokens.space.md }) {
    // 网页方式入口：图标 + 网页发送/接收菜单；
    // 服务运行时图标右上角叠绿点（overlay，不占纵向空间）
    Stack() {
      SymbolGlyph($r('sys.symbol.link'))
        .fontSize(DesignTokens.font.titleM)
        .fontColor([$r('app.color.text_primary')])

      if (options.isWebActive) {
        Circle({ width: DesignTokens.size.badgeDot, height: DesignTokens.size.badgeDot })
          .fill($r('app.color.success_green'))
          .stroke($r('app.color.page_background'))
          .strokeWidth(DesignTokens.size.badgeRing)
          .position({ x: '64%', y: '10%' })
      }
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
