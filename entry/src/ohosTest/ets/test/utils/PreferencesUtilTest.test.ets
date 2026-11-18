import { describe, it, expect } from '@ohos/hypium'
import { PreferencesUtil, preferencesUtil } from '../../../../main/ets/utils/PreferencesUtil'

// preferencesUtil 是进程单例，其它用例可能在 beforeAll 中调用 init，
// 因此「未初始化」这一前提在共享进程内不可靠（用例顺序相关、偶发失败）。
// 改用唯一且不会被写入的键，断言「键不存在时返回默认值」语义。
const ABSENT_KEY: string = '__prefutil_absent_key__'
const ABSENT_WRITE_KEY: string = '__prefutil_absent_write_key__'

export default function PreferencesUtilTest() {
  describe('PreferencesUtilTest', () => {
    it('getters_return_default_when_key_absent', 0, () => {
      expect(preferencesUtil.getBoolean(ABSENT_KEY, true)).assertTrue()
      expect(preferencesUtil.getBoolean(ABSENT_KEY, false)).assertFalse()
      expect(preferencesUtil.getString(ABSENT_KEY, 'd')).assertEqual('d')
      expect(preferencesUtil.getNumber(ABSENT_KEY, 42)).assertEqual(42)
      expect(preferencesUtil.getObject(ABSENT_KEY, 'fallback')).assertEqual('fallback')
    })

    it('has_returns_false_when_key_absent', 0, () => {
      expect(preferencesUtil.has(ABSENT_KEY)).assertFalse()
    })

    it('setters_do_not_throw', 0, () => {
      let threw: boolean = false
      try {
        preferencesUtil.setBoolean(ABSENT_WRITE_KEY, true)
        preferencesUtil.setString(ABSENT_WRITE_KEY, 'v')
        preferencesUtil.setNumber(ABSENT_WRITE_KEY, 1)
        preferencesUtil.setObject(ABSENT_WRITE_KEY, 'v')
      } catch (_e) {
        threw = true
      }
      expect(threw).assertFalse()
    })

    // 未初始化实例的兜底语义：读返回默认值（has 返回 false），写/删/刷盘不抛异常。
    // 用独立实例而非单例，避免依赖其它用例是否已调用 init。
    it('uninitialized_instance_falls_back_without_throwing', 0, () => {
      let util: PreferencesUtil = new PreferencesUtil('__prefutil_uninitialized_store__')
      let boolValue: boolean = util.getBoolean(ABSENT_KEY, true)
      let stringValue: string = util.getString(ABSENT_KEY, 'd')
      let numberValue: number = util.getNumber(ABSENT_KEY, 42)
      let objectValue: string = util.getObject(ABSENT_KEY, 'fallback')
      let hasKey: boolean = util.has(ABSENT_KEY)
      let threw: boolean = false
      try {
        util.setBoolean(ABSENT_KEY, true)
        util.setString(ABSENT_KEY, 'v')
        util.setNumber(ABSENT_KEY, 1)
        util.setObject(ABSENT_KEY, 'v')
        util.delete(ABSENT_KEY)
        util.flushNow()
      } catch (_e) {
        threw = true
      }
      expect(boolValue).assertTrue()
      expect(stringValue).assertEqual('d')
      expect(numberValue).assertEqual(42)
      expect(objectValue).assertEqual('fallback')
      expect(hasKey).assertFalse()
      expect(threw).assertFalse()
    })

  })
}
