// ReceiveInterruptedCleanupTest：接收会话中断（取消/失败）清理计划
// 回归场景：一部分文件已完成、其余失败或中途取消时，旧清理逻辑会删除该会话
// 全部预创建目标文件，把已接收完成的文件也一并清理。计划函数须按完成标记
// 只保留已完成文件，其余文件才进入清理范围。
import { describe, it, expect } from '@ohos/hypium'
import {
  planInterruptedReceiveCleanup, InterruptedReceiveCleanupPlan
} from '../../../../main/ets/service/repository/ReceiveRepository'
import { ReceivedFileEntry } from '../../../../main/ets/service/repository/ReceiveTargets'

function makeEntry(fileId: string): ReceivedFileEntry {
  let entry: ReceivedFileEntry = {
    sessionId: 'cleanup_s1',
    fileId: fileId,
    filePath: '/data/test/' + fileId,
    fileName: fileId,
    fileType: 'application/octet-stream'
  }
  return entry
}

export default function ReceiveInterruptedCleanupTest() {
  describe('ReceiveInterruptedCleanupTest', () => {
    it('partial_completed_files_are_kept', 0, () => {
      let entries: Array<ReceivedFileEntry> = [makeEntry('a'), makeEntry('b'), makeEntry('c')]
      let completed: Record<string, boolean> = {}
      completed['cleanup_s1:a'] = true
      completed['cleanup_s1:c'] = true

      let plan: InterruptedReceiveCleanupPlan =
        planInterruptedReceiveCleanup('cleanup_s1', entries, completed)

      // 已完成文件保留，未完成的 b 不在保留集合中
      expect(plan.keepFileIds['a']).assertTrue()
      expect(plan.keepFileIds['b'] === undefined).assertTrue()
      expect(plan.keepFileIds['c']).assertTrue()
      // 保留文件按原顺序进入历史记录
      expect(plan.completedEntries.length).assertEqual(2)
      expect(plan.completedEntries[0].fileId).assertEqual('a')
      expect(plan.completedEntries[1].fileId).assertEqual('c')
    })

    it('no_completed_files_keeps_nothing', 0, () => {
      let entries: Array<ReceivedFileEntry> = [makeEntry('a'), makeEntry('b')]
      let completed: Record<string, boolean> = {}

      let plan: InterruptedReceiveCleanupPlan =
        planInterruptedReceiveCleanup('cleanup_s1', entries, completed)

      expect(Object.keys(plan.keepFileIds).length).assertEqual(0)
      expect(plan.completedEntries.length).assertEqual(0)
    })

    it('all_completed_files_are_kept', 0, () => {
      let entries: Array<ReceivedFileEntry> = [makeEntry('a'), makeEntry('b')]
      let completed: Record<string, boolean> = {}
      completed['cleanup_s1:a'] = true
      completed['cleanup_s1:b'] = true

      let plan: InterruptedReceiveCleanupPlan =
        planInterruptedReceiveCleanup('cleanup_s1', entries, completed)

      expect(plan.keepFileIds['a']).assertTrue()
      expect(plan.keepFileIds['b']).assertTrue()
      expect(plan.completedEntries.length).assertEqual(2)
    })

    it('other_session_completion_does_not_leak', 0, () => {
      let entries: Array<ReceivedFileEntry> = [makeEntry('a')]
      let completed: Record<string, boolean> = {}
      // 同名 fileId 的完成标记属于其他会话，不得影响本会话的判定
      completed['cleanup_s2:a'] = true

      let plan: InterruptedReceiveCleanupPlan =
        planInterruptedReceiveCleanup('cleanup_s1', entries, completed)

      expect(plan.keepFileIds['a'] === undefined).assertTrue()
      expect(plan.completedEntries.length).assertEqual(0)
    })
  })
}
