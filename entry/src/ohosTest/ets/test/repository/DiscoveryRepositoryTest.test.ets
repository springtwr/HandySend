// DiscoveryRepositoryTest：设备发现仓库业务逻辑测试
// 覆盖发现启停全流程（setAnswer → stop 不抛异常）
// 注意：nativeDiscoveryGetDevice/nativeDiscoveryAddDevice 的联动测试
// 已由 DiscoveryNativeTest 覆盖，此处不重复
//
// ── 以下业务逻辑因需多设备配合，单设备无法测试 ──
// 1. 设备合并：同一 fingerprint 的设备在不同 IP 出现时应合并为单条记录
// 2. 离线→在线状态转换：设备消失后再次发现时状态应从 offline 恢复为 online
// 3. discovery_update 事件的设备列表与 Repository 内部状态的同步
//    （需另一台设备实际广播 register 事件触发）
// 这些场景的端到端验证需要两台设备或模拟 mDNS 广播，超出当前测试框架能力
import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium'
import {
  nativeStartDiscoveryV2,
  nativeDiscoverySetAnswerAnnouncements,
  nativeDiscoveryStop
} from '../../../../main/ets/service/NativeBridge'
import { startServer, stopServer, createTestDiscoveryConfig, allocateTestPort, sleep } from '../helper/TestHelper'

export default function DiscoveryRepositoryTest() {
  describe('DiscoveryRepositoryTest', () => {
    let suitePort: number = allocateTestPort()

    beforeAll(async (done: Function) => {
      await startServer({
        alias: 'HandySendTest',
        deviceModel: 'TestModel',
        deviceType: 'mobile',
        port: suitePort,
        saveDir: '/data/app/el2/100/base/com.springtwr.handysend/cache/localsend_test/',
        useHttps: false
      })
      done()
    })

    afterAll(async (done: Function) => {
      await stopServer()
      done()
    })

    // ── 发现启停全流程 ──

    it('discovery_start_set_answer_stop_succeeds', 0, async (done: Function) => {
      let config = createTestDiscoveryConfig()
      let threw: boolean = false
      try {
        await nativeStartDiscoveryV2(config)
        nativeDiscoverySetAnswerAnnouncements(true)
        await sleep(300)
        nativeDiscoverySetAnswerAnnouncements(false)
        nativeDiscoveryStop()
      } catch (_e) {
        threw = true
      }
      // 全流程不应抛异常
      expect(!threw).assertTrue()
      done()
    })
  })
}
