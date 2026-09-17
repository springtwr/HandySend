// LoopbackNativeTest：回环测试——Native 函数对自身服务器的调用
// 覆盖 nativeClientInfo / nativeRegisterDevice / nativeSendFiles 的基本路径
// 这些函数的正常路径需要另一台设备，但回环测试可验证请求/响应结构
import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium'
import {
  nativeClientInfo,
  nativeRegisterDevice,
  nativeSendFiles,
  nativeRespondTransfer,
  onBridgeEvent,
  offBridgeEvent
} from '../../../../main/ets/service/NativeBridge'
import {
  NativeTargetDevice,
  NativeSendResult,
  NativeEvent,
  NativePrepareUploadEvent
} from '../../../../main/ets/model/NativeTypes'
import {
  startServer,
  stopServer,
  createTestServerConfig,
  createTestFileToSend,
  allocateTestPort
} from '../helper/TestHelper'

export default function LoopbackNativeTest() {
  describe('LoopbackNativeTest', () => {
    let suitePort: number = allocateTestPort()
    let serverFingerprint: string = ''

    beforeAll(async (done: Function) => {
      let handle = await startServer(createTestServerConfig(undefined, suitePort))
      serverFingerprint = handle.fingerprint
      done()
    })

    afterAll(async (done: Function) => {
      await stopServer()
      done()
    })

    // ── nativeClientInfo ──

    it('clientInfo_against_own_server_returns_valid_json', 0, async (done: Function) => {
      // 查询自身服务器的 /info 端点
      let resultStr: string = ''
      let threw: boolean = false
      try {
        resultStr = await nativeClientInfo('http', '127.0.0.1', suitePort)
      } catch (_e) {
        threw = true
      }
      // 回环 http 请求自身服务器应成功——失败即回归（此前异常分支零断言恒通过）
      expect(threw).assertFalse()
      // 验证返回有效 JSON 且包含必要字段
      let data: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>
      expect(data['alias'] !== undefined).assertTrue()
      expect(data['fingerprint'] !== undefined).assertTrue()
      expect(data['version'] !== undefined).assertTrue()
      done()
    })

    // ── nativeRegisterDevice ──

    it('registerDevice_against_own_server_returns_valid_result', 0, async (done: Function) => {
      // 向自身服务器注册
      let threw: boolean = false
      try {
        let result = await nativeRegisterDevice(
          '127.0.0.1', suitePort,
          'HandySendTest', serverFingerprint, 'http',
          'TestModel', 'mobile', suitePort,
          '127.0.0.1'
        )
        // 验证返回结构
        expect(result.alias.length > 0).assertTrue()
        expect(result.fingerprint.length > 0).assertTrue()
        expect(result.version.length > 0).assertTrue()
      } catch (_e) {
        threw = true
      }
      // 回环注册可能因 mTLS 或网络策略失败——不崩溃即可
      expect(!threw).assertTrue()
      done()
    })

    // ── nativeSendFiles ──

    it('sendFiles_against_own_server_returns_structured_result', 0, async (done: Function) => {
      // 向自身服务器发送文件——服务器会收到 prepareUpload 事件
      let files = createTestFileToSend(1)
      let target: NativeTargetDevice = {
        ip: '127.0.0.1',
        port: suitePort,
        fingerprint: serverFingerprint,
        protocol: 'http'
      }
      // 服务器发出 prepareUpload 后必须由调用方决策，否则发送侧会一直等到
      // 决策超时（约 10s）。本用例只验证返回结构的完整性，故收到即拒绝，
      // 不需要真实落盘。
      let decideHandler = (e: NativeEvent): void => {
        if (e.type === 'prepareUpload') {
          let pe = e as NativePrepareUploadEvent
          nativeRespondTransfer(pe.sessionId, false)
        }
      }
      onBridgeEvent('prepareUpload', decideHandler)

      let result: NativeSendResult | undefined = undefined
      let threw: boolean = false
      try {
        result = await nativeSendFiles(target, 'HandySendTest', files)
      } catch (_e) {
        threw = true
      }
      // 无论发送成败都退订，避免影响后续用例
      offBridgeEvent('prepareUpload', decideHandler)
      // 主动决策后应正常返回结构化结果而非抛异常——决策链路若回归（如
      // respondTransfer 失效退回超时），会在此处失败
      expect(threw).assertFalse()
      expect(result !== undefined).assertTrue()
      if (!threw && result !== undefined) {
        // 验证返回结构完整
        expect(typeof result.sessionId === 'string').assertTrue()
        // 本用例对 prepareUpload 一律拒绝，success 必须为 false——
        // 拒绝被误报为成功（或反之）在此处失败
        expect(result.success).assertFalse()
        // 验证 failedFiles 是数组
        expect(Array.isArray(result.failedFiles)).assertTrue()
      }
      done()
    })
  })
}
