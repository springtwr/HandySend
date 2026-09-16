import { describe, it, expect } from '@ohos/hypium'
import { resolveSendCompletedProgress, ProgressReportThrottle } from '../../../../main/ets/utils/MtaProgressUtil'
import { MtaSendProgress } from '../../../../main/ets/model/mta/MtaSendModels'

// MTA 进度口径纯逻辑单测（无 UIContext/native 依赖）。
export default function MtaProgressUtilTest() {
  describe('MtaProgressUtilTest', () => {
    // ── 发送完成进度解析 ──

    it('sendCompleted_keepsDeclaredTotal', 0, () => {
      let last = new MtaSendProgress()
      last.sentBytes = 100
      last.totalBytes = 500
      last.percent = 20
      let done = resolveSendCompletedProgress(last, 900)
      expect(done.totalBytes).assertEqual(500)
      expect(done.sentBytes).assertEqual(500)
      expect(done.percent).assertEqual(100)
    })

    it('sendCompleted_fallsBackWhenNoProgress', 0, () => {
      let last = new MtaSendProgress()
      let done = resolveSendCompletedProgress(last, 900)
      expect(done.totalBytes).assertEqual(900)
      expect(done.sentBytes).assertEqual(900)
      expect(done.percent).assertEqual(100)
    })

    // ── 进度上报节流 ──

    it('throttle_firstReportAllowed', 0, () => {
      let throttle = new ProgressReportThrottle(200)
      expect(throttle.shouldReport(1000, false)).assertTrue()
    })

    it('throttle_suppressesWithinInterval', 0, () => {
      let throttle = new ProgressReportThrottle(200)
      expect(throttle.shouldReport(1000, false)).assertTrue()
      expect(throttle.shouldReport(1100, false)).assertFalse()
      expect(throttle.shouldReport(1199, false)).assertFalse()
      expect(throttle.shouldReport(1200, false)).assertTrue()
    })

    it('throttle_completeBypassesInterval', 0, () => {
      let throttle = new ProgressReportThrottle(200)
      expect(throttle.shouldReport(1000, false)).assertTrue()
      expect(throttle.shouldReport(1010, true)).assertTrue()
      // 完成事件刷新计时：其后同一间隔内不再上报
      expect(throttle.shouldReport(1100, false)).assertFalse()
    })

    it('throttle_resetAllowsImmediateReport', 0, () => {
      let throttle = new ProgressReportThrottle(200)
      expect(throttle.shouldReport(1000, false)).assertTrue()
      expect(throttle.shouldReport(1100, false)).assertFalse()
      throttle.reset()
      expect(throttle.shouldReport(1150, false)).assertTrue()
    })
  })
}
