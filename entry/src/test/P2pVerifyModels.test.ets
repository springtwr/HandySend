import { describe, it, expect } from '@ohos/hypium'
import {
  generateRandomGroupName,
  generateRandomPassphrase,
  numberIpToText
} from '../main/ets/model/mta/P2pVerifyModels'

// MTA P2P 验证页纯函数的本地单元测试（无系统 API / UIContext 依赖）。
export default function P2pVerifyModelsTest() {
  describe('P2pVerifyModelsTest', () => {
    // ── generateRandomGroupName 群组名格式 ──

    it('groupName_has_direct_prefix', 0, () => {
      let name = generateRandomGroupName()
      expect(name.startsWith('DIRECT-')).assertTrue()
    })

    it('groupName_has_8_char_suffix', 0, () => {
      let name = generateRandomGroupName()
      // 前缀 DIRECT- 为 7 个字符，加上 8 位随机字符共 15 个字符
      expect(name.length).assertEqual(15)
    })

    it('groupName_multi_call_varys', 0, () => {
      let a = generateRandomGroupName()
      let b = generateRandomGroupName()
      expect(a === b).assertFalse()
    })

    // ── generateRandomPassphrase 密码格式 ──

    it('passphrase_length_is_8', 0, () => {
      let psk = generateRandomPassphrase()
      expect(psk.length).assertEqual(8)
    })

    it('passphrase_uses_alphanumeric', 0, () => {
      let psk = generateRandomPassphrase()
      expect(/^[A-Za-z0-9]{8}$/.test(psk)).assertTrue()
    })

    // ── numberIpToText IP 转换 ──

    it('ip_zero_to_0000', 0, () => {
      expect(numberIpToText(0)).assertEqual('0.0.0.0')
    })

    it('ip_loopback_to_127001', 0, () => {
      expect(numberIpToText(2130706433)).assertEqual('127.0.0.1')
    })

    it('ip_192168491_to_text', 0, () => {
      expect(numberIpToText(3232237857)).assertEqual('192.168.49.1')
    })

    it('ip_max_to_255255255255', 0, () => {
      expect(numberIpToText(4294967295)).assertEqual('255.255.255.255')
    })

    it('ip_19216811_to_text', 0, () => {
      expect(numberIpToText(3232235777)).assertEqual('192.168.1.1')
    })
  })
}
