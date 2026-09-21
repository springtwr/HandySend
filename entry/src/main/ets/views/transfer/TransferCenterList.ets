/**
 * TransferCenterList.ets — 传输中心会话列表
 *
 * 单一「会话」列表：进行中 / 待确认 / 终态可见窗口内会话与持久化历史合并展示，
 * 按会话创建时间倒序排列（历史条目无创建时间时回退完成时间）。
 * 行序列（条目 / 空态）在 ViewModel 于数据变更时一次性构建并缓存，
 * 本组件通过**单一** `Repeat(virtualScroll)` 直接渲染该缓存，不在 build 中重算行模型、
 * 也不逐行同步读取资源（不使用 ListItemGroup，避免嵌套分组导致的滚动卡死）。
 * 列表标题与入口由外层标题栏承载，页内不再重复。
 */

import { DesignTokens } from '../../common/DesignTokens';
import {
  CenterRow,
  ROW_EMPTY,
  ROW_SESSION,
  SessionRowModel,
  TransferCenterViewModel,
  rowAwaitingConfirm,
  rowHasByteProgress,
  rowIsTerminal,
  rowPercent,
  rowStage,
  rowStageText
} from '../../viewmodel/TransferCenterViewModel';
import { SessionStatusBadge } from './SessionStatusBadge';
import { hasDisplayText } from '../../service/transfer/adapters/SessionAdapter';

@ComponentV2
export struct TransferCenterList {
  @Require @Param viewModel: TransferCenterViewModel
  // 滚动控制器由壳层下传：壳层需将它绑定到导航组件（驱动标题栏滚动模糊）与页签控制器
  @Require @Param scroller: Scroller
  @Event onOpenSession: (sessionId: string) => void = (_sessionId: string) => {
  }
  // 滚动增量上抛（供主页页签栏滚动感知隐藏动画）
  @Event onScrollDelta: (deltaY: number, absY: number) => void = (_deltaY: number, _absY: number) => {
  }

  /** 来源协议文字徽标（复用会话卡片徽标样式）。 */
  @Builder
  sourceBadge(text: ResourceStr) {
    Text(text)
      .fontSize(DesignTokens.font.captionM)
      .fontColor($r('app.color.ip_blue_text'))
      .backgroundColor($r('app.color.accent_blue_bg'))
      .padding({
        left: DesignTokens.space.tiny,
        right: DesignTokens.space.tiny,
        top: DesignTokens.space.mini,
        bottom: DesignTokens.space.mini
      })
      .borderRadius(DesignTokens.radius.sm)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
  }

  /**
   * 会话条目三行结构：
   * 第一行方向文案（发给 / 来自）；第二行设备昵称 + 来源协议徽标 + 状态徽标；
   * 第三行时间（精确到秒）+ 文件数量。进行中且具备字节进度时追加独立进度行；
   * 终态仅以状态徽标呈现结果、不展示进度。
   */
  @Builder
  sessionRow(row: SessionRowModel) {
    Row({ space: DesignTokens.space.sm }) {
      Column({ space: DesignTokens.space.mini }) {
        // 第一行：传输方向文案
        Text(row.directionLabel)
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        // 第二行：设备昵称 + 来源协议徽标 + 状态徽标（终态为结果徽标）
        Row({ space: DesignTokens.space.tiny }) {
          Text(row.peerName.length > 0 ? row.peerName : $r('app.string.session_peer_unknown_device'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          this.sourceBadge(row.sourceLabel)
          SessionStatusBadge({ stage: rowStage(row), stageText: rowStageText(row) })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 第三行：时间（精确到秒）+ 文件数量
        Row({ space: DesignTokens.space.xxs }) {
          Text(row.timeText)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
          Text('·')
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_tertiary'))
          Text(row.fileCountText)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 进行中：有字节进度才展示独立进度行；无字节进度改由阶段文案表达；终态不展示进度。
        if (!rowIsTerminal(row)) {
          if (rowHasByteProgress(row)) {
            Row({ space: DesignTokens.space.sm }) {
              Progress({ value: rowPercent(row), total: 100, type: ProgressType.Linear })
                .width('100%')
                .height(DesignTokens.size.progressBarHeight)
                .color($r('app.color.accent_blue'))
                .backgroundColor($r('app.color.border_light'))
                .layoutWeight(1)
              Text(Math.round(rowPercent(row)) + '%')
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .width(DesignTokens.space.xl + 6)
                .textAlign(TextAlign.End)
            }
            .width('100%')
          } else if (hasDisplayText(rowStageText(row))) {
            Text(rowStageText(row))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (rowAwaitingConfirm(row)) {
        Row({ space: DesignTokens.space.xxs }) {
          Button($r('app.string.session_detail_confirm'))
            .fontSize(DesignTokens.font.bodyS)
            .height(36)
            .onClick(() => {
              this.viewModel.confirm(row.sessionId);
            })
          Button($r('app.string.session_detail_decline'))
            .fontSize(DesignTokens.font.bodyS)
            .height(36)
            .backgroundColor($r('app.color.page_background'))
            .fontColor($r('app.color.text_secondary'))
            .onClick(() => {
              this.viewModel.decline(row.sessionId);
            })
        }
      }
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      // 注册表内可见会话进入实时详情；持久化历史条目进入只读摘要详情
      this.onOpenSession(row.sessionId);
    })
    .accessibilityText(row.peerName)
    .id('transfer_center_session_item')
  }

  /** 空态（合并列表无任何条目）。 */
  @Builder
  emptyBlock() {
    Column({ space: DesignTokens.space.tiny }) {
      Text($r('app.string.transfer_center_empty_title'))
        .fontSize(DesignTokens.font.subtitleM)
        .fontColor($r('app.color.text_primary'))
      Text($r('app.string.transfer_center_empty_hint'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(DesignTokens.space.xl)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    .alignItems(HorizontalAlign.Center)
    .id('transfer_center_empty_state')
  }

  build() {
    List({ space: DesignTokens.space.tiny, scroller: this.scroller }) {
      // 筛选 / 条目 / 空态同处一个顶层 Repeat 的直接子级 ListItem 序列，
      // 不使用 ListItemGroup，避免嵌套分组在虚拟滚动下的卡死。
      Repeat(this.viewModel.rows)
        .each((ri: RepeatItem<CenterRow>) => {
          ListItem() {
            if (ri.item.kind === ROW_SESSION) {
              if (ri.item.session !== undefined) {
                this.sessionRow(ri.item.session)
              }
            } else if (ri.item.kind === ROW_EMPTY) {
              this.emptyBlock()
            }
          }
        })
        .key((item: CenterRow) => item.key)
        .virtualScroll()
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .scrollBar(BarState.Off)
    // 内容不足一屏也保持回弹（alwaysEnabled）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 滚动容器不裁剪：滚动中的条目可绘制到标题栏区域内，使毛玻璃背板有内容可透出
    .clip(false)
    // 渲染范围控制：Repeat 开启 virtualScroll 后按显示区 + 预加载区懒加载，cachedCount 控制预加载条目数；
    // 第二个入参置真让预加载条目一并参与绘制，使穿透到标题栏下方的条目不会因超出缓存范围而消失
    .cachedCount(4, true)
    // 悬浮页签（barOverlap + barFloatingStyle）下，列表内容应能延伸到页签背后以保持
    // 悬浮观感：不用底部 padding（避免压缩内容区导致页签背后空白），改用 contentEndOffset
    // 精确控制滚动到底时末条与显示区底边的距离，保证末条不被页签遮挡
    // 列表内容与标题栏的顶部间距：原先由页内顶部操作行的行内边距提供，
    // 该操作行移除后需在此补回，保证与发送页、设置页的首元素间距一致
    .padding({
      left: DesignTokens.space.md,
      right: DesignTokens.space.md,
      top: DesignTokens.space.md
    })
    .contentEndOffset(DesignTokens.size.tabBarClearance)
    .onDidScroll((_xOffset: number, yOffset: number) => {
      let offset = this.scroller.currentOffset();
      this.onScrollDelta(yOffset, offset.yOffset);
    })
  }
}
