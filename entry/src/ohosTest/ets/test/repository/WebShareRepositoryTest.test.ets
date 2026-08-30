// WebShareRepositoryTest：Web 分享仓库业务逻辑测试
// 注意：nativeCreateShareLink/nativeStopShareServer 的基础功能测试
// 已由 WebShareNativeTest 覆盖，此处不重复
// Web 分享的完整业务流程（创建链接→接受下载→下载完成）需要浏览器客户端配合，
// 单设备无法端到端测试，仅验证服务器启停不崩溃
//
// ── 以下业务逻辑因需浏览器客户端配合，单设备无法测试 ──
// 1. 状态转换链：idle → sharing → download_requested → download_accepted/denied
// 2. createShareLink 返回的 URL 在浏览器中可访问且展示正确的文件列表
// 3. handlePrepareDownloadTyped/handleFileDownloadTyped 的多请求并发与互斥
// 4. declineAllPendingWebDownloads 批量拒绝的正确性
// 5. acceptWebDownloadRequest/declineWebDownloadRequest 对同一请求的幂等性
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
