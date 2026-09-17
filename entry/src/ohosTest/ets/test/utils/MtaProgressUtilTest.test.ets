import { describe, it, expect } from '@ohos/hypium'
import {
  resolveMaxActualBytes, resolveSendCompletedProgress, ProgressReportThrottle
} from '../../../../main/ets/utils/MtaProgressUtil'
import { MtaConstants } from '../../../../main/ets/service/mta/MtaConstants'
import { MtaSendProgress } from '../../../../main/ets/model/mta/MtaSendModels'

// MTA 进度口径纯逻辑单测（无 UIContext/native 依赖）。
export default function MtaProgressUtilTest() {
  describe('MtaProgressUtilTest', () => {
    // ── 解压总量上限（防 zip 炸弹，安全相关）──

    it('maxActualBytes_invalid_declared_uses_fallback', 0, () => {
      // ≤0 / NaN（缺失、非法、非有限）一律取未知声明兜底值
      expect(resolveMaxActualBytes(0)).assertEqual(MtaConstants.UNZIP_FALLBACK_TOTAL_BYTES)
      expect(resolveMaxActualBytes(-100)).assertEqual(MtaConstants.UNZIP_FALLBACK_TOTAL_BYTES)
      expect(resolveMaxActualBytes(NaN)).assertEqual(MtaConstants.UNZIP_FALLBACK_TOTAL_BYTES)
    })

    it('maxActualBytes_small_declared_uses_tolerance_floor', 0, () => {
      // 声明值很小时容差取下限（1MB），而非比例值
      expect(resolveMaxActualBytes(1000)).assertEqual(1000 + MtaConstants.UNZIP_TOLERANCE_MIN_BYTES)
    })

    it('maxActualBytes_ratio_dominates_when_large', 0, () => {
      // 声明 500MB：比例容差 5MB > 下限 1MB
      let declared: number = 500 * 1024 * 1024
      let expected: number = declared + Math.ceil(declared * MtaConstants.UNZIP_TOLERANCE_RATIO)
      expect(resolveMaxActualBytes(declared)).assertEqual(expected)
    })

    it('maxActualBytes_capped_at_max_total', 0, () => {
      // 声明 25GB：声明值 + 容差超出接收总大小上限（20GB），取上限封顶
      let declared: number = 25 * 1024 * 1024 * 1024
      expect(resolveMaxActualBytes(declared)).assertEqual(MtaConstants.MAX_UNZIP_TOTAL_BYTES)
    })

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
