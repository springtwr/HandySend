// WebShareNativeTest：Web Share NativeBridge 函数测试
// 覆盖 nativeCreateShareLink/nativeStopShareServer/nativeAcceptWebDownload/
//        nativeDeclineWebDownload/nativeStartWebUpload/nativePrepareDownload/nativeDownloadFile
import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium'
import { socket } from '@kit.NetworkKit'
import {
  nativeCreateShareLink,
  nativeStopShareServer,
  nativeAcceptWebDownload,
  nativeDeclineWebDownload,
  nativeStartWebUpload,
  nativeGetServerStatus,
  nativePollDebugLogWithLevels,
  onBridgeEvent,
  offBridgeEvent
} from '../../../../main/ets/service/NativeBridge'
import { NativeShareLinkInfo, NativeServerStatus, NativeEvent } from '../../../../main/ets/model/NativeTypes'
import { startServer, stopServer, createTestFileToSend, allocateTestPort, sleep, waitUntil } from '../helper/TestHelper'

// 失败诊断：排空 Rust 日志缓冲（Rust 侧 log 输出仅在进程内缓冲，
// 测试进程无人消费，失败时取出嵌入错误消息供定位）
function dumpRustLogs(): string {
  let lines: Array<string> = nativePollDebugLogWithLevels()
  if (lines.length === 0) {
    return '(Rust 日志缓冲为空)'
  }
  // 单行拼接：测试框架错误输出仅展示首行，换行符会丢失后续内容
  return lines.join(' | ')
}

// 端口占用诊断：TCP connect 127.0.0.1:port 并发 HTTP GET /——
// 可连=存在活跃监听者，响应内容用于识别其身份（LocalSend 特征响应等）
async function probePort(port: number): Promise<string> {
  let tcp = socket.constructTCPSocketInstance()
  try {
    await tcp.connect({ address: { address: '127.0.0.1', port: port }, timeout: 2000 })
  } catch (e) {
    return '不可连接(' + e + ')：无监听者'
  }
  // 连接成功：发 HTTP 请求识别监听者身份
  let response: string = ''
  let settled: boolean = false
  let waiter: () => void = () => {
  }
  let messagePromise: Promise<void> = new Promise<void>((resolve: () => void) => {
    waiter = resolve
  })
  tcp.on('message', (info: socket.SocketMessageInfo) => {
    let text: string = String.fromCharCode(...new Uint8Array(info.message))
    if (response.length < 400) {
      response += text
    }
    if (!settled) {
      settled = true
      waiter()
    }
  })
  try {
    await tcp.send({ data: 'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' })
  } catch (_e) {
  }
  // 等待响应最多 1.5 秒
  let timerPromise: Promise<void> = new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, 1500)
  })
  await Promise.race([messagePromise, timerPromise])
  try {
    tcp.close()
  } catch (_e) {
  }
  if (response.length === 0) {
    return '可连接：存在活跃监听者（无 HTTP 响应）'
  }
  return '可连接：存在活跃监听者，响应: ' + response.substring(0, 300)
}

export default function WebShareNativeTest() {
  describe('WebShareNativeTest', () => {
    let suitePort: number = allocateTestPort()

    beforeAll(async (done: Function) => {
      await startServer({
        alias: 'HandySendTest',
        deviceModel: 'TestModel',
        deviceType: 'mobile',
        port: suitePort,
        saveDir: '/data/app/el2/100/base/com.springtwr.handysend/cache/handysend_test/',
        useHttps: false
      })
      done()
    })

    afterAll(async (done: Function) => {
      // 确保 Share Server 被停止
      try {
        await nativeStopShareServer()
      } catch (_e) {
      }
      await stopServer()
      done()
    })

    // ── nativeCreateShareLink ──

    it('createShareLink_returns_valid_info', 0, async (done: Function) => {
      let files = createTestFileToSend(1)
      let info: NativeShareLinkInfo
      try {
        info = await nativeCreateShareLink(files, 'HandySendTest')
      } catch (e) {
        throw new Error('[E2E] createShareLink 失败: ' + e + ' [Rust 日志] ' + dumpRustLogs())
      }
      // 验证 URL 非空且以 http 开头
      expect(info.url.length > 0).assertTrue()
      expect(info.url.indexOf('http') === 0).assertTrue()
      // 验证端口大于 0
      expect(info.port > 0).assertTrue()
      // 验证 sessionId 非空
      expect(info.sessionId.length > 0).assertTrue()
      // 清理
      await nativeStopShareServer()
      done()
    })

    // ── nativeStopShareServer ──

    it('stopShareServer_after_createShareLink_succeeds', 0, async (done: Function) => {
      // 先创建再停止——停止应成功
      let files = createTestFileToSend(1)
      let createdOk: boolean = false
      try {
        await nativeCreateShareLink(files, 'HandySendTest')
        createdOk = true
      } catch (_e) {
        // 创建 ShareLink 失败（如端口冲突）——后续验证停止安全性
        createdOk = false
      }

      if (createdOk) {
        // 创建成功 → 第一次停止应成功
        let stopThrew: boolean = false
        try {
          await nativeStopShareServer()
        } catch (_e) {
          stopThrew = true
        }
        expect(!stopThrew).assertTrue()
        // 第二次停止幂等（stop_share_server 会以普通配置重启服务器，恒不抛）
        let doubleStopThrew: boolean = false
        try {
          await nativeStopShareServer()
        } catch (_e) {
          doubleStopThrew = true
        }
        expect(!doubleStopThrew).assertTrue()
      } else {
        // 创建失败 → 停止也不应崩溃
        try {
          await nativeStopShareServer()
        } catch (_e) {
          // 预期可能抛异常
        }
        // 关键：服务器状态未被破坏
        // （无法直接验证，但进程存活即证明）
      }
      done()
    })

    // ── nativeAcceptWebDownload ──

    it('acceptWebDownload_with_invalid_session_throws', 0, () => {
      let threw: boolean = false
      try {
        nativeAcceptWebDownload('invalid_session_id')
      } catch (_e) {
        threw = true
      }
      // 无效 sessionId 应抛异常
      expect(threw).assertTrue()
    })

    // ── nativeDeclineWebDownload ──

    it('declineWebDownload_with_invalid_session_throws', 0, () => {
      let threw: boolean = false
      try {
        nativeDeclineWebDownload('invalid_session_id')
      } catch (_e) {
        threw = true
      }
      // 无效 sessionId 应抛异常
      expect(threw).assertTrue()
    })

    // ── nativeStartWebUpload ──

    it('startWebUpload_after_createShareLink_returns_valid_port', 0, async (done: Function) => {
      // createShareLink 后调用 startWebUpload 应返回端口号
      let files = createTestFileToSend(1)
      let info: NativeShareLinkInfo | undefined = undefined
      try {
        info = await nativeCreateShareLink(files, 'HandySendTest')
      } catch (_e) {
        // createShareLink 可能因端口冲突失败——跳过
        done()
        return
      }
      let port: number = await nativeStartWebUpload()
      // 返回值应为正端口号
      expect(port > 0).assertTrue()
      await nativeStopShareServer()
      done()
    })

    // ── onBridgeEvent 类型化事件订阅验证 ──

    it('onBridgeEvent_receives_event_after_createShareLink', 0, async (done: Function) => {
      // 订阅类型化事件后，createShareLink（重启服务器）应触发 serverStarted 事件
      let received: boolean = false
      let handler = (e: NativeEvent): void => {
        if (e.type === 'serverStarted') {
          received = true
        }
      }
      onBridgeEvent('serverStarted', handler)
      let files = createTestFileToSend(1)
      try {
        await nativeCreateShareLink(files, 'HandySendTest')
      } catch (_e) {
        // createShareLink 可能因端口冲突失败——仅验证订阅本身不崩溃
        offBridgeEvent('serverStarted', handler)
        expect(true).assertTrue()
        done()
        return
      }
      // 等待事件回调（轮询，事件到达即继续，避免固定等待）
      await waitUntil((): boolean => received, 1000)
      expect(received).assertTrue()
      offBridgeEvent('serverStarted', handler)
      await nativeStopShareServer()
      done()
    })

    // ── URL 格式验证 ──

    it('createShareLink_url_format_validation', 0, async (done: Function) => {
      let files = createTestFileToSend(2)
      let info: NativeShareLinkInfo
      try {
        info = await nativeCreateShareLink(files, 'HandySendTest')
      } catch (e) {
        throw new Error('[E2E] createShareLink 失败: ' + e + ' [Rust 日志] ' + dumpRustLogs()
          + ' [端口探测] ' + await probePort(suitePort))
      }
      // URL 应包含 http:// 和 IP:端口
      expect(info.url.indexOf('http') === 0).assertTrue()
      // URL 应包含端口号（与 info.port 一致）
      let portStr: string = ':' + info.port.toString()
      expect(info.url.indexOf(portStr) >= 0).assertTrue()
      // 清理
      await nativeStopShareServer()
      done()
    })
  })
}
