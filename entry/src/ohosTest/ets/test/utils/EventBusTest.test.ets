import { describe, it, expect } from '@ohos/hypium'
import { EventBus } from '../../../../main/ets/utils/EventBus'

export default function EventBusTest() {
  describe('EventBusTest', () => {
    // ── subscribe + notifyChange ──

    it('notifyChange_calls_all_subscribers', 0, () => {
      let bus: EventBus = new EventBus()
      let count1: number = 0
      let count2: number = 0
      bus.subscribe(() => {
        count1++
      })
      bus.subscribe(() => {
        count2++
      })
      bus.notifyChange()
      expect(count1).assertEqual(1)
      expect(count2).assertEqual(1)
    })

    it('notifyChange_multiple_times', 0, () => {
      let bus: EventBus = new EventBus()
      let count: number = 0
      bus.subscribe(() => {
        count++
      })
      bus.notifyChange()
      bus.notifyChange()
      bus.notifyChange()
      expect(count).assertEqual(3)
    })

    // ── unsubscribe ──

    it('unsubscribe_prevents_future_calls', 0, () => {
      let bus: EventBus = new EventBus()
      let count: number = 0
      let cb: () => void = () => {
        count++
      }
      bus.subscribe(cb)
      bus.notifyChange()
      expect(count).assertEqual(1)
      bus.unsubscribe(cb)
      bus.notifyChange()
      expect(count).assertEqual(1)
    })

    it('unsubscribe_only_removes_target_callback', 0, () => {
      let bus: EventBus = new EventBus()
      let count1: number = 0
      let count2: number = 0
      let cb1: () => void = () => {
        count1++
      }
      let cb2: () => void = () => {
        count2++
      }
      bus.subscribe(cb1)
      bus.subscribe(cb2)
      bus.unsubscribe(cb1)
      bus.notifyChange()
      expect(count1).assertEqual(0)
      expect(count2).assertEqual(1)
    })

    it('unsubscribe_unknown_callback_no_effect', 0, () => {
      let bus: EventBus = new EventBus()
      let count: number = 0
      bus.subscribe(() => {
        count++
      })
      let unknownCb: () => void = () => {
      }
      bus.unsubscribe(unknownCb)
      bus.notifyChange()
      expect(count).assertEqual(1)
    })

    // ── 异常隔离 ──

    it('notifyChange_throwing_callback_does_not_break_others', 0, () => {
      let bus: EventBus = new EventBus()
      let count2: number = 0
      bus.subscribe(() => {
        throw new Error('callback error')
      })
      bus.subscribe(() => {
        count2++
      })
      // 首个回调抛错不应中断后续回调，也不应向上传播
      bus.notifyChange()
      expect(count2).assertEqual(1)
    })

    // ── 边界条件 ──

    it('notifyChange_with_no_subscribers_no_crash', 0, () => {
      let bus: EventBus = new EventBus()
      bus.notifyChange()
      // 不崩溃即通过
    })

    it('subscribe_same_callback_multiple_times', 0, () => {
      let bus: EventBus = new EventBus()
      let count: number = 0
      let cb: () => void = () => {
        count++
      }
      bus.subscribe(cb)
      bus.subscribe(cb)
      bus.notifyChange()
      // 同一回调注册两次 → 通知时调用两次
      expect(count).assertEqual(2)
      // 取消订阅一次后不再被调用
      bus.unsubscribe(cb)
      bus.notifyChange()
      // unsubscribe 只移除一个匹配项，仍剩一个
      expect(count).assertEqual(3)
    })
  })
}
