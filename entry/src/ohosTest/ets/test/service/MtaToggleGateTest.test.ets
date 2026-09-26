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
  getMtaReceiveSnapshot,
  isMtaSendActive
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

    // 并发发送记账成对归还：多次 suspend/resume 后发送占用必须归零，且不因重复 resume 变负
    it('send_active_count_pairs_on_suspend_and_resume', 0, async (done: Function) => {
      let origEnabled: boolean = getMtaEnabled()
      let origReceive: boolean = getMtaReceiveEnabled()
      try {
        // 接收开关关闭：suspend/resume 仅做记账与恢复判定，不触达蓝牙资源
        setMtaEnabled(true)
        setMtaReceiveEnabled(false)
        await suspendMtaReceiveForSend()
        await suspendMtaReceiveForSend()
        expect(isMtaSendActive()).assertTrue()
        await resumeMtaReceiveAfterSend()
        // 仍有并发发送未结束：占用保持
        expect(isMtaSendActive()).assertTrue()
        await resumeMtaReceiveAfterSend()
        expect(isMtaSendActive()).assertFalse()
        // 重复归还不产生负计数
        await resumeMtaReceiveAfterSend()
        expect(isMtaSendActive()).assertFalse()
        expect(getMtaReceiveSnapshot().serviceRunning).assertFalse()
      } finally {
        setMtaEnabled(origEnabled)
        setMtaReceiveEnabled(origReceive)
      }
      done()
    })
  })
}
