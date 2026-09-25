/**
 * SessionMetaSection.ets — 详情页完整信息区块
 *
 * 分区展示传输详情（性能 + 结果与错误合并为一个分区）、本机设备与标识；
 * 时间点信息由「时间线」区块承载，此处不重复展示。
 * 直接读取可观测视图模型的 `@Trace` 字段（实时会话与历史条目统一取数）；
 * 缺省字段按统一占位降级，不产生空白错位。
 * 长文本值行（协议会话 ID、统一会话标识）统一使用公共单行值行组件。
 *
 * 刷新机制：随进度变化的展示值一律在调用处以子组件 `@Param` 绑定传值——
 * 框架按依赖追踪在值变化时重新绑定子组件，从而刷新界面。
 * 由此得到一条约束：随进度变化的展示值不得经带基本类型参数的组件内 `@Builder` 渲染，
 * 因为该类 `@Builder` 按值传递参数，参数变化不会触发其内部 UI 刷新。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { SessionDetailViewModel } from '../../viewmodel/SessionDetailViewModel';
import { formatDuration, formatSizeDetailed, formatSpeed } from '../../utils/FormatUtil';
import { getStringSync } from '../../utils/ResourceUtil';
import { SingleLineValueRow } from '../../components/SingleLineValueRow';
import { SessionStatusBadge } from './SessionStatusBadge';

@ComponentV2
export struct SessionMetaSection {
  // 可观测视图模型：渲染中直接读取其 `@Trace` 字段（阶段与结果徽标同源）
  @Require @Param viewModel: SessionDetailViewModel

  /** 统一占位符文本。 */
  private placeholder(): string {
    return getStringSync(this.getUIContext(), $r('app.string.session_detail_placeholder'));
  }

  /** 空值统一降级为占位符。 */
  private valueOrPlaceholder(value: string): string {
    return value.length > 0 ? value : this.placeholder();
  }

  /** 速度文案（非正值视为不可得）。 */
  private speedText(bytesPerSec: number): string {
    return bytesPerSec > 0 ? formatSpeed(bytesPerSec) : this.placeholder();
  }

  /** 耗时文案（毫秒转秒；不可得为占位）。 */
  private durationText(durationMs: number): string {
    return durationMs > 0 ? formatDuration(durationMs / 1000) : this.placeholder();
  }

  /** 本机 IP 与接口名组合文案。 */
  private localNetworkText(): string {
    let ip: string = this.viewModel.meta.localIp;
    let name: string = this.viewModel.meta.localInterfaceName;
    if (ip.length === 0 && name.length === 0) {
      return this.placeholder();
    }
    if (name.length === 0) {
      return ip;
    }
    if (ip.length === 0) {
      return name;
    }
    return ip + ' · ' + name;
  }

  /** 分区标题。 */
  @Builder
  sectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize(DesignTokens.font.subtitleS)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
  }

  /** 信息区块容器。 */
  @Builder
  sectionCard() {
    Column({ space: DesignTokens.space.mini }) {
      this.sectionTitle($r('app.string.session_meta_performance_title'))
      SingleLineValueRow({
        label: $r('app.string.session_meta_total_size_label'),
        value: formatSizeDetailed(this.viewModel.meta.totalBytes),
        enableCopy: false
      })
      SingleLineValueRow({
        label: $r('app.string.session_meta_duration_label'),
        value: this.durationText(this.viewModel.meta.durationMs),
        enableCopy: false
      })
      SingleLineValueRow({
        label: $r('app.string.session_meta_average_speed_label'),
        value: this.speedText(this.viewModel.meta.averageSpeedBps),
        enableCopy: false
      })
      SingleLineValueRow({
        label: $r('app.string.session_meta_peak_speed_label'),
        value: this.speedText(this.viewModel.meta.peakSpeedBps),
        enableCopy: false
      })

      // 「结果」行并入传输详情区块，作为普通信息行（间距与其它信息行一致，不再以分隔线切分）
      Row({ space: DesignTokens.space.sm }) {
        Text($r('app.string.session_detail_result_label'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        SessionStatusBadge({ stage: this.viewModel.currentStage(), stageText: '' })
      }
      .width('100%')
      .padding({ top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
      .alignItems(VerticalAlign.Center)

      if (this.viewModel.meta.errorCode.length > 0) {
        SingleLineValueRow({
          label: $r('app.string.session_meta_error_code_label'),
          value: this.viewModel.meta.errorCode,
          enableCopy: false
        })
      }
      if (this.viewModel.meta.errorMessage.length > 0) {
        SingleLineValueRow({
          label: $r('app.string.session_meta_error_message_label'),
          value: this.viewModel.meta.errorMessage,
          enableCopy: false
        })
      }

      // 「本机」分组标题：与上方「传输」区块之间留出略大于普通行距的间距。
      // 普通相邻信息行距约 6vp（行内上下 2 + 容器 space 2）；此处额外 6vp，使区块间距约 10vp。
      Column() {
        this.sectionTitle($r('app.string.session_meta_local_title'))
      }
      .width('100%')
      .margin({ top: DesignTokens.space.xxs + DesignTokens.space.mini })

      SingleLineValueRow({
        label: $r('app.string.local_device_alias'),
        value: this.valueOrPlaceholder(this.viewModel.meta.localAlias),
        enableCopy: false
      })
      SingleLineValueRow({
        label: $r('app.string.session_meta_local_network_label'),
        value: this.localNetworkText(),
        enableCopy: false
      })
      SingleLineValueRow({
        label: $r('app.string.session_meta_protocol_session_id_label'),
        value: this.viewModel.meta.protocolSessionId,
        enableCopy: true
      })
      SingleLineValueRow({
        label: $r('app.string.transfer_detail_session_id'),
        value: this.viewModel.meta.sessionId,
        enableCopy: true
      })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    .alignItems(HorizontalAlign.Start)
    .id('session_detail_meta_section')
  }

  build() {
    this.sectionCard()
  }
}
