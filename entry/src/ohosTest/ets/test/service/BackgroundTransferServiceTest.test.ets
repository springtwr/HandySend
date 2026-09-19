import { describe, it, expect } from '@ohos/hypium'
import {
  throttleDelayMs,
  resolveTerminalKind,
  TransferTerminalKind
} from '../../../../main/ets/service/BackgroundTransferService'

// 后台传输服务纯决策函数单测（节流决策 + 终态文案决策）。
// 仅测模块导出的纯函数，不触发长时任务/通知等副作用。

export default function BackgroundTransferServiceTest() {
  describe('BackgroundTransferServiceTest', () => {
    // ── throttleDelayMs ──

    it('throttle_firstFrame_publishImmediately', 0, () => {
      // 任务周期内尚未发布过（lastPublishMs < 0）→ 首帧立即发布
      expect(throttleDelayMs(100000, -1, 1000)).assertEqual(0)
    })

    it('throttle_intervalElapsed_publishImmediately', 0, () => {
      // 距上次发布已达间隔 → 立即发布
      expect(throttleDelayMs(101000, 100000, 1000)).assertEqual(0)
      expect(throttleDelayMs(105000, 100000, 1000)).assertEqual(0)
    })

    it('throttle_withinInterval_returnsRemaining', 0, () => {
      // 未到间隔 → 返回剩余毫秒数
      expect(throttleDelayMs(100500, 100000, 1000)).assertEqual(500)
      expect(throttleDelayMs(100999, 100000, 1000)).assertEqual(1)
    })

    // ── resolveTerminalKind ──

    it('terminal_noFailure_success', 0, () => {
      expect(resolveTerminalKind(false, false)).assertEqual(TransferTerminalKind.success)
    })

    it('terminal_allFailed_failed', 0, () => {
      expect(resolveTerminalKind(true, true)).assertEqual(TransferTerminalKind.failed)
    })

    it('terminal_mixed_partial', 0, () => {
      expect(resolveTerminalKind(true, false)).assertEqual(TransferTerminalKind.partial)
    })
  })
}
