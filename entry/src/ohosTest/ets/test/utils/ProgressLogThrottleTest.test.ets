import { describe, it, expect } from '@ohos/hypium'
import { ProgressLogThrottle } from '../../../../main/ets/utils/ProgressLogThrottle'

// 传输进度日志节流器纯逻辑单测（无 UIContext/native 依赖）。
export default function ProgressLogThrottleTest() {
  describe('ProgressLogThrottleTest', () => {
    it('firstEmitAllowed', 0, () => {
      let throttle = new ProgressLogThrottle(1000)
      expect(throttle.shouldLog('s1:f1', 1000)).assertTrue()
    })

    it('suppressesWithinInterval', 0, () => {
      let throttle = new ProgressLogThrottle(1000)
      expect(throttle.shouldLog('s1:f1', 1000)).assertTrue()
      expect(throttle.shouldLog('s1:f1', 1500)).assertFalse()
      expect(throttle.shouldLog('s1:f1', 1999)).assertFalse()
      // 达到最小间隔后放行
      expect(throttle.shouldLog('s1:f1', 2000)).assertTrue()
    })

    it('dimensionsIndependent', 0, () => {
      // 同一会话不同文件各自独立计时
      let throttle = new ProgressLogThrottle(1000)
      expect(throttle.shouldLog('s1:f1', 1000)).assertTrue()
      expect(throttle.shouldLog('s1:f2', 1000)).assertTrue()
      expect(throttle.shouldLog('s1:f1', 1100)).assertFalse()
    })

    it('clearAllowsImmediateEmit', 0, () => {
      // 文件进入终态时清理该维度，随后可立即输出（用于判断终态必发）
      let throttle = new ProgressLogThrottle(1000)
      expect(throttle.shouldLog('s1:f1', 1000)).assertTrue()
      expect(throttle.shouldLog('s1:f1', 1100)).assertFalse()
      throttle.clear('s1:f1')
      expect(throttle.shouldLog('s1:f1', 1150)).assertTrue()
    })

    it('clearSessionRemovesOnlyThatSession', 0, () => {
      // 会话终结时仅清理本会话维度，其他会话节流状态不受影响
      let throttle = new ProgressLogThrottle(1000)
      expect(throttle.shouldLog('s1:f1', 1000)).assertTrue()
      expect(throttle.shouldLog('s1:f2', 1000)).assertTrue()
      expect(throttle.shouldLog('s2:f1', 1000)).assertTrue()
      throttle.clearSession('s1')
      expect(throttle.shouldLog('s1:f1', 1100)).assertTrue()
      expect(throttle.shouldLog('s1:f2', 1100)).assertTrue()
      expect(throttle.shouldLog('s2:f1', 1100)).assertFalse()
    })

    it('defaultIntervalIsOneSecond', 0, () => {
      let throttle = new ProgressLogThrottle()
      expect(throttle.shouldLog('s1:f1', 0)).assertTrue()
      expect(throttle.shouldLog('s1:f1', 999)).assertFalse()
      expect(throttle.shouldLog('s1:f1', 1000)).assertTrue()
    })
  })
}
