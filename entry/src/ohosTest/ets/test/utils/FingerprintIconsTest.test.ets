// FingerprintIcons 指纹校验图标推导测试（安全相关回归保护）。
// toIcons 期望值由算法参考实现（SHA-256 → 前 32 个十六进制字符 → base-260 长除法）
// 离线计算得出，任何偏差都意味着与 LocalSend 指纹图标算法出现分叉，
// 会导致用户无法通过图标网格发现指纹不匹配。
import { describe, it, expect } from '@ohos/hypium'
import { toIcons, getCombinedFingerprint } from '../../../../main/ets/utils/FingerprintIcons'

export default function FingerprintIconsTest() {
  describe('FingerprintIconsTest', () => {
    // ── toIcons：已知输入的确定性结果 ──

    it('toIcons_known_input_produces_expected_icons', 0, () => {
      let icons: Array<string> = toIcons('fp1fp2')
      // 结果长度 = ceil(32 × 4 × ln(2) / ln(260)) = 16
      expect(icons.length).assertEqual(16)
      let expected: Array<number> = [
        0xE38D, 0xF0546, 0xE66D, 0xF0569, 0xE1D7, 0xE5EC, 0xE542, 0xE5E9,
        0xE4DC, 0xF0587, 0xF04CB, 0xE16F, 0xE0C8, 0xE0C8, 0xE66C, 0xE60A
      ]
      for (let i = 0; i < expected.length; i++) {
        expect(icons[i].codePointAt(0) === expected[i]).assertTrue()
      }
    })

    it('toIcons_another_input_produces_expected_icons', 0, () => {
      let icons: Array<string> = toIcons('aaaabbbbccccdddd')
      expect(icons.length).assertEqual(16)
      let expected: Array<number> = [
        0xE0C9, 0xE1D5, 0xE6F2, 0xE640, 0xE68A, 0xE0CF, 0xE185, 0xE179,
        0xE4E4, 0xE2F3, 0xE4BE, 0xE683, 0xE511, 0xE6C1, 0xF0518, 0xE120
      ]
      for (let i = 0; i < expected.length; i++) {
        expect(icons[i].codePointAt(0) === expected[i]).assertTrue()
      }
    })

    it('toIcons_is_deterministic', 0, () => {
      let first: Array<string> = toIcons('determinism-check')
      let second: Array<string> = toIcons('determinism-check')
      expect(first.length === second.length).assertTrue()
      for (let i = 0; i < first.length; i++) {
        expect(first[i].codePointAt(0) === second[i].codePointAt(0)).assertTrue()
      }
    })

    // ── getCombinedFingerprint：排序后拼接 ──

    it('combinedFingerprint_sorts_before_join', 0, () => {
      // 无论本地/远程顺序如何，组合结果一致（排序保证）
      expect(getCombinedFingerprint('bbb', 'aaa')).assertEqual('aaabbb')
      expect(getCombinedFingerprint('aaa', 'bbb')).assertEqual('aaabbb')
    })

    it('combinedFingerprint_equal_fingerprints_doubled', 0, () => {
      expect(getCombinedFingerprint('same', 'same')).assertEqual('samesame')
    })
  })
}
