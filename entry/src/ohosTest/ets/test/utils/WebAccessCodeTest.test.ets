import { describe, it, expect } from '@ohos/hypium'
import {
  WEB_ACCESS_CODE_LENGTH,
  generateWebAccessCode,
  isWebAccessCode
} from '../../../../main/ets/utils/WebAccessCode'

// 本次访问码的纯逻辑单测（无 UIContext/系统依赖）。
export default function WebAccessCodeTest() {
  describe('WebAccessCodeTest', () => {
    it('generates_six_digits', 0, () => {
      expect(WEB_ACCESS_CODE_LENGTH).assertEqual(6)
      for (let i = 0; i < 20; i++) {
        let code: string = generateWebAccessCode()
        expect(code.length).assertEqual(6)
        expect(isWebAccessCode(code)).assertTrue()
      }
    })

    it('accepts_leading_zero', 0, () => {
      expect(isWebAccessCode('000123')).assertTrue()
    })

    it('rejects_empty_or_wrong_length', 0, () => {
      expect(isWebAccessCode('')).assertFalse()
      expect(isWebAccessCode('12345')).assertFalse()
      expect(isWebAccessCode('1234567')).assertFalse()
    })

    it('rejects_non_digit', 0, () => {
      expect(isWebAccessCode('12 456')).assertFalse()
      expect(isWebAccessCode('12a456')).assertFalse()
      expect(isWebAccessCode('密码1234')).assertFalse()
    })
  })
}
