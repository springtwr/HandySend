import { describe, it, expect } from '@ohos/hypium'
import { DiscoveredDevice } from '../../../../main/ets/model/Types'
import {
  SessionDataFlow,
  SessionEventKind,
  SessionInitiator,
  SessionStage
} from '../../../../main/ets/model/transfer/TransferSession'
import {
  beginLocalSendSession,
  updateLocalSendProgress,
  finishLocalSend
} from '../../../../main/ets/service/transfer/adapters/LocalSendSendAdapter'
import {
  LOCAL_RECEIVE_KEY,
  ensureReceiveSession,
  finishLocalReceiveSession,
  markReceiveActive,
  updateReceiveProgress
} from '../../../../main/ets/service/transfer/adapters/LocalSendReceiveAdapter'
import { getAdapter } from '../../../../main/ets/service/transfer/adapters/SessionAdapter'
import {
  MtaSendTerminal,
  beginMtaSendSession,
  finishMtaSendSession,
  updateMtaSendProgress
} from '../../../../main/ets/service/transfer/adapters/MtaSendAdapter'
import { handleMtaReceiveState } from '../../../../main/ets/service/transfer/adapters/MtaReceiveAdapter'
import {
  beginWebDownloadBurst,
  handleWebFileDownload,
  handleWebDownloadProgress,
  markWebDownloadAccepted,
  markWebDownloadDeclined
} from '../../../../main/ets/service/transfer/adapters/WebDownloadAdapter'
import { ReceiverStage, ReceiverState, ReceiveRequest } from '../../../../main/ets/model/mta/MtaProtocolModels'
import {
  getSession,
  findByProtocol,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import { liveSessionRow } from '../../../../main/ets/viewmodel/TransferCenterViewModel'

function device(): DiscoveredDevice {
  return {
    alias: 'Peer',
    ip: '192.168.1.9',
    port: 53317,
    fingerprint: 'fp',
    version: '2.1',
    deviceModel: 'Model',
    deviceType: 'mobile',
    protocol: 'http',
    lastSeen: 0,
    channels: []
  }
}

export default function AdaptersTest() {
  describe('AdaptersTest', () => {
    it('localsendSend_eventTranslation', 0, () => {
      resetRegistry()
      let id = beginLocalSendSession('single_1', device(), [
        { fileId: 'f1', filePath: '/a', fileName: 'a', fileType: 'text/plain', size: 100 }
      ])
      let s = getSession(id)
      expect(s !== undefined).assertTrue()
      if (s !== undefined) {
        expect(s.dataFlow).assertEqual(SessionDataFlow.outbound)
        expect(s.initiatedBy).assertEqual(SessionInitiator.local)
        expect(s.stage).assertEqual(SessionStage.active)
        expect(s.totalBytes).assertEqual(100)
      }
      updateLocalSendProgress(id, 'f1', 40, 100)
      let mid = getSession(id)
      if (mid !== undefined) {
        expect(mid.bytesSent).assertEqual(40)
      }
      finishLocalSend(id, true)
      let done = getSession(id)
      if (done !== undefined) {
        expect(done.stage).assertEqual(SessionStage.succeeded)
      }
      resetRegistry()
    })

    it('localsendSend_textMessage_noByteProgress', 0, () => {
      resetRegistry()
      // 单条文本消息走「仅预览送达」路径：接收端不上传文件、无字节进度事件，
      // 故该会话不声明字节进度，行模型据此不产生百分比进度渲染
      let textId = beginLocalSendSession('text_1', device(), [
        { fileId: 'f1', filePath: '/a.txt', fileName: 'a.txt', fileType: 'text/plain', size: 5, preview: '你好' }
      ])
      let textSession = getSession(textId)
      expect(textSession !== undefined).assertTrue()
      if (textSession !== undefined) {
        expect(textSession.capabilities.hasByteProgress).assertFalse()
        expect(liveSessionRow(textSession).hasByteProgress).assertFalse()
      }
      // 普通文件发送（不承载文本内容）保持字节进度
      let fileId = beginLocalSendSession('file_1', device(), [
        { fileId: 'f2', filePath: '/b.bin', fileName: 'b.bin', fileType: 'application/octet-stream', size: 100 }
      ])
      let fileSession = getSession(fileId)
      expect(fileSession !== undefined).assertTrue()
      if (fileSession !== undefined) {
        expect(fileSession.capabilities.hasByteProgress).assertTrue()
        expect(liveSessionRow(fileSession).hasByteProgress).assertTrue()
      }
      resetRegistry()
    })

    it('localsendReceive_pendingThenActive', 0, () => {
      resetRegistry()
      let id = ensureReceiveSession('sess-1', 'Sender', '10.0.0.2', 'fp', 'mobile', 'Model',
        [{ fileId: 'f1', fileName: 'a', fileType: 'text/plain', totalBytes: 50 }], true, '')
      let s = getSession(id)
      expect(s !== undefined).assertTrue()
      if (s !== undefined) {
        expect(s.stage).assertEqual(SessionStage.awaitingConfirmation)
        expect(s.dataFlow).assertEqual(SessionDataFlow.inbound)
        expect(s.initiatedBy).assertEqual(SessionInitiator.remote)
      }
      // 幂等：同协议标识复用同一会话
      let again = ensureReceiveSession('sess-1', 'Sender', '10.0.0.2', 'fp', 'mobile', 'Model', [], true, '')
      expect(again).assertEqual(id)
      markReceiveActive('sess-1')
      updateReceiveProgress('sess-1', 'f1', 25, 50)
      let active = getSession(id)
      if (active !== undefined) {
        expect(active.stage).assertEqual(SessionStage.active)
        expect(active.bytesSent).assertEqual(25)
      }
      finishLocalReceiveSession('sess-1', SessionStage.succeeded)
      let done = getSession(id)
      if (done !== undefined) {
        expect(done.stage).assertEqual(SessionStage.succeeded)
      }
      resetRegistry()
    })

    it('localsendReceive_textPreview', 0, () => {
      resetRegistry()
      // 文本消息：摄入时携带的文本内容进入展示描述符（详情页文本预览插槽）
      let id = ensureReceiveSession('sess-txt', 'Sender', '10.0.0.2', 'fp', 'mobile', 'Model',
        [{ fileId: 'f1', fileName: 'message.txt', fileType: 'text/plain', totalBytes: 5 }], true, '你好')
      let adapter = getAdapter(LOCAL_RECEIVE_KEY)
      expect(adapter !== undefined).assertTrue()
      if (adapter !== undefined) {
        let display = adapter.getDisplayDescriptor(id)
        expect(display.supportsTextPreview).assertTrue()
        expect(display.textPreview).assertEqual('你好')
      }
      // 无文本内容的普通文件：不产生文本预览
      let plainId = ensureReceiveSession('sess-bin', 'Sender', '10.0.0.3', 'fp', 'mobile', 'Model',
        [{ fileId: 'f1', fileName: 'a.bin', fileType: '', totalBytes: 8 }], true, '')
      if (adapter !== undefined) {
        let plain = adapter.getDisplayDescriptor(plainId)
        expect(plain.supportsTextPreview).assertFalse()
      }
      resetRegistry()
    })

    it('mtaSend_stageAndTerminal', 0, () => {
      resetRegistry()
      let id = beginMtaSendSession('task-1', 'MtaPeer', 'mobile', 'Model', 'Brand',
        [{ fileId: 'f1', fileName: 'a', fileType: '', totalBytes: 200 }])
      let s = getSession(id)
      expect(s !== undefined).assertTrue()
      if (s !== undefined) {
        expect(s.protocolKey).assertEqual('mta-send')
      }
      updateMtaSendProgress(id, 120, 200, '接收中')
      let mid = getSession(id)
      if (mid !== undefined) {
        expect(mid.bytesSent).assertEqual(120)
        expect(mid.stageText).assertEqual('接收中')
      }
      finishMtaSendSession(id, MtaSendTerminal.partial, '')
      let done = getSession(id)
      if (done !== undefined) {
        expect(done.stage).assertEqual(SessionStage.partiallyFailed)
      }
      resetRegistry()
    })

    it('mtaReceive_requestThenCompleted', 0, () => {
      resetRegistry()
      let state = new ReceiverState()
      state.stage = ReceiverStage.REQUEST_RECEIVED
      let request = new ReceiveRequest()
      request.senderName = 'MtaSender'
      request.fileName = 'a.bin'
      request.totalSize = 300
      state.receiveRequest = request
      handleMtaReceiveState(state)
      let found = findByProtocol('mta-receive', 'mta-receive-session')
      expect(found !== undefined).assertTrue()
      if (found !== undefined) {
        expect(found.stage).assertEqual(SessionStage.awaitingConfirmation)
        expect(found.peer.displayName).assertEqual('MtaSender')
      }
      state.stage = ReceiverStage.DOWNLOADING
      state.progress.receivedBytes = 150
      handleMtaReceiveState(state)
      let downloading = findByProtocol('mta-receive', 'mta-receive-session')
      if (downloading !== undefined) {
        expect(downloading.stage).assertEqual(SessionStage.active)
        expect(downloading.bytesSent).assertEqual(150)
      }
      state.stage = ReceiverStage.COMPLETED
      handleMtaReceiveState(state)
      let completed = findByProtocol('mta-receive', 'mta-receive-session')
      if (completed !== undefined) {
        expect(completed.stage).assertEqual(SessionStage.succeeded)
      }
      resetRegistry()
    })

    it('webDownload_burstPendingThenDecline', 0, () => {
      resetRegistry()
      let id = beginWebDownloadBurst('192.168.1.50', true)
      let s = getSession(id)
      expect(s !== undefined).assertTrue()
      if (s !== undefined) {
        expect(s.stage).assertEqual(SessionStage.awaitingConfirmation)
        expect(s.dataFlow).assertEqual(SessionDataFlow.outbound)
        expect(s.initiatedBy).assertEqual(SessionInitiator.remote)
        // 匿名对端：仅有 IP 的展示描述符兜底
        expect(s.peer.anonymous).assertTrue()
      }
      // 同 IP 再次请求复用同一突发会话
      let again = beginWebDownloadBurst('192.168.1.50', true)
      expect(again).assertEqual(id)
      handleWebFileDownload('192.168.1.50', 'f1', 100)
      handleWebDownloadProgress('192.168.1.50', 'f1', 100, 100)
      let mid = getSession(id)
      if (mid !== undefined) {
        expect(mid.files.length).assertEqual(1)
        expect(mid.bytesSent).assertEqual(100)
      }
      markWebDownloadDeclined('192.168.1.50')
      let declined = getSession(id)
      if (declined !== undefined) {
        expect(declined.stage).assertEqual(SessionStage.declined)
      }
      resetRegistry()
    })

    it('webDownload_acceptAdvancesViaRegistry', 0, () => {
      resetRegistry()
      let id = beginWebDownloadBurst('192.168.1.51', true)
      let pending = getSession(id)
      if (pending !== undefined) {
        expect(pending.stage).assertEqual(SessionStage.awaitingConfirmation)
      }
      // 接受经注册表推进：状态转进行中并补记 confirmed / started 时间线
      markWebDownloadAccepted('192.168.1.51')
      let accepted = getSession(id)
      if (accepted !== undefined) {
        expect(accepted.stage).assertEqual(SessionStage.active)
        let confirmed = 0
        let started = 0
        for (let i = 0; i < accepted.timeline.length; i++) {
          if (accepted.timeline[i].kind === SessionEventKind.confirmed) {
            confirmed++
          }
          if (accepted.timeline[i].kind === SessionEventKind.started) {
            started++
          }
        }
        expect(confirmed).assertEqual(1)
        expect(started).assertEqual(1)
      }
      // 幂等：重复接受不重复推进、不重复补记时间线
      markWebDownloadAccepted('192.168.1.51')
      let again = getSession(id)
      if (again !== undefined) {
        expect(again.stage).assertEqual(SessionStage.active)
        let confirmedAgain = 0
        for (let i = 0; i < again.timeline.length; i++) {
          if (again.timeline[i].kind === SessionEventKind.confirmed) {
            confirmedAgain++
          }
        }
        expect(confirmedAgain).assertEqual(1)
      }
      resetRegistry()
    })
  })
}
