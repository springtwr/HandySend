import { describe, it, expect } from '@ohos/hypium'
import { ipShortCode } from '../main/ets/utils/NetworkPresentation'

export default function NetworkPresentationTest() {
  describe('NetworkPresentationTest', () => {
    // ── ipShortCode ──

    it('ipShortCode_normal_ip', 0, () => {
      expect(ipShortCode('192.168.1.24')).assertEqual('#24')
    })

    it('ipShortCode_single_segment', 0, () => {
      expect(ipShortCode('localhost')).assertEqual('#localhost')
    })

    it('ipShortCode_empty_string', 0, () => {
      // ''.split('.') → ['']，最后一段为空字符串
      expect(ipShortCode('')).assertEqual('#')
    })

    it('ipShortCode_trailing_dot', 0, () => {
      expect(ipShortCode('192.168.1.')).assertEqual('#')
    })
  })
}
