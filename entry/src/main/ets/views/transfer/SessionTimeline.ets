/**
 * SessionTimeline.ets — 详情页关键事件时间线
 *
 * 以时间线形式展示创建 / 确认 / 开始 / 终态及原因；事件携带统一会话标识。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { EmptyState } from '../../components/EmptyState';
import { SessionEventKind, SessionTimelineEvent } from '../../model/transfer/TransferSession';
import { formatTime } from '../../utils/FormatUtil';

/** 时间线事件类别 → 文案。 */
export function timelineEventLabel(kind: SessionEventKind): ResourceStr {
  if (kind === SessionEventKind.created) {
    return $r('app.string.session_detail_timeline_created');
  }
  if (kind === SessionEventKind.confirmed) {
    return $r('app.string.session_detail_timeline_confirmed');
  }
  if (kind === SessionEventKind.started) {
    return $r('app.string.session_detail_timeline_started');
  }
  if (kind === SessionEventKind.completed) {
    return $r('app.string.session_detail_timeline_completed');
  }
  if (kind === SessionEventKind.failed) {
    return $r('app.string.session_detail_timeline_failed');
  }
  if (kind === SessionEventKind.cancelled) {
    return $r('app.string.session_detail_timeline_cancelled');
  }
  return $r('app.string.session_detail_timeline_declined');
}

@ComponentV2
export struct SessionTimeline {
  @Require @Param events: Array<SessionTimelineEvent>

  build() {
    Column({ space: DesignTokens.space.xxs }) {
      Repeat(this.events)
        .each((ri: RepeatItem<SessionTimelineEvent>) => {
          Row({ space: DesignTokens.space.sm }) {
            Text(timelineEventLabel(ri.item.kind))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_primary'))
            Text(formatTime(ri.item.timestamp))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .padding({ top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
        })
        .key((item: SessionTimelineEvent) => item.sessionId + '#' + item.timestamp + '#' + item.kind)

      if (this.events.length === 0) {
        EmptyState({ mainText: $r('app.string.session_detail_placeholder') })
      }
    }
    .width('100%')
    .id('session_detail_timeline')
  }
}
