// SendLogic.test：发送协议协商纯逻辑测试
// 覆盖 resolveSendProtocol 的 4 种本地/远程 HTTPS 组合
import { describe, it, expect } from '@ohos/hypium'
import { resolveSendProtocol } from '../main/ets/service/repository/SendRepository'

export default function SendLogicTest() {
  describe('SendLogicTest', () => {

    // ── 加密不可降级 ──

    it('local_https_remote_http_returns_null', 0, () => {
      // 本地要求加密但远程不支持——必须拒绝
      let result: string | null = resolveSendProtocol(true, false)
      expect(result === null).assertTrue()
    })

    // ── 双方 HTTPS ──

    it('local_https_remote_https_returns_https', 0, () => {
      let result: string | null = resolveSendProtocol(true, true)
      expect(result === 'https').assertTrue()
    })

    // ── 本地 HTTP 远程 HTTPS（升级） ──

    it('local_http_remote_https_returns_https', 0, () => {
      // 远程只监听 HTTPS，必须升级才能连上
      let result: string | null = resolveSendProtocol(false, true)
      expect(result === 'https').assertTrue()
    })

    // ── 双方 HTTP ──

    it('local_http_remote_http_returns_http', 0, () => {
      let result: string | null = resolveSendProtocol(false, false)
      expect(result === 'http').assertTrue()
    })
  })
}
