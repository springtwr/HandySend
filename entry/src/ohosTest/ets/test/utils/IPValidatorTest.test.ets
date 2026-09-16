import { describe, it, expect } from '@ohos/hypium'
import { isValidIpAddress, isUrl } from '../../../../main/ets/utils/IPValidator'

export default function IPValidatorTest() {
  describe('IPValidatorTest', () => {
    // ── isValidIpAddress：合法地址 ──

    it('isValidIp_typical_address', 0, () => {
      expect(isValidIpAddress('192.168.1.1')).assertTrue()
    })

    it('isValidIp_max_each_segment', 0, () => {
      expect(isValidIpAddress('255.255.255.255')).assertTrue()
    })

    it('isValidIp_zero_in_middle', 0, () => {
      expect(isValidIpAddress('10.0.0.1')).assertTrue()
    })

    // ── isValidIpAddress：非法地址 ──

    it('isValidIp_empty_string', 0, () => {
      expect(isValidIpAddress('')).assertFalse()
    })

    it('isValidIp_last_segment_zero', 0, () => {
      expect(isValidIpAddress('192.168.1.0')).assertFalse()
    })

    it('isValidIp_segment_over_255', 0, () => {
      expect(isValidIpAddress('192.168.1.256')).assertFalse()
    })

    it('isValidIp_leading_zero', 0, () => {
      expect(isValidIpAddress('192.168.01.1')).assertFalse()
    })

    it('isValidIp_three_segments', 0, () => {
      expect(isValidIpAddress('192.168.1')).assertFalse()
    })

    it('isValidIp_five_segments', 0, () => {
      expect(isValidIpAddress('192.168.1.1.1')).assertFalse()
    })

    it('isValidIp_non_numeric', 0, () => {
      expect(isValidIpAddress('192.168.1.abc')).assertFalse()
    })

    it('isValidIp_with_spaces', 0, () => {
      expect(isValidIpAddress('192.168.1.1 ')).assertFalse()
    })

    it('isValidIp_empty_segment', 0, () => {
      expect(isValidIpAddress('192.168..1')).assertFalse()
    })

    it('isValidIp_negative_segment', 0, () => {
      expect(isValidIpAddress('192.168.-1.1')).assertFalse()
    })

    // ── isUrl ──

    it('isUrl_http_valid', 0, () => {
      expect(isUrl('http://example.com')).assertTrue()
    })

    it('isUrl_https_valid', 0, () => {
      expect(isUrl('https://example.com/path')).assertTrue()
    })

    it('isUrl_no_protocol_invalid', 0, () => {
      expect(isUrl('example.com')).assertFalse()
    })

    it('isUrl_empty_invalid', 0, () => {
      expect(isUrl('')).assertFalse()
    })

    it('isUrl_ftp_invalid', 0, () => {
      expect(isUrl('ftp://example.com')).assertFalse()
    })
  })
}
