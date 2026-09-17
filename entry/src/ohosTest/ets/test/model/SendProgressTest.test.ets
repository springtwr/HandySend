// 发送进度条目清理语义单测
// 覆盖 upsertProgress/removeProgressForSession 的键匹配清理语义（回归保护）。
import { describe, it, expect } from '@ohos/hypium'
import {
  upsertProgress,
  removeProgressForSession,
  getActiveProgress,
  clearActiveProgress
} from '../../../../main/ets/service/repository/SendRepository'
import { TransferProgress } from '../../../../main/ets/model/Types'

export default function SendProgressTest() {
  describe('SendProgressTest', () => {
    it('clearActiveProgress_isolates_module_state', 0, () => {
      // 测试开头清理，隔离模块级 activeProgress 状态
      clearActiveProgress()
      let all: Array<TransferProgress> = getActiveProgress()
      expect(all.length).assertEqual(0)
    })

    it('removeProgressForSession_removes_only_target_session', 0, () => {
      clearActiveProgress()
      // 写入两个不同会话的进度条目
      upsertProgress({
        sessionId: 'session_A',
        fileId: 'file_1',
        bytesSent: 100,
        totalBytes: 200,
        filePath: '/tmp/a.bin'
      })
      upsertProgress({
        sessionId: 'session_B',
        fileId: 'file_1',
        bytesSent: 50,
        totalBytes: 200,
        filePath: '/tmp/b.bin'
      })
      // 移除会话 A 的条目：仅 A 消失、B 保留
      removeProgressForSession('session_A')
      let remaining: Array<TransferProgress> = getActiveProgress()
      expect(remaining.length).assertEqual(1)
      expect(remaining[0].sessionId).assertEqual('session_B')
    })

    it('removeProgressForSession_unknown_id_keeps_list', 0, () => {
      clearActiveProgress()
      upsertProgress({
        sessionId: 'session_A',
        fileId: 'file_1',
        bytesSent: 100,
        totalBytes: 200,
        filePath: '/tmp/a.bin'
      })
      // 移除不存在的会话 id：列表内容不变、无异常
      removeProgressForSession('not_exist')
      let remaining: Array<TransferProgress> = getActiveProgress()
      expect(remaining.length).assertEqual(1)
      expect(remaining[0].sessionId).assertEqual('session_A')
    })

    it('upsertProgress_same_session_and_file_replaces_entry', 0, () => {
      clearActiveProgress()
      upsertProgress({
        sessionId: 'session_A',
        fileId: 'file_1',
        bytesSent: 100,
        totalBytes: 200,
        filePath: '/tmp/a.bin'
      })
      // 同 sessionId + fileId 再次 upsert：原位替换而非追加
      upsertProgress({
        sessionId: 'session_A',
        fileId: 'file_1',
        bytesSent: 200,
        totalBytes: 200,
        filePath: '/tmp/a.bin'
      })
      let all: Array<TransferProgress> = getActiveProgress()
      expect(all.length).assertEqual(1)
      expect(all[0].bytesSent).assertEqual(200)

      // 同会话不同 fileId：独立条目，各自保留
      upsertProgress({
        sessionId: 'session_A',
        fileId: 'file_2',
        bytesSent: 50,
        totalBytes: 300,
        filePath: '/tmp/a2.bin'
      })
      let expanded: Array<TransferProgress> = getActiveProgress()
      expect(expanded.length).assertEqual(2)
      // 清理，避免影响后续用例
      clearActiveProgress()
    })

    it('clearActiveProgress_cleanup_at_end', 0, () => {
      // 测试结束清理模块状态
      clearActiveProgress()
      let all: Array<TransferProgress> = getActiveProgress()
      expect(all.length).assertEqual(0)
    })
  })
}
