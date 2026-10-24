// WebShareRepositoryTest：网页分享仓库冒烟测试
// 自研单服务架构下，面板只做服务启停与状态投影；
// 传输行为由 Rust 集成测试覆盖，此处仅验证服务器启停不崩溃
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
      // WebShareRepository 依赖服务器运行，验证前置条件
      let status = nativeGetServerStatus()
      expect(status.running).assertTrue()
    })
  })
}
