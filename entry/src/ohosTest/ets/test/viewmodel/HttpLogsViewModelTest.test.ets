// HttpLogsViewModelTest：日志页视图模型实时刷新测试
// 覆盖节流合并、积压阈值立即刷新、增量追加保持稳定键、退订后不再追加、清空后继续追加。
import { describe, it, expect } from '@ohos/hypium'
import { addLog, clearLogs } from '../../../../main/ets/service/AppService'
import { HttpLogsViewModel } from '../../../../main/ets/viewmodel/HttpLogsViewModel'
import { sleep } from '../helper/TestHelper'

// 合并窗口为 500ms，此处等待略长于该值以确保窗口已结束
const WAIT_WINDOW_MS: number = 650;

export default function HttpLogsViewModelTest() {
  describe('HttpLogsViewModelTest', () => {
    it('loadLogs_loads_snapshot', 0, () => {
      clearLogs()
      addLog('info', 'a')
      addLog('info', 'b')
      let vm: HttpLogsViewModel = new HttpLogsViewModel()
      vm.loadLogs()
      expect(vm.logEntries.length).assertEqual(2)
    })

    it('subscribe_appends_new_logs_after_merge_window', 0, async (done: Function) => {
      clearLogs()
      let vm: HttpLogsViewModel = new HttpLogsViewModel()
      vm.loadLogs()
      vm.subscribeLogs()
      addLog('info', 'a')
      await sleep(WAIT_WINDOW_MS)
      expect(vm.logEntries.length).assertEqual(1)
      addLog('info', 'b')
      await sleep(WAIT_WINDOW_MS)
      expect(vm.logEntries.length).assertEqual(2)
      vm.unsubscribeLogs()
      done()
    })

    it('notifications_within_window_merge_into_single_refresh', 0, async (done: Function) => {
      clearLogs()
      let vm: HttpLogsViewModel = new HttpLogsViewModel()
      vm.loadLogs()
      vm.subscribeLogs()
      for (let i = 0; i < 5; i++) {
        addLog('info', 'm' + i)
      }
      // 合并窗口内不逐条刷新：此刻尚无条目上屏
      expect(vm.logEntries.length).assertEqual(0)
      await sleep(WAIT_WINDOW_MS)
      // 窗口结束后一次性刷新，5 条同时出现
      expect(vm.logEntries.length).assertEqual(5)
      vm.unsubscribeLogs()
      done()
    })

    it('backlog_threshold_flushes_immediately', 0, () => {
      clearLogs()
      let vm: HttpLogsViewModel = new HttpLogsViewModel()
      vm.loadLogs()
      vm.subscribeLogs()
      for (let i = 0; i < 100; i++) {
        addLog('info', 'm' + i)
      }
      // 达到积压阈值（100 条）立即刷新，无需等待合并窗口
      expect(vm.logEntries.length).assertEqual(100)
      vm.unsubscribeLogs()
    })

    it('incremental_append_keeps_existing_keys', 0, async (done: Function) => {
      clearLogs()
      addLog('info', 'a')
      let vm: HttpLogsViewModel = new HttpLogsViewModel()
      vm.loadLogs()
      vm.subscribeLogs()
      let firstKey: string = vm.keyFor(vm.logEntries[0], 0)
      addLog('info', 'b')
      await sleep(WAIT_WINDOW_MS)
      expect(vm.logEntries.length).assertEqual(2)
      // 尾部追加不改变既有条目的稳定键
      expect(vm.keyFor(vm.logEntries[0], 0)).assertEqual(firstKey)
      vm.unsubscribeLogs()
      done()
    })

    it('unsubscribe_stops_appending', 0, async (done: Function) => {
      clearLogs()
      let vm: HttpLogsViewModel = new HttpLogsViewModel()
      vm.loadLogs()
      vm.subscribeLogs()
      addLog('info', 'a')
      await sleep(WAIT_WINDOW_MS)
      expect(vm.logEntries.length).assertEqual(1)
      vm.unsubscribeLogs()
      addLog('info', 'b')
      await sleep(WAIT_WINDOW_MS)
      // 退订后不再追加
      expect(vm.logEntries.length).assertEqual(1)
      done()
    })

    it('clear_then_continue_appending', 0, async (done: Function) => {
      clearLogs()
      addLog('info', 'a')
      let vm: HttpLogsViewModel = new HttpLogsViewModel()
      vm.loadLogs()
      vm.subscribeLogs()
      vm.clearLogs()
      expect(vm.logEntries.length).assertEqual(0)
      // 清空后新日志继续实时追加（订阅未失效）
      addLog('info', 'b')
      await sleep(WAIT_WINDOW_MS)
      expect(vm.logEntries.length).assertEqual(1)
      vm.unsubscribeLogs()
      done()
    })
  })
}
