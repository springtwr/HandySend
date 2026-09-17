// UtilityNativeTest：工具函数 NativeBridge 测试
// 覆盖 nativeSanitizeFileName/nativeGetNetworkInterfaces/
//        nativeHashFileStream/nativeCancelHash/nativeHashBuffer/nativeCreateCancelToken/
//        nativeFailFileDownload/nativeFailFileUpload/nativeFlushRustLogs
// 注意：工具函数不需要服务器运行
// computeFingerprintHash 纯逻辑由 Rust convert.rs 测试覆盖
import { describe, it, expect } from '@ohos/hypium'
import {
  nativeSanitizeFileName,
  nativeGetNetworkInterfaces,
  nativeHashBuffer,
  nativeCreateCancelToken,
  nativeFailFileDownload,
  nativeFailFileUpload,
  nativeCancelHash,
  nativePollDebugLogWithLevels,
  nativeFlushRustLogs,
  nativeHashFileStream
} from '../../../../main/ets/service/NativeBridge'
import { NativeCancellationToken } from '../../../../main/ets/model/NativeTypes'
import { NetworkInterfaceInfo } from 'localsend_ohrs'

export default function UtilityNativeTest() {
  describe('UtilityNativeTest', () => {

    // ── nativeSanitizeFileName ──

    it('sanitizeFileName_normal_name', 0, () => {
      let result: string = nativeSanitizeFileName('test_file.txt')
      expect(result === 'test_file.txt').assertTrue()
    })

    it('sanitizeFileName_special_chars', 0, () => {
      let result: string = nativeSanitizeFileName('test<>file|name?.txt')
      // HarmonyOS/Linux 上 Rules::Posix 仅替换 / 和控制字符
      // <>|? 在 POSIX 文件系统中合法，不会被替换
      expect(result === 'test<>file|name?.txt').assertTrue()
    })

    it('sanitizeFileName_empty_string_returns_untitled', 0, () => {
      let result: string = nativeSanitizeFileName('')
      // 空字符串应返回默认占位名 "untitled"
      expect(result === 'untitled').assertTrue()
    })

    it('sanitizeFileName_path_separators', 0, () => {
      let result: string = nativeSanitizeFileName('test/file\\name.txt')
      // POSIX 规则下 / 被替换为 _，\ 在 POSIX 中合法
      expect(result === 'test_file\\name.txt').assertTrue()
    })

    // ── nativeGetNetworkInterfaces ──

    it('getNetworkInterfaces_returns_nonempty_array', 0, () => {
      let interfaces: Array<NetworkInterfaceInfo> = nativeGetNetworkInterfaces()
      // 真机上至少应有一个网络接口
      expect(interfaces.length > 0).assertTrue()
    })

    it('getNetworkInterfaces_interface_has_name_and_ip', 0, () => {
      let interfaces: Array<NetworkInterfaceInfo> = nativeGetNetworkInterfaces()
      expect(interfaces.length > 0).assertTrue()
      let iface: NetworkInterfaceInfo = interfaces[0]
      expect(iface.name.length > 0).assertTrue()
      expect(iface.ip.length > 0).assertTrue()
    })

    // ── nativeCreateCancelToken ──

    it('createCancelToken_returns_valid_token', 0, () => {
      let token: NativeCancellationToken = nativeCreateCancelToken()
      expect(token.id !== undefined).assertTrue()
      expect(token.id.length > 0).assertTrue()
    })

    it('createCancelToken_unique_ids', 0, () => {
      let token1: NativeCancellationToken = nativeCreateCancelToken()
      let token2: NativeCancellationToken = nativeCreateCancelToken()
      expect(token1.id !== token2.id).assertTrue()
    })

    // ── nativeHashBuffer ──

    it('hashBuffer_returns_deterministic_hash', 0, () => {
      let buffer1 = new ArrayBuffer(4)
      let view1 = new Uint8Array(buffer1)
      view1[0] = 1;
      view1[1] = 2;
      view1[2] = 3;
      view1[3] = 4
      let buffer2 = new ArrayBuffer(4)
      let view2 = new Uint8Array(buffer2)
      view2[0] = 1;
      view2[1] = 2;
      view2[2] = 3;
      view2[3] = 4
      let hash1: string = nativeHashBuffer(buffer1)
      let hash2: string = nativeHashBuffer(buffer2)
      // 相同输入应产生相同哈希
      expect(hash1 === hash2).assertTrue()
      expect(hash1.length > 0).assertTrue()
    })

    // ── nativeFailFileDownload ──

    it('failFileDownload_with_invalid_ids_throws', 0, () => {
      let threw: boolean = false
      try {
        nativeFailFileDownload('invalid_session', 'invalid_file')
      } catch (_e) {
        threw = true
      }
      // 无效 ID 应抛异常
      expect(threw).assertTrue()
    })

    // ── nativeFailFileUpload ──

    it('failFileUpload_with_invalid_ids_throws', 0, () => {
      let threw: boolean = false
      try {
        nativeFailFileUpload('invalid_session', 'invalid_file')
      } catch (_e) {
        threw = true
      }
      expect(threw).assertTrue()
    })

    // ── nativeCancelHash ──

    it('cancelHash_with_invalid_id_throws', 0, async (done: Function) => {
      let threw: boolean = false
      try {
        await nativeCancelHash('invalid_cancel_id')
      } catch (_e) {
        threw = true
      }
      expect(threw).assertTrue()
      done()
    })

    // ── nativePollDebugLogWithLevels ──

    it('pollDebugLog_returns_array', 0, () => {
      // pollDebugLog 返回 Rust 侧缓存的调试日志
      let logs: Array<string> = nativePollDebugLogWithLevels()
      // 返回值应为数组（可能为空）
      expect(logs !== undefined).assertTrue()
      expect(Array.isArray(logs)).assertTrue()
    })

    it('pollDebugLog_entries_are_strings', 0, () => {
      let logs: Array<string> = nativePollDebugLogWithLevels()
      for (let i = 0; i < logs.length; i++) {
        expect(typeof logs[i] === 'string').assertTrue()
      }
    })

    // ── nativeFlushRustLogs ──

    it('flushRustLogs_empty_and_repeat_calls_do_not_throw', 0, () => {
      // 冒烟验证：先排空缓冲，对空缓冲及连续调用均不应抛异常。
      // level|message 分割与未知级别降级依赖 Rust 侧注入的日志行，
      // ArkTS 测试无法控制缓冲内容，故此处只覆盖调用安全性。
      let threw: boolean = false
      try {
        nativePollDebugLogWithLevels()
        nativeFlushRustLogs()
        nativeFlushRustLogs()
      } catch (_e) {
        threw = true
      }
      expect(!threw).assertTrue()
    })

    // ── nativeHashFileStream ──

    it('hashFileStream_nonexistent_file_throws', 0, async (done: Function) => {
      // 不存在的文件应抛异常
      let threw: boolean = false
      try {
        await nativeHashFileStream('/data/storage/el2/base/haps/entry/cache/nonexistent_test_file_abc123.txt')
      } catch (_e) {
        threw = true
      }
      expect(threw).assertTrue()
      done()
    })
  })
}
