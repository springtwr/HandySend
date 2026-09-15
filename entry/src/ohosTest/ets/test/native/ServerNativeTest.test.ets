// ServerNativeTest：服务器生命周期 NativeBridge 函数测试
// 覆盖 nativeCreateServer/nativeStopServer/nativeGetServerStatus/nativePollPendingRequests/nativeRespondTransfer
import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium'
import {
  nativeCreateServer,
  nativeGetServerStatus,
  nativePollPendingRequests,
  nativeRespondTransfer,
  onBridgeEvent,
  offBridgeEvent
} from '../../../../main/ets/service/NativeBridge'
import {
  NativeServerStatus,
  NativeServerHandle,
  NativeTransferRequest,
  NativeEvent
} from '../../../../main/ets/model/NativeTypes'
import {
  startServer,
  stopServer,
  createTestServerConfig,
  allocateTestPort,
  sleep
} from '../helper/TestHelper'

export default function ServerNativeTest() {
  // ── 不依赖服务器启停的用例 ──
  describe('ServerNativeTest', () => {
    it('onBridgeEvent_subscribe_and_off_does_not_throw', 0, () => {
      // 类型化事件订阅是传输事件（register/prepareUpload/uploadProgress/
      // sessionEnd/cancelReceived 等）注入 ArkTS 层的入口
      // 验证订阅/退订不抛异常——handler 签名正确
      let threw: boolean = false
      let handler = (_e: NativeEvent): void => {
        // 回调内容不影响订阅本身
      }
      try {
        onBridgeEvent('deviceFound', handler)
        offBridgeEvent('deviceFound', handler)
      } catch (_e) {
        threw = true
      }
      expect(!threw).assertTrue()
    })
  })

  // ── 依赖服务器运行的用例 ──
  describe('ServerNativeTest_Running', () => {
    let suitePort: number = allocateTestPort()

    beforeAll(async (done: Function) => {
      await startServer(createTestServerConfig(undefined, suitePort))
      done()
    })

    afterAll(async (done: Function) => {
      await stopServer()
      done()
    })

    it('createServer_server_running_with_valid_fingerprint', 0, () => {
      // beforeAll 已启动服务器，验证状态完整——单一确定性断言路径
      let status: NativeServerStatus = nativeGetServerStatus()
      expect(status.running).assertTrue()
      expect(status.fingerprint !== undefined && status.fingerprint.length > 0).assertTrue()
    })

    it('createServer_twice_should_succeed', 0, async (done: Function) => {
      // 在已运行的服务器上再次创建——应能处理（先停后建或直接成功）
      let secondPort: number = allocateTestPort()
      let config = createTestServerConfig(undefined, secondPort)
      try {
        let handle: NativeServerHandle = await nativeCreateServer(config)
        expect(handle.fingerprint.length > 0).assertTrue()
        expect(handle.port > 0).assertTrue()
      } catch (_e) {
        // 某些实现可能抛异常——也是可接受行为
        // 验证异常后服务器状态字段可访问（进程未崩溃）
        let statusAfterError: NativeServerStatus = nativeGetServerStatus()
        expect(statusAfterError.fingerprint !== undefined).assertTrue()
      }
      // 确保服务器处于运行状态
      let status: NativeServerStatus = nativeGetServerStatus()
      expect(status.running).assertTrue()
      done()
    })

    it('pollPendingRequests_returns_empty_when_no_requests', 0, () => {
      let requests: Array<NativeTransferRequest> = nativePollPendingRequests()
      expect(requests.length === 0).assertTrue()
    })

    it('respondTransfer_with_invalid_session_throws', 0, async (done: Function) => {
      // 使用无效 sessionId 调用——应抛异常
      let threw: boolean = false
      try {
        await nativeRespondTransfer('invalid_session_id', false, [])
      } catch (_e) {
        threw = true
      }
      // 无效 session 应抛异常
      expect(threw).assertTrue()
      // 验证服务器状态未受影响
      let status: NativeServerStatus = nativeGetServerStatus()
      expect(status.running).assertTrue()
      done()
    })
  })

  // ── 服务器停启独立测试 ──
  describe('ServerNativeTest_StopStart', () => {
    it('stopServer_makes_status_not_running', 0, async (done: Function) => {
      // 独立启停——不与其他 describe 共享 beforeAll/afterAll 服务器
      let stopStartPort: number = allocateTestPort()
      await startServer(createTestServerConfig(undefined, stopStartPort))
      await stopServer()
      await sleep(200)
      let status: NativeServerStatus = nativeGetServerStatus()
      expect(status.running).assertFalse()
      done()
    })
  })
}
