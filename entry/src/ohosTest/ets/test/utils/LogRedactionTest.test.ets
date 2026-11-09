// LogRedactionTest：日志脱敏工具的行为
import { describe, it, expect } from '@ohos/hypium'
import { maskSecret, redactSessionToken } from '../../../../main/ets/utils/LogRedaction'

export default function LogRedactionTest() {
  describe('LogRedactionTest', () => {
    it('redacts_session_token', 0, () => {
      expect(redactSessionToken('abcdefghijklmnop')).assertEqual('abcd***mnop')
      expect(redactSessionToken('short')).assertEqual('***')
    })

    it('masks_secret', 0, () => {
      expect(maskSecret('')).assertEqual('')
      expect(maskSecret('abcd')).assertEqual('****')
      expect(maskSecret('abcde')).assertEqual('ab*de')
      expect(maskSecret('abcdefgh')).assertEqual('ab****gh')
    })
  })
}
