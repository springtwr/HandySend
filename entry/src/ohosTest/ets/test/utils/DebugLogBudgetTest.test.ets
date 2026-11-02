// DebugLogBudgetTest：debug 令牌桶的突发、补充与重置行为
import { describe, it, expect } from '@ohos/hypium'
import { DebugLogBudget } from '../../../../main/ets/utils/DebugLogBudget'

export default function DebugLogBudgetTest() {
  describe('DebugLogBudgetTest', () => {
    it('burst_then_suppress', 0, () => {
      let budget: DebugLogBudget = new DebugLogBudget(100, 300, 0)
      for (let i = 0; i < 300; i++) {
        expect(budget.allow(0)).assertTrue()
      }
      expect(budget.allow(0)).assertFalse()
      expect(budget.takeSuppressed()).assertEqual(1)
    })

    it('refills_by_rate', 0, () => {
      let budget: DebugLogBudget = new DebugLogBudget(100, 300, 0)
      for (let i = 0; i < 300; i++) {
        budget.allow(0)
      }
      let allowed: number = 0
      for (let i = 0; i < 100; i++) {
        if (budget.allow(1000)) {
          allowed++
        }
      }
      expect(allowed).assertEqual(100)
      expect(budget.allow(1000)).assertFalse()
      expect(budget.takeSuppressed()).assertEqual(1)
    })

    it('reset_restores_burst', 0, () => {
      let budget: DebugLogBudget = new DebugLogBudget(100, 300, 0)
      for (let i = 0; i < 300; i++) {
        budget.allow(0)
      }
      expect(budget.allow(0)).assertFalse()
      budget.reset(0)
      expect(budget.allow(0)).assertTrue()
      expect(budget.takeSuppressed()).assertEqual(0)
    })
  })
}
