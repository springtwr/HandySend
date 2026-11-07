import { describe, it, expect } from '@ohos/hypium'
import { MainTabViewModel } from '../../../../main/ets/viewmodel/MainTabViewModel'
import { ensureReceiveSession } from '../../../../main/ets/service/transfer/adapters/LocalSendReceiveAdapter'
import { resetRegistry } from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  isSessionDetailOpen,
  markSessionDetailClosed,
  markSessionDetailOpen
} from '../../../../main/ets/utils/SessionDetailStack'

export default function MainTabPromptTest() {
  describe('MainTabPromptTest', () => {
    it('multiple_new_pending_queues_all', 0, () => {
      resetRegistry()
      let firstId: string = ensureReceiveSession('prompt-1', 'Sender A', '10.0.0.1', 'fp-a', 'mobile',
        'Model A', [{ fileId: 'f1', fileName: 'a', fileType: 'text/plain', totalBytes: 10 }], true, '')
      let secondId: string = ensureReceiveSession('prompt-2', 'Sender B', '10.0.0.2', 'fp-b', 'mobile',
        'Model B', [{ fileId: 'f2', fileName: 'b', fileType: 'text/plain', totalBytes: 20 }], true, '')
      let vm = new MainTabViewModel()
      vm.refreshBadges()
      expect(vm.pendingCount).assertEqual(2)
      // 同帧多条新请求全部入队，按到达顺序逐条打开
      expect(vm.autoOpenSessionIds.length).assertEqual(2)
      expect(vm.autoOpenSessionIds[0]).assertEqual(firstId)
      expect(vm.autoOpenSessionIds[1]).assertEqual(secondId)
      expect(vm.autoOpenSessionVersion).assertEqual(1)

      // 队列未消费时，后到请求追加到队尾而不是覆盖
      let thirdId: string = ensureReceiveSession('prompt-3', 'Sender C', '10.0.0.3', 'fp-c', 'mobile',
        'Model C', [{ fileId: 'f3', fileName: 'c', fileType: 'text/plain', totalBytes: 30 }], true, '')
      vm.refreshBadges()
      expect(vm.autoOpenSessionIds.length).assertEqual(3)
      expect(vm.autoOpenSessionIds[2]).assertEqual(thirdId)
      expect(vm.autoOpenSessionVersion).assertEqual(2)

      // 页面消费队列后，新到达的请求重新入队
      vm.autoOpenSessionIds = []
      let fourthId: string = ensureReceiveSession('prompt-4', 'Sender D', '10.0.0.4', 'fp-d', 'mobile',
        'Model D', [{ fileId: 'f4', fileName: 'd', fileType: 'text/plain', totalBytes: 40 }], true, '')
      vm.refreshBadges()
      expect(vm.autoOpenSessionIds.length).assertEqual(1)
      expect(vm.autoOpenSessionIds[0]).assertEqual(fourthId)
      expect(vm.autoOpenSessionVersion).assertEqual(3)

      resetRegistry()
    })

    it('session_detail_stack_tracks_layers', 0, () => {
      markSessionDetailOpen('detail-test')
      expect(isSessionDetailOpen('detail-test')).assertTrue()
      // 同一会话可有多层详情页：关掉一层仍视为打开
      markSessionDetailOpen('detail-test')
      markSessionDetailClosed('detail-test')
      expect(isSessionDetailOpen('detail-test')).assertTrue()
      markSessionDetailClosed('detail-test')
      expect(isSessionDetailOpen('detail-test')).assertFalse()
    })
  })
}
