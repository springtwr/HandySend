// SessionStatusBadge 状态徽标文案解析测试。
// 终态会话的徽标文案须取统一状态文案，不得采用进行中阶段残留的离散文案。
import { describe, it, expect } from '@ohos/hypium'
import {
  sessionBadgeText,
  sessionFileStageBgColor,
  sessionFileStageColor,
  sessionFileStageLabel
} from '../../../../main/ets/views/transfer/SessionStatusBadge'
import { SessionFileStage, SessionStage } from '../../../../main/ets/model/transfer/TransferSession'

export default function SessionStatusBadgeTest() {
  describe('SessionStatusBadgeTest', () => {
    it('terminal_stage_ignores_stale_stage_text', 0, () => {
      // 会话已进入终态后，进行中阶段留下的离散文案不得再被徽标采用
      let shown = sessionBadgeText(SessionStage.succeeded, '传输中');
      expect(typeof shown === 'string').assertFalse();
      if (typeof shown !== 'string') {
        expect(shown.id).assertEqual($r('app.string.session_stage_succeeded').id);
      }
    })

    it('non_terminal_keeps_discrete_stage_text', 0, () => {
      // 非终态保持既有语义：离散阶段文案优先
      expect(sessionBadgeText(SessionStage.active, '传输中')).assertEqual('传输中');
      // 无离散文案时回退统一状态映射
      let fallback = sessionBadgeText(SessionStage.active, '');
      expect(typeof fallback === 'string').assertFalse();
      if (typeof fallback !== 'string') {
        expect(fallback.id).assertEqual($r('app.string.session_stage_active').id);
      }
    })

    it('awaiting_confirmation_is_not_terminal', 0, () => {
      // 待确认为非终态：仍采用离散阶段文案
      expect(sessionBadgeText(SessionStage.awaitingConfirmation, '待确认')).assertEqual('待确认');
    })

    it('file_stage_failed_hasLabelAndColors', 0, () => {
      // 逐文件「失败」映射文案/配色可用（详情页与历史条目同口径复用）
      let label = sessionFileStageLabel(SessionFileStage.failed)
      expect(typeof label === 'string').assertFalse()
      if (typeof label !== 'string') {
        expect(label.id).assertEqual($r('app.string.file_status_failed').id)
      }
      let color = sessionFileStageColor(SessionFileStage.failed) as Resource
      expect(color.id).assertEqual($r('app.color.danger_red').id)
      let bg = sessionFileStageBgColor(SessionFileStage.failed) as Resource
      expect(bg.id).assertEqual($r('app.color.danger_bg').id)
    })

    it('file_stage_cancelled_hasLabelAndColors', 0, () => {
      // 逐文件「已取消」映射文案/配色可用（取消后等待中/传输中的文件展示为已取消）
      let label = sessionFileStageLabel(SessionFileStage.cancelled)
      expect(typeof label === 'string').assertFalse()
      if (typeof label !== 'string') {
        expect(label.id).assertEqual($r('app.string.file_status_cancelled').id)
      }
      let color = sessionFileStageColor(SessionFileStage.cancelled) as Resource
      expect(color.id).assertEqual($r('app.color.text_secondary').id)
      let bg = sessionFileStageBgColor(SessionFileStage.cancelled) as Resource
      expect(bg.id).assertEqual($r('app.color.page_background').id)
    })
  })
}
