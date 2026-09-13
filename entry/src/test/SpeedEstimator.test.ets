import { describe, it, expect } from '@ohos/hypium'
import { SpeedEstimator } from '../main/ets/utils/SpeedEstimator'

// 速度采样与剩余时间估算纯逻辑单测（无 UIContext/native 依赖）。
export default function SpeedEstimatorTest() {
  describe('SpeedEstimatorTest', () => {
    it('firstSample_noSpeed', 0, () => {
      let e = new SpeedEstimator()
      // 首个样本无差分基准，不产生速度；剩余时间不可计算
      e.update(1000, 1000)
      expect(e.getSpeed()).assertEqual(0)
      expect(e.etaSeconds(10000, 1000)).assertEqual(-1)
    })

    it('steadyGrowth_speedInBytesPerSec', 0, () => {
      let e = new SpeedEstimator()
      e.update(0, 0)
      e.update(1000, 1000)
      // 1000 字节 / 1000 毫秒 = 1000 B/s
      expect(e.getSpeed()).assertEqual(1000)
    })

    it('emaSmoothing', 0, () => {
      let e = new SpeedEstimator()
      e.update(0, 0)
      e.update(1000, 1000)
      e.update(3000, 2000)
      // 瞬时 2000 B/s，EMA：0.3 * 2000 + 0.7 * 1000 = 1300
      let speed = e.getSpeed()
      expect(Math.abs(speed - 1300) < 0.001).assertTrue()
    })

    it('noGrowth_keepsSpeed', 0, () => {
      let e = new SpeedEstimator()
      e.update(0, 0)
      e.update(1000, 1000)
      // 字节无增量：保持原速度，不清零
      e.update(1000, 3000)
      expect(e.getSpeed()).assertEqual(1000)
    })

    it('bytesRegress_keepsSpeed', 0, () => {
      let e = new SpeedEstimator()
      e.update(0, 0)
      e.update(1000, 1000)
      // 字节回退：不更新速度，不产生负值
      e.update(500, 2000)
      expect(e.getSpeed()).assertEqual(1000)
    })

    it('unevenSampling_normalizedByTime', 0, () => {
      let e = new SpeedEstimator()
      e.update(0, 0)
      // 模拟进度事件被丢弃：5 秒窗口内传 5000 字节，按实际时间差归一仍为 1000 B/s
      e.update(5000, 5000)
      expect(e.getSpeed()).assertEqual(1000)
    })

    it('reset_clearsAll', 0, () => {
      let e = new SpeedEstimator()
      e.update(0, 0)
      e.update(1000, 1000)
      e.reset()
      expect(e.getSpeed()).assertEqual(0)
      expect(e.isStale(5000, 3000)).assertTrue()
      // 复位后首个样本无差分基准，不产生速度
      e.update(1000, 5000)
      expect(e.getSpeed()).assertEqual(0)
    })

    it('etaSeconds_cases', 0, () => {
      let e = new SpeedEstimator()
      e.update(0, 0)
      e.update(1000, 1000)
      // 速度 1000 B/s，剩余 4000 字节 → 4 秒
      expect(e.etaSeconds(5000, 1000)).assertEqual(4)
      // 已无剩余字节 → 0
      expect(e.etaSeconds(1000, 1000)).assertEqual(0)
    })

    it('stale_afterThreshold', 0, () => {
      let e = new SpeedEstimator()
      e.update(0, 0)
      e.update(1000, 1000)
      // 距最近增长未达阈值：未过期；达到阈值：过期
      expect(e.isStale(1000 + 2999, 3000)).assertFalse()
      expect(e.isStale(1000 + 3000, 3000)).assertTrue()
    })
  })
}
