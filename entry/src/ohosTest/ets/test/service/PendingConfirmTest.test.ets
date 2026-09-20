import { describe, it, expect } from '@ohos/hypium'
import {
  SessionStage
} from '../../../../main/ets/model/transfer/TransferSession'
import {
  confirmSession,
  declineSession,
  getSession,
  resetRegistry,
  cancel,
  findByProtocol
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  ensureReceiveSession,
  finishLocalReceiveSession,
  setLocalReceiveInvokers
} from '../../../../main/ets/service/transfer/adapters/LocalSendReceiveAdapter'
import {
  beginWebDownloadBurst,
  markWebDownloadDeclined
} from '../../../../main/ets/service/transfer/adapters/WebDownloadAdapter'
import { handleMtaReceiveState } from '../../../../main/ets/service/transfer/adapters/MtaReceiveAdapter'
import { ReceiverStage, ReceiverState, ReceiveRequest } from '../../../../main/ets/model/mta/MtaProtocolModels'

let confirmedId: string = ''
let declinedId: string = ''
let cleanedId: string = ''

export default function PendingConfirmTest() {
  describe('PendingConfirmTest', () => {
    it('localsend_confirm_movesToActive', 0, () => {
      resetRegistry()
      confirmedId = ''
      declinedId = ''
      setLocalReceiveInvokers(
        (sid: string): void => {
          confirmedId = sid;
        },
        (sid: string): void => {
          declinedId = sid;
        },
        (sid: string): void => {
          cleanedId = sid;
        }
      )
      let id = ensureReceiveSession('ls-1', 'Sender', '10.0.0.1', 'fp', 'mobile', 'Model',
        [{ fileId: 'f1', fileName: 'a', fileType: 'text/plain', totalBytes: 10 }], true, '')
      let pending = getSession(id)
      expect(pending !== undefined).assertTrue()
      if (pending !== undefined) {
        expect(pending.stage).assertEqual(SessionStage.awaitingConfirmation)
      }
      confirmSession(id)
      expect(confirmedId).assertEqual('ls-1')
      let active = getSession(id)
      if (active !== undefined) {
        expect(active.stage).assertEqual(SessionStage.active)
      }
      resetRegistry()
    })

    it('localsend_decline_terminal', 0, () => {
      resetRegistry()
      declinedId = ''
      setLocalReceiveInvokers(
        (sid: string): void => {
          confirmedId = sid;
        },
        (sid: string): void => {
          declinedId = sid;
        },
        (sid: string): void => {
          cleanedId = sid;
        }
      )
      let id = ensureReceiveSession('ls-2', 'Sender', '10.0.0.1', 'fp', 'mobile', 'Model',
        [{ fileId: 'f1', fileName: 'a', fileType: 'text/plain', totalBytes: 10 }], true, '')
      declineSession(id)
      expect(declinedId).assertEqual('ls-2')
      let declined = getSession(id)
      if (declined !== undefined) {
        expect(declined.stage).assertEqual(SessionStage.declined)
      }
      resetRegistry()
    })

    it('localsend_withdrawBeforeConfirm_cancelled', 0, () => {
      resetRegistry()
      let id = ensureReceiveSession('ls-3', 'Sender', '10.0.0.1', 'fp', 'mobile', 'Model',
        [{ fileId: 'f1', fileName: 'a', fileType: 'text/plain', totalBytes: 10 }], true, '')
      // 发送方撤回：接收仓库收到取消事件后终结为已取消
      finishLocalReceiveSession('ls-3', SessionStage.cancelled)
      let cancelled = getSession(id)
      if (cancelled !== undefined) {
        expect(cancelled.stage).assertEqual(SessionStage.cancelled)
      }
      resetRegistry()
    })

    it('web_pendingThenDecline', 0, () => {
      resetRegistry()
      let id = beginWebDownloadBurst('10.0.0.9', true)
      let pending = getSession(id)
      expect(pending !== undefined).assertTrue()
      if (pending !== undefined) {
        expect(pending.stage).assertEqual(SessionStage.awaitingConfirmation)
      }
      markWebDownloadDeclined('10.0.0.9')
      let declined = getSession(id)
      if (declined !== undefined) {
        expect(declined.stage).assertEqual(SessionStage.declined)
      }
      resetRegistry()
    })

    it('web_pendingCancel_isIdempotent', 0, () => {
      resetRegistry()
      let id = beginWebDownloadBurst('10.0.0.10', true)
      // Web 下载不支持进行中取消：cancel 为空操作，待确认状态保持不变
      cancel(id)
      let still = getSession(id)
      if (still !== undefined) {
        expect(still.stage).assertEqual(SessionStage.awaitingConfirmation)
      }
      resetRegistry()
    })

    it('mta_requestThenDecline', 0, () => {
      resetRegistry()
      let state = new ReceiverState()
      state.stage = ReceiverStage.REQUEST_RECEIVED
      let request = new ReceiveRequest()
      request.senderName = 'MtaSender'
      request.fileName = 'a.bin'
      request.totalSize = 100
      state.receiveRequest = request
      handleMtaReceiveState(state)
      let pending = getSession(getMtaId())
      expect(pending !== undefined).assertTrue()
      if (pending !== undefined) {
        expect(pending.stage).assertEqual(SessionStage.awaitingConfirmation)
      }
      // 通过注册表分发拒绝（适配器经注入入口执行协议动作并进入终态）
      if (pending !== undefined) {
        declineSession(pending.id)
        let declined = getSession(pending.id)
        if (declined !== undefined) {
          expect(declined.stage).assertEqual(SessionStage.declined)
        }
      }
      resetRegistry()
    })
  })
}

// MTA 接收会话使用固定协议标识，测试辅助定位
function getMtaId(): string {
  let session = findByProtocol('mta-receive', 'mta-receive-session')
  // 返回统一会话标识；未找到时返回空串使查找失败
  return session !== undefined ? session.id : ''
}
