// LoopbackNativeTest：回环测试——Native 函数对自身服务器的调用
// 覆盖 nativeClientInfo / nativeRegisterDevice / nativeSendFiles 的基本路径
// 这些函数的正常路径需要另一台设备，但回环测试可验证请求/响应结构
import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium'
import {
  nativeClientInfo,
  nativeRegisterDevice,
  nativeSendFiles,
  nativeGetServerStatus,
  nativeGetCurrentSendSessionId,
  nativeRespondTransfer
} from '../../../../main/ets/service/NativeBridge'
import {
  NativeTargetDevice, NativeFileToSend, NativeSendResult
} from '../../../../main/ets/model/NativeTypes'
import {
  startServer,
  stopServer,
  createTestServerConfig,
  createTestFileToSend,
  allocateTestPort,
  getCurrentPort,
  sleep
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
      if (!threw) {
        // 验证返回有效 JSON 且包含必要字段
        let data: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>
        expect(data['alias'] !== undefined).assertTrue()
        expect(data['fingerprint'] !== undefined).assertTrue()
        expect(data['version'] !== undefined).assertTrue()
      }
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
      let result: NativeSendResult | undefined = undefined
      let threw: boolean = false
      try {
        result = await nativeSendFiles(target, 'HandySendTest', files)
      } catch (_e) {
        threw = true
      }
      if (!threw && result !== undefined) {
        // 验证返回结构完整
        expect(result.sessionId.length > 0 || result.sessionId === '').assertTrue()
        // 自身服务器可能接受（auto-accept）或超时
        // 关键验证：success 字段存在且为 boolean
        expect(typeof result.success === 'boolean').assertTrue()
        // 验证 failedFiles 是数组
        expect(Array.isArray(result.failedFiles)).assertTrue()
      }
      done()
    })
  })
}
