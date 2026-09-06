// SendProgress.test：发送进度条目清理语义单测
// 覆盖 upsertProgress/removeProgressForSession 的键匹配清理语义（FR-006 回归保护）。
// 注意：entry 模块 Local Test 依赖预览引擎，Linux 上不可执行；本文件仅保证编译正确性。
import { describe, it, expect } from '@ohos/hypium'
import {
  upsertProgress,
  removeProgressForSession,
  getActiveProgress,
  clearActiveProgress
} from '../main/ets/service/repository/SendRepository'
import { TransferProgress } from '../main/ets/model/Types'

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

    it('clearActiveProgress_cleanup_at_end', 0, () => {
      // 测试结束清理模块状态
      clearActiveProgress()
      let all: Array<TransferProgress> = getActiveProgress()
      expect(all.length).assertEqual(0)
    })
  })
}
