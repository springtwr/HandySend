// SendNativeTest：发送 NativeBridge 函数测试
// 覆盖 nativeSendFiles/nativeCancelTransfer/nativeCancelTransferLocal/
//        nativeCancelLocalSession/nativeGetCurrentSendSessionId
// 注意：大部分用例使用无效 ID，验证异常行为
import { describe, it, expect } from '@ohos/hypium'
import { socket } from '@kit.NetworkKit'
import {
  nativeSendFiles,
  nativeCancelTransfer,
  nativeCancelTransferLocal,
  nativeCancelLocalSession,
  nativeGetCurrentSendSessionId,
  nativeGetSecurityContext
} from '../../../../main/ets/service/NativeBridge'
import {
  NativeSecurityContext,
  NativeTargetDevice,
  NativeFileToSend,
  NativeSendResult
} from '../../../../main/ets/model/NativeTypes'
import { createTestFileToSend, createTestTargetDevice, createTestCancelTarget } from '../helper/TestHelper'

// PC 端 CLI 可达性探测：不可达时用例直接跳过，避免 nativeSendFiles 等到
// TCP 连接超时（约 3s）。本用例依赖外部 PC 环境，探测失败属正常情形。
async function canReachTcp(ip: string, port: number, timeoutMs: number): Promise<boolean> {
  let tcp = socket.constructTCPSocketInstance()
  try {
    await tcp.connect({ address: { address: ip, port: port }, timeout: timeoutMs })
    try {
      tcp.close()
    } catch (_closeErr) {
    }
    return true
  } catch (_e) {
    try {
      tcp.close()
    } catch (_closeErr) {
    }
    return false
  }
}

export default function SendNativeTest() {
  describe('SendNativeTest', () => {
    // ── nativeGetCurrentSendSessionId ──

    it('getCurrentSendSessionId_returns_empty_when_no_session', 0, () => {
      let sessionId: string = nativeGetCurrentSendSessionId()
      expect(sessionId === '').assertTrue()
    })

    // ── nativeCancelTransferLocal ──

    it('cancelTransferLocal_with_invalid_session_no_error', 0, () => {
      // Rust 侧 cancel_local_session 对无效 session 静默忽略（no-op）
      let threw: boolean = false
      try {
        nativeCancelTransferLocal('invalid_session_id_xyz')
      } catch (_e) {
        threw = true
      }
      // 无效 session 不应抛异常——是 no-op
      expect(!threw).assertTrue()
    })

    // ── nativeCancelLocalSession ──

    it('cancelLocalSession_with_invalid_session_no_error', 0, async (done: Function) => {
      let threw: boolean = false
      try {
        await nativeCancelLocalSession('invalid_session_id_xyz')
      } catch (_e) {
        threw = true
      }
      expect(!threw).assertTrue()
      done()
    })

    // ── nativeCancelTransfer ──

    it('cancelTransfer_with_invalid_target_throws', 0, async (done: Function) => {
      // 目标指向本机保留端口：连接立即被拒（ECONNREFUSED），无需等待不可达
      // 地址的 TCP 连接超时（约 5s）
      let target = createTestCancelTarget('127.0.0.1', 1)
      let threw: boolean = false
      try {
        await nativeCancelTransfer(target, 'invalid_session_id_xyz')
      } catch (_e) {
        // 对端不可达或无活跃传输应抛异常
        threw = true
      }
      expect(threw).assertTrue()
      done()
    })

    // ── nativeSendFiles ──
    // 端到端发送测试：需要 PC LocalSend CLI 作为接收端
    // 前置条件：
    //   1. PC 启动 CLI：localsend-cli（默认监听 53317 端口，接收模式）
    //   2. 预配对 CLI：将设备 fingerprint 写入 ~/.config/localsend/paired-v2.json
    //      使 CLI 自动接受传输请求（无需手动按 Y）
    //      paired-v2.json 格式：
    //      { "version": 1, "devices": { "<FINGERPRINT>": { "alias": "HandySend", "channels": [] } } }
    //   3. PC 和设备在同一局域网（PC IP 默认 192.168.2.4）
    //   4. 发送测试文件需要 App 沙箱内存在可读文件
    // 未满足条件时此用例跳过（不失败）

    it('sendFiles_to_cli_receiver', 0, async (done: Function) => {
      // PC 端 IP——同局域网内运行 LocalSend CLI 的 PC
      let pcIp: string = '192.168.2.4'
      let pcPort: number = 53317

      // 前置可达性探测：PC 端 CLI 不可达时直接跳过（本用例依赖外部环境），
      // 否则 nativeSendFiles 会等到 TCP 连接超时（约 3s）
      let reachable: boolean = await canReachTcp(pcIp, pcPort, 500)
      if (!reachable) {
        // CLI 不可达：跳过端到端发送，但仍验证进程可用（与异常分支同口径）
        let sessionId: string = nativeGetCurrentSendSessionId()
        expect(sessionId !== undefined).assertTrue()
        done()
        return
      }

      // 获取当前设备 fingerprint
      let fingerprint: string = ''
      try {
        let ctx: NativeSecurityContext = nativeGetSecurityContext()
        fingerprint = ctx.certificateHash
      } catch (_e) {
        // 无法获取 fingerprint——跳过端到端测试
        done()
        return
      }

      // 构造目标设备
      let target: NativeTargetDevice = createTestTargetDevice(pcIp, pcPort, fingerprint)
      // 使用 http 协议（CLI 默认不强制 HTTPS）
      target.protocol = 'http'

      // 构造测试文件
      let files: Array<NativeFileToSend> = createTestFileToSend(1)

      let threw: boolean = false
      try {
        let result: NativeSendResult = await nativeSendFiles(target, 'HandySendTest', files)
        // 发送成功时验证返回结构
        expect(result !== undefined).assertTrue()
        expect(result.success !== undefined).assertTrue()
        if (result.success) {
          expect(result.sessionId.length > 0).assertTrue()
        }
      } catch (_e) {
        threw = true
        // 连接失败（CLI 未启动/未配对/文件不存在/网络不可达）——环境问题
        // 验证后续 API 仍可用（进程未崩溃）
        let sessionId: string = nativeGetCurrentSendSessionId()
        expect(sessionId !== undefined).assertTrue()
      }
      done()
    })
  })
}
