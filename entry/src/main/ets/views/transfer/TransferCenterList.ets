/**
 * TransferCenterList.ets — 传输中心会话列表
 *
 * 单一「会话」列表：进行中 / 待确认 / 终态可见窗口内会话与持久化历史合并展示，
 * 按会话创建时间倒序排列（历史条目无创建时间时回退完成时间）。
 * 行序列（标题 / 可选来源筛选 / 条目 / 空态）在 ViewModel 于数据变更时一次性构建并缓存，
 * 本组件通过**单一** `Repeat(virtualScroll)` 直接渲染该缓存，不在 build 中重算行模型、
 * 也不逐行同步读取资源（不使用 ListItemGroup，避免嵌套分组导致的滚动卡死）。
 */

import { DesignTokens } from '../../common/DesignTokens';
import {
  CenterRow,
  ROW_EMPTY,
  ROW_FILTER,
  ROW_HEADER,
  ROW_SESSION,
  SessionRowModel,
  TransferCenterViewModel
} from '../../viewmodel/TransferCenterViewModel';
import { SessionStatusBadge } from './SessionStatusBadge';
import { hasDisplayText } from '../../service/transfer/adapters/SessionAdapter';

@ComponentV2
export struct TransferCenterList {
  @Require @Param viewModel: TransferCenterViewModel
  @Event onOpenSession: (sessionId: string) => void = (_sessionId: string) => {
  }
  @Event onOpenFileHistory: () => void = () => {
  }
  @Event onOpenLocalDevice: () => void = () => {
  }
  // 滚动增量上抛（供主页页签栏滚动感知隐藏动画）
  @Event onScrollDelta: (deltaY: number, absY: number) => void = (_deltaY: number, _absY: number) => {
  }
  private scroller: Scroller = new Scroller()

  /** 会话分组标题行（单一「会话」；样式对齐发送页「选择文件」标题，右侧保留三个入口）。 */
  @Builder
  sessionsHeader() {
    Row({ space: DesignTokens.space.sm }) {
      Text($r('app.string.transfer_center_group_sessions'))
        .fontSize(DesignTokens.font.titleS)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      // 本机信息精简入口（同故障排查入口样式：图标 + 48vp 热区）
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(DesignTokens.font.titleM)
        .fontColor([$r('app.color.text_primary')])
        .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
        .accessibilityGroup(true)
        .accessibilityText($r('app.string.settings_group_local_device'))
        .onClick(() => {
          this.onOpenLocalDevice();
        })
        .id('transfer_center_local_device_entry')

      // 文件历史入口（独立于会话历史，不受清除历史影响）
      SymbolGlyph($r('sys.symbol.arrow_counterclockwise_clock'))
        .fontSize(DesignTokens.font.titleM)
        .fontColor([$r('app.color.text_primary')])
        .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
        .accessibilityGroup(true)
        .accessibilityText($r('app.string.transfer_center_file_history_entry'))
        .onClick(() => {
          this.onOpenFileHistory();
        })
        .id('transfer_center_file_history_entry')

      if (this.viewModel.historyCount > 0) {
        Text($r('app.string.transfer_center_clear_history'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.accent_blue'))
          .accessibilityGroup(true)
          .onClick(() => {
            this.viewModel.clearHistory();
          })
          .id('transfer_center_clear_history_btn')
      }
    }
    .width('100%')
    .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.sm })
    .alignItems(VerticalAlign.Center)
  }

  /** 来源协议筛选标签行。 */
  @Builder
  sourceFilterRow() {
    Row({ space: DesignTokens.space.xxs }) {
      Text($r('app.string.transfer_center_filter_all'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor(this.viewModel.sourceFilter.length === 0 ? $r('app.color.accent_blue') :
          $r('app.color.text_secondary'))
        .padding({
          left: DesignTokens.space.sm,
          right: DesignTokens.space.sm,
          top: DesignTokens.space.tiny,
          bottom: DesignTokens.space.tiny
        })
        .backgroundColor(this.viewModel.sourceFilter.length === 0 ? $r('app.color.accent_blue_bg') :
          $r('app.color.page_background'))
        .borderRadius(DesignTokens.radius.max)
        .accessibilityGroup(true)
        .onClick(() => {
          this.viewModel.setSourceFilter('');
        })
      Repeat(this.viewModel.sourceKeys)
        .each((ri: RepeatItem<string>) => {
          Text(this.viewModel.sourceLabel(ri.item))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor(this.viewModel.sourceFilter === ri.item ? $r('app.color.accent_blue') :
              $r('app.color.text_secondary'))
            .padding({
              left: DesignTokens.space.sm,
              right: DesignTokens.space.sm,
              top: DesignTokens.space.tiny,
              bottom: DesignTokens.space.tiny
            })
            .backgroundColor(this.viewModel.sourceFilter === ri.item ? $r('app.color.accent_blue_bg') :
              $r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.max)
            .accessibilityGroup(true)
            .onClick(() => {
              this.viewModel.setSourceFilter(ri.item);
            })
        })
        .key((item: string) => item)
    }
    .width('100%')
    .padding({ bottom: DesignTokens.space.xxs })
  }

  /** 会话条目：时间 · 方向 · 传输方式 + 对端 + 状态/进度。 */
  @Builder
  sessionRow(row: SessionRowModel) {
    Row({ space: DesignTokens.space.sm }) {
      Column() {
        Row({ space: DesignTokens.space.tiny }) {
          Text(row.peerName.length > 0 ? row.peerName : '--')
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          SessionStatusBadge({ stage: row.stage, stageText: row.stageText })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 元信息：会话时间 · 传输方向 · 传输方式（来源协议）
        Row({ space: DesignTokens.space.xxs }) {
          Text(row.timeText)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
          Text('·')
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_tertiary'))
          Text(row.directionLabel)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
          Text('·')
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_tertiary'))
          Text(row.sourceLabel)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: DesignTokens.space.mini })
        .alignItems(VerticalAlign.Center)

        // 进行中：有字节进度才展示进度条 + 百分比；
        // 无字节进度的会话不渲染百分比（避免误导性的 0%），改由状态徽标/阶段文案表达。
        // 终态仅展示结果徽标。
        if (!row.terminal) {
          if (row.hasByteProgress) {
            Row({ space: DesignTokens.space.sm }) {
              Progress({ value: row.percent, total: 100, type: ProgressType.Linear })
                .width('100%')
                .height(DesignTokens.size.progressBarHeight)
                .color($r('app.color.accent_blue'))
                .backgroundColor($r('app.color.border_light'))
                .layoutWeight(1)
              Text(Math.round(row.percent) + '%')
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .width(DesignTokens.space.xl + 6)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .margin({ top: DesignTokens.space.tiny })
          } else if (hasDisplayText(row.stageText)) {
            Text(row.stageText)
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: DesignTokens.space.tiny })
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (row.awaitingConfirm) {
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
      // 标题 / 筛选 / 条目 / 空态同处一个顶层 Repeat 的直接子级 ListItem 序列，
      // 不使用 ListItemGroup，避免嵌套分组在虚拟滚动下的卡死。
      Repeat(this.viewModel.rows)
        .each((ri: RepeatItem<CenterRow>) => {
          ListItem() {
            if (ri.item.kind === ROW_HEADER) {
              this.sessionsHeader()
            } else if (ri.item.kind === ROW_FILTER) {
              this.sourceFilterRow()
            } else if (ri.item.kind === ROW_SESSION) {
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
    .scrollBar(BarState.Off)
    // 内容不足一屏也保持回弹（alwaysEnabled）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 渲染范围控制：Repeat 开启 virtualScroll 后按显示区 + 预加载区懒加载，cachedCount 控制预加载条目数
    .cachedCount(4)
    // 底部留出页签安全距离，避免列表末条被一级页签遮挡
    .padding({
      left: DesignTokens.space.md,
      right: DesignTokens.space.md,
      bottom: DesignTokens.size.tabBarClearance
    })
    .onDidScroll((_xOffset: number, yOffset: number) => {
      let offset = this.scroller.currentOffset();
      this.onScrollDelta(yOffset, offset.yOffset);
    })
  }
}
