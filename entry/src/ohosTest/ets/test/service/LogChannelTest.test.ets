// LogChannelTest：AppCore 日志刷新通道测试
// 覆盖 addLog 通知订阅者、未订阅者不受影响、与全局变更总线隔离、裁剪行为不回归。
import { describe, it, expect, afterEach } from '@ohos/hypium'
import {
  addLog,
  clearLogs,
  getLogs,
  subscribeLogs,
  unsubscribeLogs,
  subscribe,
  unsubscribe
} from '../../../../main/ets/service/AppService'
import { LogEntry } from '../../../../main/ets/model/Types'

export default function LogChannelTest() {
  describe('LogChannelTest', () => {
    afterEach(() => {
      // 逐用例清空共享的内存日志缓冲，保证用例间互不干扰
      clearLogs()
    })

    it('addLog_notifies_subscribers', 0, () => {
      clearLogs()
      let count: number = 0
      let cb: () => void = () => {
        count++
      }
      subscribeLogs(cb)
      addLog('info', 'a')
      addLog('info', 'b')
      unsubscribeLogs(cb)
      expect(count).assertEqual(2)
    })

    it('unsubscribed_callback_not_notified', 0, () => {
      clearLogs()
      let subCount: number = 0
      let otherCount: number = 0
      let subCb: () => void = () => {
        subCount++
      }
      let otherCb: () => void = () => {
        otherCount++
      }
      subscribeLogs(subCb)
      addLog('info', 'a')
      unsubscribeLogs(subCb)
      addLog('info', 'b')
      // 退订后不再被调用，未订阅的回调始终不受影响
      expect(subCount).assertEqual(1)
      expect(otherCount).assertEqual(0)
    })

    it('addLog_does_not_notify_global_changeBus', 0, () => {
      clearLogs()
      let globalCount: number = 0
      let cb: () => void = () => {
        globalCount++
      }
      subscribe(cb)
      addLog('info', 'a')
      addLog('warn', 'b')
      unsubscribe(cb)
      // 日志写入只走日志刷新通道，不触发全局界面变更通知
      expect(globalCount).assertEqual(0)
    })

    it('addLog_writes_entry_content', 0, () => {
      clearLogs()
      addLog('warn', 'hello')
      let logs: Array<LogEntry> = getLogs()
      expect(logs.length).assertEqual(1)
      expect(logs[0].level).assertEqual('warn')
      expect(logs[0].message).assertEqual('hello')
    })

    it('trim_caps_buffer_to_1800', 0, () => {
      clearLogs()
      for (let i = 0; i < 2001; i++) {
        addLog('info', 'm' + i)
      }
      let logs: Array<LogEntry> = getLogs()
      // 超过上限 2000 时裁剪到最近 1800 条，保留最近条目
      expect(logs.length).assertEqual(1800)
      expect(logs[logs.length - 1].message).assertEqual('m2000')
    })
  })
}
