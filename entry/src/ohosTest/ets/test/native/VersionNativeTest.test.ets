// VersionNativeTest：版本信息 NativeBridge 函数测试
// 覆盖 getNativeLibraryVersion/getLocalSendProtocolVersion/verifyNativeVersion
import { describe, it, expect } from '@ohos/hypium'
import {
  getNativeLibraryVersion,
  getLocalSendProtocolVersion,
  verifyNativeVersion
} from '../../../../main/ets/service/NativeBridge'

// 期望的原生库版本（与 NativeBridge.ets 中 EXPECTED_NATIVE_VERSION 一致）
const EXPECTED_NATIVE_VERSION: string = '1.18.1'

export default function VersionNativeTest() {
  describe('VersionNativeTest', () => {
    // ── getNativeLibraryVersion ──

    it('getNativeVersion_matches_expected_version', 0, () => {
      let version: string = getNativeLibraryVersion()
      expect(version === EXPECTED_NATIVE_VERSION).assertTrue()
    })

    // ── getLocalSendProtocolVersion ──

    it('getProtocolVersion_format_check', 0, () => {
      let version: string = getLocalSendProtocolVersion()
      // 协议版本应为数字格式（如 "2.2"）
      let parts: Array<string> = version.split('.')
      expect(parts.length >= 2).assertTrue()
    })

    // ── verifyNativeVersion ──

    it('verifyNativeVersion_current_version_matches_no_throw', 0, () => {
      // 应用启动时第一个调用的函数——版本匹配时不应抛异常
      let threw: boolean = false
      try {
        verifyNativeVersion()
      } catch (_e) {
        threw = true
      }
      expect(!threw).assertTrue()
    })
  })
}
