import { describe, it, expect } from '@ohos/hypium'
import { preferencesUtil } from '../main/ets/utils/PreferencesUtil'

export default function PreferencesUtilTest() {
  describe('PreferencesUtilTest', () => {
    it('getters_return_default_when_not_initialized', 0, () => {
      expect(preferencesUtil.getBoolean('k', true)).assertTrue()
      expect(preferencesUtil.getBoolean('k', false)).assertFalse()
      expect(preferencesUtil.getString('k', 'd')).assertEqual('d')
      expect(preferencesUtil.getNumber('k', 42)).assertEqual(42)
      expect(preferencesUtil.getObject('k', 'fallback')).assertEqual('fallback')
    })

    it('has_returns_false_when_not_initialized', 0, () => {
      expect(preferencesUtil.has('k')).assertFalse()
    })

    it('setters_no_throw_when_not_initialized', 0, () => {
      let threw: boolean = false
      try {
        preferencesUtil.setBoolean('k', true)
        preferencesUtil.setString('k', 'v')
        preferencesUtil.setNumber('k', 1)
        preferencesUtil.setObject('k', 'v')
      } catch (_e) {
        threw = true
      }
      expect(threw).assertFalse()
    })

  })
}
