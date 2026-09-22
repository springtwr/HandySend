/**
 * SendMethodZone.ets — 发送页方式区
 *
 * 「不经设备发现的其它发起/接收方式」的两个图标菜单入口，由方式注册表驱动：
 * 「网页」（网页发送 / 网页接收）与「其它方式」（指定 IP 等）。
 * 新增方式仍无需修改发送页。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { TransferMethodDescriptor, TransferMethodGroup } from '../../model/transfer/Registries';
import { listMethodsByGroup } from '../../service/transfer/TransferMethodRegistry';

@ComponentV2
export struct SendMethodZone {
  @Builder
  methodItem(descriptor: TransferMethodDescriptor) {
    MenuItem({ content: descriptor.label })
      .enabled(descriptor.available())
      .onClick(() => {
        descriptor.action();
      })
  }

  /** 「网页」组菜单（网页发送 / 网页接收）。 */
  @Builder
  webMenu() {
    Menu() {
      Repeat(listMethodsByGroup(TransferMethodGroup.web))
        .each((ri: RepeatItem<TransferMethodDescriptor>) => {
          this.methodItem(ri.item)
        })
        .key((item: TransferMethodDescriptor) => item.key)
    }
  }

  /** 「其它方式」组菜单（指定 IP 等）。 */
  @Builder
  otherMenu() {
    Menu() {
      Repeat(listMethodsByGroup(TransferMethodGroup.other))
        .each((ri: RepeatItem<TransferMethodDescriptor>) => {
          this.methodItem(ri.item)
        })
        .key((item: TransferMethodDescriptor) => item.key)
    }
  }

  build() {
    // 两个方式入口与刷新按钮使用同一间距（space.md），使右侧图标行整体等距对齐
    Row({ space: DesignTokens.space.md }) {
      // 网页方式入口：图标 + 网页发送/接收菜单
      SymbolGlyph($r('sys.symbol.link'))
        .fontSize(DesignTokens.font.titleM)
        .fontColor([$r('app.color.text_primary')])
        .responseRegion({
          x: -12,
          y: -12,
          width: 48,
          height: 48
        })
        .bindMenu(this.webMenu)
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
        .bindMenu(this.otherMenu)
        .accessibilityGroup(true)
        .id('send_method_entry')
    }
    .alignItems(VerticalAlign.Center)
  }
}
