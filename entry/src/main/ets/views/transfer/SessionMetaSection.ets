/**
 * SessionMetaSection.ets — 详情页完整信息区块
 *
 * 分区展示传输详情（性能 + 结果与错误合并为一个分区）、本机设备与标识；
 * 时间点信息由「时间线」区块承载，此处不重复展示。
 * 对实时会话与历史条目统一取数（数据来自 SessionDetailViewModel.meta），
 * 缺省字段按统一占位降级，不产生空白错位。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { SessionStage } from '../../model/transfer/TransferSession';
import { SessionDetailMeta, canCopyMetaValue } from '../../viewmodel/SessionDetailViewModel';
import { formatDuration, formatSizeDetailed, formatSpeed } from '../../utils/FormatUtil';
import { copyText } from '../../utils/ClipboardUtil';
import { SessionStatusBadge } from './SessionStatusBadge';

@ComponentV2
export struct SessionMetaSection {
  @Require @Param meta: SessionDetailMeta
  @Require @Param stage: SessionStage

  /** 空值统一降级为占位符。 */
  private valueOrPlaceholder(value: string): ResourceStr {
    return value.length > 0 ? value : $r('app.string.session_detail_placeholder');
  }

  /** 速度文案（非正值视为不可得）。 */
  private speedText(bytesPerSec: number): ResourceStr {
    return bytesPerSec > 0 ? formatSpeed(bytesPerSec) : $r('app.string.session_detail_placeholder');
  }

  /** 耗时文案（毫秒转秒；不可得为占位）。 */
  private durationText(durationMs: number): ResourceStr {
    return durationMs > 0 ? formatDuration(durationMs / 1000) : $r('app.string.session_detail_placeholder');
  }

  /** 本机 IP 与接口名组合文案。 */
  private localNetworkText(): ResourceStr {
    let ip: string = this.meta.localIp;
    let name: string = this.meta.localInterfaceName;
    if (ip.length === 0 && name.length === 0) {
      return $r('app.string.session_detail_placeholder');
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

  /** 信息行：标签（左）+ 值（右，完整可见，可换行，与校验和行同口径）。 */
  @Builder
  metaRow(label: ResourceStr, value: ResourceStr) {
    Row({ space: DesignTokens.space.sm }) {
      Text(label)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
      Text(value)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.End)
        .wordBreak(WordBreak.BREAK_ALL)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
    .alignItems(VerticalAlign.Top)
  }

  /** 可复制信息行：标签 + 完整值（可换行）+ 行内复制入口（空值隐藏入口，不附加来源标注）。 */
  @Builder
  metaCopyRow(label: ResourceStr, value: string, copyLabel: ResourceStr) {
    Row({ space: DesignTokens.space.sm }) {
      Text(label)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
      Text(this.valueOrPlaceholder(value))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.End)
        .wordBreak(WordBreak.BREAK_ALL)
        .layoutWeight(1)
      if (canCopyMetaValue(value)) {
        Text(copyLabel)
          .fontSize(DesignTokens.font.captionM)
          .fontColor($r('app.color.accent_blue'))
          .onClick(() => {
            this.copyMetaValue(value);
          })
          .id('session_meta_copy_value')
      }
    }
    .width('100%')
    .padding({ top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
    .alignItems(VerticalAlign.Top)
  }

  /** 复制完整值并给出成功/失败提示。 */
  private copyMetaValue(value: string): void {
    if (copyText(value)) {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.copy_success'),
        duration: 2000
      });
    } else {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.copy_failed'),
        duration: 2000
      });
    }
  }

  /** 信息区块容器。 */
  @Builder
  sectionCard() {
    Column({ space: DesignTokens.space.mini }) {
      this.sectionTitle($r('app.string.session_meta_performance_title'))
      this.metaRow($r('app.string.session_meta_total_size_label'), formatSizeDetailed(this.meta.totalBytes))
      this.metaRow($r('app.string.session_meta_duration_label'), this.durationText(this.meta.durationMs))
      this.metaRow($r('app.string.session_meta_average_speed_label'),
        this.speedText(this.meta.averageSpeedBps))
      this.metaRow($r('app.string.session_meta_peak_speed_label'), this.speedText(this.meta.peakSpeedBps))

      Divider().color($r('app.color.border_light')).margin({ top: DesignTokens.space.tiny })

      Row({ space: DesignTokens.space.sm }) {
        Text($r('app.string.session_detail_result_label'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        SessionStatusBadge({ stage: this.stage, stageText: '' })
      }
      .width('100%')
      .padding({ top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
      .alignItems(VerticalAlign.Center)
      if (this.meta.errorCode.length > 0) {
        this.metaRow($r('app.string.session_meta_error_code_label'), this.meta.errorCode)
      }
      if (this.meta.errorMessage.length > 0) {
        this.metaRow($r('app.string.session_meta_error_message_label'), this.meta.errorMessage)
      }

      Divider().color($r('app.color.border_light')).margin({ top: DesignTokens.space.tiny })

      this.sectionTitle($r('app.string.session_meta_local_title'))
      this.metaRow($r('app.string.local_device_alias'), this.valueOrPlaceholder(this.meta.localAlias))
      this.metaRow($r('app.string.session_meta_local_network_label'), this.localNetworkText())
      this.metaCopyRow($r('app.string.session_meta_protocol_session_id_label'),
        this.meta.protocolSessionId, $r('app.string.session_meta_protocol_session_id_copy'))
      this.metaCopyRow($r('app.string.transfer_detail_session_id'),
        this.meta.sessionId, $r('app.string.transfer_detail_copy_id'))
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
