import { describe, it, expect } from '@ohos/hypium'
import { SpeedEstimator } from '../../../../main/ets/utils/SpeedEstimator'

// 速度滑动窗口估算纯逻辑单测（无 UIContext/native 依赖）。
export default function SpeedEstimatorTest() {
  describe('SpeedEstimatorTest', () => {
    it('firstSample_noSpeed', 0, () => {
      let e = new SpeedEstimator()
      // 首个样本无差分基准，不产生速度；剩余时间不可计算
      e.update(1000, 1000)
      expect(e.getSpeed()).assertEqual(0)
      expect(e.etaSeconds(10000, 1000)).assertEqual(-1)
    })

    it('windowNotFull_noSpeed', 0, () => {
      let e = new SpeedEstimator()
      // 历史不足一个完整窗口（2000ms）：窗口覆盖传输起点（管线灌充期），不出速度
      e.update(0, 0)
      e.update(1000, 1000)
      expect(e.getSpeed()).assertEqual(0)
    })

    it('steadyGrowth_windowDifferential', 0, () => {
      let e = new SpeedEstimator()
      // 窗口跨度满 2000ms：2000 字节 / 2000 毫秒 = 1000 B/s
      e.update(0, 0)
      e.update(2000, 2000)
      expect(e.getSpeed()).assertEqual(1000)
    })

    it('fillBurst_excludedByAnchor', 0, () => {
      let e = new SpeedEstimator()
      // 模拟管线灌充：前 50ms 冲入 10MB（磁盘读速），之后稳态 1MB/s；
      // 窗口起点之后的差分锚点落在灌充完成后，尖峰被排除
      e.update(0, 0)
      e.update(10 * 1000 * 1000, 50)
      e.update(12 * 1000 * 1000, 2050)
      expect(e.getSpeed()).assertEqual(1000 * 1000)
    })

    it('noGrowthInWindow_zeroSpeed', 0, () => {
      let e = new SpeedEstimator()
      // 窗口内字节无增量：速度归零（不保留陈旧值）
      e.update(0, 0)
      e.update(1000, 1000)
      e.update(1000, 3000)
      expect(e.getSpeed()).assertEqual(0)
    })

    it('bytesRegress_noNegativeSpeed', 0, () => {
      let e = new SpeedEstimator()
      // 字节回退：差分为负时不产生负值速度
      e.update(0, 0)
      e.update(1000, 1000)
      e.update(500, 2000)
      e.update(500, 3000)
      expect(e.getSpeed()).assertEqual(0)
    })

    it('unevenSampling_normalizedByTime', 0, () => {
      let e = new SpeedEstimator()
      // 模拟进度事件被丢弃：5 秒窗口内传 5000 字节，按实际时间差归一仍为 1000 B/s
      e.update(0, 0)
      e.update(5000, 5000)
      expect(e.getSpeed()).assertEqual(1000)
    })

    it('burstArrival_notDistorted', 0, () => {
      let e = new SpeedEstimator()
      // 模拟事件在 JS 队列中被压缩处理：多个样本同一时刻到达，
      // 差分只依赖窗口两端点，速度不受压缩到达影响
      e.update(0, 0)
      e.update(1000, 1000)
      e.update(2000, 3000)
      e.update(3000, 3000)
      expect(e.getSpeed()).assertEqual(1000)
    })

    it('oldSamplesPruned_speedSteady', 0, () => {
      let e = new SpeedEstimator()
      // 持续 10 秒稳态采样（500ms 一次）：旧样本被清理，末尾速度仍为 1000 B/s
      for (let t = 0; t <= 10000; t += 500) {
        e.update(t, t)
      }
      expect(e.getSpeed()).assertEqual(1000)
    })

    it('reset_clearsAll', 0, () => {
      let e = new SpeedEstimator()
      e.update(0, 0)
      e.update(2000, 2000)
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
      e.update(2000, 2000)
      // 速度 1000 B/s，剩余 3000 字节 → 3 秒
      expect(e.etaSeconds(5000, 2000)).assertEqual(3)
      // 已无剩余字节 → 0
      expect(e.etaSeconds(2000, 2000)).assertEqual(0)
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
