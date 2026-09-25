// MtaToggleGateTest：MTA 总开关门禁测试
// 覆盖总开关关闭时 startMtaReceiveIfEnabled / resumeMtaReceiveAfterSend 不拉起接收。
// 断言口径：入口直接返回且接收服务运行态保持 false（不触达蓝牙资源）。
import { describe, it, expect, beforeAll } from '@ohos/hypium'
import {
  getMtaEnabled,
  setMtaEnabled,
  getMtaReceiveEnabled,
  setMtaReceiveEnabled
} from '../../../../main/ets/service/repository/SettingsRepository'
import {
  startMtaReceiveIfEnabled,
  suspendMtaReceiveForSend,
  resumeMtaReceiveAfterSend,
  getMtaReceiveSnapshot
} from '../../../../main/ets/service/repository/MtaRepository'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import { getTestAppContext } from '../helper/TestContext'

export default function MtaToggleGateTest() {
  describe('MtaToggleGateTest', () => {

    beforeAll(() => {
      // 初始化偏好存储（测试环境未走 App 主流程，preferences 未初始化）
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        initAllPreferences(ctx)
      }
    })

    // 总开关关闭：前台入口直接返回，接收服务保持停止
    it('startMtaReceiveIfEnabled_noop_when_mta_disabled', 0, () => {
      let origEnabled: boolean = getMtaEnabled()
      let origReceive: boolean = getMtaReceiveEnabled()
      try {
        setMtaEnabled(false)
        setMtaReceiveEnabled(true)
        let ctx = getTestAppContext()
        if (ctx !== undefined) {
          startMtaReceiveIfEnabled(ctx)
        }
        expect(getMtaReceiveSnapshot().serviceRunning).assertFalse()
      } finally {
        // 恢复原开关状态
        setMtaEnabled(origEnabled)
        setMtaReceiveEnabled(origReceive)
      }
    })

    // 总开关关闭：收发互斥的发送结束恢复路径不拉起接收
    it('resumeMtaReceiveAfterSend_noop_when_mta_disabled', 0, async (done: Function) => {
      let origEnabled: boolean = getMtaEnabled()
      let origReceive: boolean = getMtaReceiveEnabled()
      try {
        setMtaEnabled(false)
        setMtaReceiveEnabled(true)
        await suspendMtaReceiveForSend()
        await resumeMtaReceiveAfterSend()
        expect(getMtaReceiveSnapshot().serviceRunning).assertFalse()
      } finally {
        // 恢复原开关状态
        setMtaEnabled(origEnabled)
        setMtaReceiveEnabled(origReceive)
      }
      done()
    })
  })
}
