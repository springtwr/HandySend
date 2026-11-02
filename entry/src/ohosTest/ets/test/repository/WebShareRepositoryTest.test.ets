// WebShareRepositoryTest：LocalSend 服务器启停冒烟测试
// 网页服务由自研独立原生服务承载（WebShareRepository 管理），不依赖 LocalSend 服务器；
// 本套件仅验证两者解耦后 LocalSend 服务器的启停仍正常，网页链路由 Rust 集成测试覆盖
import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium'
import {
  nativeGetServerStatus
} from '../../../../main/ets/service/NativeBridge'
import { startServer, stopServer, allocateTestPort } from '../helper/TestHelper'

export default function WebShareRepositoryTest() {
  describe('WebShareRepositoryTest', () => {
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
      await stopServer()
      done()
    })

    // ── 服务器运行状态验证 ──

    it('server_running_for_web_share', 0, () => {
      // LocalSend 服务器启停不涉及网页服务；此处验证既有服务器路径仍可用
      let status = nativeGetServerStatus()
      expect(status.running).assertTrue()
    })
  })
}
