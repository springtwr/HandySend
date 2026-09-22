import { describe, it, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import { DiscoveredDevice, MediaFileInfo, SendFileItem } from '../../../../main/ets/model/Types'
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
  MtaSendEventDecision,
  MtaSendTerminal,
  beginMtaSendSession,
  decideMtaSendEvent,
  finishMtaSendSession,
  updateMtaSendProgress
} from '../../../../main/ets/service/transfer/adapters/MtaSendAdapter'
import { MtaSenderStage } from '../../../../main/ets/model/mta/MtaSendModels'
import { decidePeerGroupAbandon } from '../../../../main/ets/service/mta/MtaSendService'
import { MtaConstants } from '../../../../main/ets/service/mta/MtaConstants'
import {
  MTA_PEER_ACCEPT_WINDOW_MS,
  MTA_PENDING_TIMEOUT_MS,
  MTA_RECEIVE_KEY,
  expirePendingConfirm,
  handleMtaReceiveState,
  notifyMtaTextSaved,
  setMtaReceiveInvokers
} from '../../../../main/ets/service/transfer/adapters/MtaReceiveAdapter'
import {
  WEB_DOWNLOAD_KEY,
  beginWebDownloadBurst,
  handleWebFileDownload,
  handleWebDownloadProgress,
  markWebDownloadAccepted,
  markWebDownloadDeclined
} from '../../../../main/ets/service/transfer/adapters/WebDownloadAdapter'
import { ReceiverStage, ReceiverState, ReceiveRequest } from '../../../../main/ets/model/mta/MtaProtocolModels'
import {
  getHistory,
  getSession,
  findByProtocol,
  finish,
  confirmSession,
  declineSession,
  querySessions,
  resetRegistry,
  updateSessionFilePath
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import { uniquePath } from '../../../../main/ets/service/repository/ReceiveTargets'
import { isTextFile } from '../../../../main/ets/utils/MimeUtils'
import { getTestAppContext } from '../helper/TestContext'
import { clearSessionHistory, resetSessionHistoryCache } from '../../../../main/ets/service/transfer/SessionHistoryStore'
import { createSendSession } from '../../../../main/ets/service/repository/SendRepository'
import { liveSessionRow, rowHasByteProgress } from '../../../../main/ets/viewmodel/TransferCenterViewModel'

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

/** 构造一条"文本消息接收请求已到达"的接收状态（供文本接受路径用例复用）。 */
function textReceiveState(senderName: string, text: string): ReceiverState {
  let state = new ReceiverState()
  state.stage = ReceiverStage.REQUEST_RECEIVED
  let request = new ReceiveRequest()
  request.senderName = senderName
  request.fileName = 'message.txt'
  request.totalSize = 5
  request.textContent = text
  state.receiveRequest = request
  return state
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
        expect(rowHasByteProgress(liveSessionRow(textSession))).assertFalse()
      }
      // 普通文件发送（不承载文本内容）保持字节进度
      let fileId = beginLocalSendSession('file_1', device(), [
        { fileId: 'f2', filePath: '/b.bin', fileName: 'b.bin', fileType: 'application/octet-stream', size: 100 }
      ])
      let fileSession = getSession(fileId)
      expect(fileSession !== undefined).assertTrue()
      if (fileSession !== undefined) {
        expect(fileSession.capabilities.hasByteProgress).assertTrue()
        expect(rowHasByteProgress(liveSessionRow(fileSession))).assertTrue()
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

    it('localsendReceive_webOriginShowsIpOnly', 0, () => {
      resetRegistry()
      // 网页来源（浏览器上传）：对端名称取客户端 IP、清空型号徽标，副标题不重复 IP
      let webId = ensureReceiveSession('sess-web', 'Web Browser', '10.0.0.7', 'fp', 'web', 'Chrome',
        [{ fileId: 'f1', fileName: 'a.bin', fileType: '', totalBytes: 10 }], true, '')
      let adapter = getAdapter(LOCAL_RECEIVE_KEY)
      expect(adapter !== undefined).assertTrue()
      if (adapter !== undefined) {
        let display = adapter.getDisplayDescriptor(webId)
        expect(display.peerTitle).assertEqual('10.0.0.7')
        expect(display.peerSubtitle).assertEqual('')
        expect(display.badges.length).assertEqual(0)
      }
      let webSession = getSession(webId)
      expect(webSession !== undefined).assertTrue()
      if (webSession !== undefined) {
        expect(webSession.peer.displayName).assertEqual('10.0.0.7')
        expect(webSession.peer.deviceType).assertEqual('web')
      }
      // 普通设备来源：保留真实别名与型号徽标，副标题保留 IP
      let normalId = ensureReceiveSession('sess-normal', 'Alice Phone', '10.0.0.8', 'fp', 'mobile',
        'Mate 60', [{ fileId: 'f1', fileName: 'a.bin', fileType: '', totalBytes: 10 }], true, '')
      if (adapter !== undefined) {
        let normal = adapter.getDisplayDescriptor(normalId)
        expect(normal.peerTitle).assertEqual('Alice Phone')
        expect(normal.peerSubtitle).assertEqual('10.0.0.8')
        expect(normal.badges.length).assertEqual(1)
      }
      resetRegistry()
    })

    it('localsendReceive_webOriginAcceptDecline', 0, () => {
      resetRegistry()
      // 待确认入站会话经接受后进入进行中（与任务中心同一事实源）
      let acceptId = ensureReceiveSession('sess-web-acc', 'Web Browser', '10.0.0.11', 'fp', 'web',
        'Chrome', [{ fileId: 'f1', fileName: 'a.bin', fileType: '', totalBytes: 10 }], true, '')
      confirmSession(acceptId)
      let active = getSession(acceptId)
      expect(active !== undefined).assertTrue()
      if (active !== undefined) {
        expect(active.stage).assertEqual(SessionStage.active)
      }
      // 待确认入站会话经拒绝后按拒绝终结
      let declineId = ensureReceiveSession('sess-web-dec', 'Web Browser', '10.0.0.12', 'fp', 'web',
        'Chrome', [{ fileId: 'f1', fileName: 'a.bin', fileType: '', totalBytes: 10 }], true, '')
      declineSession(declineId)
      let declined = getSession(declineId)
      expect(declined !== undefined).assertTrue()
      if (declined !== undefined) {
        expect(declined.stage).assertEqual(SessionStage.declined)
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

    it('mtaSend_multiFileProgressCursorSplit', 0, () => {
      resetRegistry()
      // 多文件顺序流：累计字节按各文件 totalBytes 游标拆分，不再全记到 files[0]
      let id = beginMtaSendSession('task-m', 'MtaPeer', 'mobile', 'Model', 'Brand',
        [{ fileId: 'f1', fileName: 'a', fileType: '', totalBytes: 100 },
          { fileId: 'f2', fileName: 'b', fileType: '', totalBytes: 150 }])
      updateMtaSendProgress(id, 120, 250, '发送中')
      let s = getSession(id)
      expect(s !== undefined).assertTrue()
      if (s !== undefined) {
        expect(s.bytesSent).assertEqual(120)
        expect(s.files.length).assertEqual(2)
        expect(s.files[0].bytesSent).assertEqual(100)
        expect(s.files[1].bytesSent).assertEqual(20)
      }
      // 累计越过全部文件：各文件均封顶，不产生超额
      updateMtaSendProgress(id, 260, 250, '发送中')
      let s2 = getSession(id)
      if (s2 !== undefined) {
        expect(s2.files[0].bytesSent).assertEqual(100)
        expect(s2.files[1].bytesSent).assertEqual(150)
      }
      resetRegistry()
    })

    it('mtaSend_sessionPerRequest_sameDeviceIndependent', 0, () => {
      resetRegistry()
      // 同一设备先后两次发送：各自使用本次请求信息创建独立会话，互不合并（FR-003）
      let first = beginMtaSendSession('task-a', '同一设备', 'mobile', 'Model', 'Brand',
        [{ fileId: 'f1', fileName: 'a.txt', fileType: 'text/plain', totalBytes: 10 }])
      let second = beginMtaSendSession('task-b', '同一设备', 'mobile', 'Model', 'Brand',
        [{ fileId: 'f2', fileName: 'b.txt', fileType: 'text/plain', totalBytes: 20 }])
      expect(first === second).assertFalse()
      let s1 = getSession(first)
      let s2 = getSession(second)
      expect(s1 !== undefined).assertTrue()
      expect(s2 !== undefined).assertTrue()
      if (s1 !== undefined && s2 !== undefined) {
        expect(s1.protocolSessionId).assertEqual('task-a')
        expect(s2.protocolSessionId).assertEqual('task-b')
        expect(s1.totalBytes).assertEqual(10)
        expect(s2.totalBytes).assertEqual(20)
        expect(s1.files[0].fileName).assertEqual('a.txt')
        expect(s2.files[0].fileName).assertEqual('b.txt')
        // 两条会话各自独立成行、互不覆盖（FR-008）
        expect(liveSessionRow(s1).key === liveSessionRow(s2).key).assertFalse()
      }
      // 文本发送（无文件条目）仍产生可展示会话，且结果归属本次请求
      let textId = beginMtaSendSession('task-text', '同一设备', 'mobile', 'Model', 'Brand', [])
      let textSession = getSession(textId)
      expect(textSession !== undefined).assertTrue()
      if (textSession !== undefined) {
        expect(textSession.files.length).assertEqual(0)
        expect(liveSessionRow(textSession).sessionId).assertEqual(textId)
      }
      // 独立终结：终态只落在被终结的那条会话，另一条不受影响
      finishMtaSendSession(first, MtaSendTerminal.failed, '模拟失败', 'failed')
      let doneFirst = getSession(first)
      let stillSecond = getSession(second)
      if (doneFirst !== undefined && stillSecond !== undefined) {
        expect(doneFirst.stage).assertEqual(SessionStage.failed)
        expect(stillSecond.stage).assertEqual(SessionStage.active)
      }
      resetRegistry()
    })

    it('mtaPeerFingerprint_andBrand_passthrough', 0, () => {
      // MTA 发送：对端 BLE 地址复用 fingerprint 字段、品牌标识透传至会话与展示描述符
      resetRegistry()
      let sendId = beginMtaSendSession('task-id', 'MtaPeer', 'mobile', 'Model', 'Brand',
        [{ fileId: 'f1', fileName: 'a', fileType: '', totalBytes: 10 }], 30, 'AA:BB:CC:DD:EE:FF')
      let sendSession = getSession(sendId)
      expect(sendSession !== undefined).assertTrue()
      if (sendSession !== undefined) {
        expect(sendSession.peer.fingerprint).assertEqual('AA:BB:CC:DD:EE:FF')
        expect(sendSession.peer.mtaBrandId).assertEqual(30)
      }
      let sendAdapter = getAdapter('mta-send')
      expect(sendAdapter !== undefined).assertTrue()
      if (sendAdapter !== undefined) {
        expect(sendAdapter.getDisplayDescriptor(sendId).mtaBrandId).assertEqual(30)
      }
      resetRegistry()

      // MTA 接收：对端标识优先已连接 GATT 的对端标识；品牌恒为未知（-1）
      let state = new ReceiverState()
      state.stage = ReceiverStage.REQUEST_RECEIVED
      state.connectedPeerId = '11:22:33:44:55:66'
      let request = new ReceiveRequest()
      request.senderName = 'MtaSender'
      request.senderId = 'sender-hex'
      request.fileName = 'a.bin'
      request.totalSize = 100
      state.receiveRequest = request
      handleMtaReceiveState(state)
      let recv = findByProtocol(MTA_RECEIVE_KEY, 'mta-receive-session')
      expect(recv !== undefined).assertTrue()
      if (recv !== undefined) {
        expect(recv.peer.fingerprint).assertEqual('11:22:33:44:55:66')
        expect(recv.peer.mtaBrandId).assertEqual(-1)
      }
      let recvAdapter = getAdapter(MTA_RECEIVE_KEY)
      if (recvAdapter !== undefined && recv !== undefined) {
        expect(recvAdapter.getDisplayDescriptor(recv.id).mtaBrandId).assertEqual(-1)
      }
      resetRegistry()

      // MTA 接收：已连接标识为空时回退接收请求携带的发送方 ID
      let fallbackState = new ReceiverState()
      fallbackState.stage = ReceiverStage.REQUEST_RECEIVED
      let fallbackRequest = new ReceiveRequest()
      fallbackRequest.senderName = 'MtaSender2'
      fallbackRequest.senderId = 'sender-fallback'
      fallbackRequest.fileName = 'b.bin'
      fallbackRequest.totalSize = 50
      fallbackState.receiveRequest = fallbackRequest
      handleMtaReceiveState(fallbackState)
      let fallback = findByProtocol(MTA_RECEIVE_KEY, 'mta-receive-session')
      expect(fallback !== undefined).assertTrue()
      if (fallback !== undefined) {
        expect(fallback.peer.fingerprint).assertEqual('sender-fallback')
      }
      resetRegistry()
    })

    it('resend_sameDevice_localSend_replacesTerminal_andKeepsHistory', 0, () => {
      resetRegistry()
      // 显式清空历史，排除其它套件残留，使「被取代的历史仍可查」断言可确定
      clearSessionHistory()
      let files: Array<SendFileItem> = [
        { fileId: 'f1', filePath: '/a', fileName: 'a', fileType: 'text/plain', size: 10 }
      ]
      // 第一次发送并成功（暂存列表保持不变）
      createSendSession('s1', '10.0.0.1', 'Peer', files)
      // 局域网发送创建时协议会话 ID 尚不可知：该字段为空，不承载内部业务编号，故按协议键定位会话
      let firstList = querySessions({ protocolKey: 'localsend-send' })
      expect(firstList.length).assertEqual(1)
      if (firstList.length > 0) {
        expect(firstList[0].protocolSessionId).assertEqual('')
      }
      let firstId: string = firstList.length > 0 ? firstList[0].id : ''
      finishLocalSend(firstId, true)
      expect(getHistory().length > 0).assertTrue()
      // 再次向同一设备发送：新会话创建之前取代该对端上一条已终态可见条目
      createSendSession('s2', '10.0.0.1', 'Peer', files)
      let secondList = querySessions({ protocolKey: 'localsend-send' })
      expect(secondList.length).assertEqual(1)
      let secondId: string = secondList.length > 0 ? secondList[0].id : ''
      // 每次发送各成一条会话：标识唯一、互不覆盖
      expect(secondId === firstId).assertFalse()
      // 上一条已终态条目被移除，本次会话仍在
      expect(getSession(firstId) === undefined).assertTrue()
      expect(getSession(secondId) !== undefined).assertTrue()
      // 被取代的历史记录仍可查（移除的是可见条目，不是传输记录）
      let entries = getHistory()
      let kept: boolean = false
      for (let i = 0; i < entries.length; i++) {
        if (entries[i].sessionId === firstId) {
          kept = true
        }
      }
      expect(kept).assertTrue()
      resetRegistry()
      clearSessionHistory()
    })

    it('resend_sameMtaPeer_replacesTerminalEntry', 0, () => {
      resetRegistry()
      // 互传发送：同一设备先后两次，第二次创建前按昵称取代上一条已终态条目
      let first = beginMtaSendSession('task-a', '同一设备', 'mobile', 'Model', 'Brand', [])
      finishMtaSendSession(first, MtaSendTerminal.success)
      let second = beginMtaSendSession('task-b', '同一设备', 'mobile', 'Model', 'Brand', [])
      expect(second === first).assertFalse()
      expect(getSession(first) === undefined).assertTrue()
      expect(getSession(second) !== undefined).assertTrue()
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
      }
      // 同 IP 再次请求复用同一突发会话
      let again = beginWebDownloadBurst('192.168.1.50', true)
      expect(again).assertEqual(id)
      handleWebFileDownload('192.168.1.50', 'f1', 'report.pdf', 100)
      handleWebDownloadProgress('192.168.1.50', 'f1', 100, 100)
      let mid = getSession(id)
      if (mid !== undefined) {
        expect(mid.files.length).assertEqual(1)
        expect(mid.files[0].fileName).assertEqual('report.pdf')
        expect(mid.bytesSent).assertEqual(100)
      }
      // 对端条目只显示纯 IP：标题为 IP、副标题为空（网页来源由来源徽标表达）
      let adapter = getAdapter(WEB_DOWNLOAD_KEY)
      expect(adapter !== undefined).assertTrue()
      if (adapter !== undefined) {
        let display = adapter.getDisplayDescriptor(id)
        expect(display.peerTitle).assertEqual('192.168.1.50')
        expect(display.peerSubtitle).assertEqual('')
      }
      markWebDownloadDeclined('192.168.1.50')
      let declined = getSession(id)
      if (declined !== undefined) {
        expect(declined.stage).assertEqual(SessionStage.declined)
      }
      resetRegistry()
    })

    it('webDownload_partiallyFailedNotReused', 0, () => {
      resetRegistry()
      // 部分失败属终态：同 IP 新请求须新建突发，不得复用旧会话
      let id = beginWebDownloadBurst('192.168.1.60', true)
      markWebDownloadAccepted('192.168.1.60')
      finish(id, SessionStage.partiallyFailed, '')
      let next = beginWebDownloadBurst('192.168.1.60', true)
      expect(next === id).assertFalse()
      let s = getSession(next)
      if (s !== undefined) {
        expect(s.stage).assertEqual(SessionStage.awaitingConfirmation)
      }
      resetRegistry()
    })

    it('mtaReceive_pendingTimeoutThresholdAndTerminal', 0, () => {
      resetRegistry()
      // 待确认超时必须严格大于对端接受窗口（35 秒），避免抢在对端仍等待时误终结
      expect(MTA_PEER_ACCEPT_WINDOW_MS).assertEqual(35000)
      expect(MTA_PENDING_TIMEOUT_MS > MTA_PEER_ACCEPT_WINDOW_MS).assertTrue()

      let rejected = false
      setMtaReceiveInvokers(
        (): void => {
        },
        (): void => {
          rejected = true;
        },
        (): void => {
        },
        (): void => {
        },
        (): Array<MediaFileInfo> => []
      )

      let state = new ReceiverState()
      state.stage = ReceiverStage.REQUEST_RECEIVED
      let request = new ReceiveRequest()
      request.senderName = 'MtaSender'
      request.fileName = 'a.bin'
      request.totalSize = 100
      state.receiveRequest = request
      handleMtaReceiveState(state)

      let pending = findByProtocol('mta-receive', 'mta-receive-session')
      expect(pending !== undefined).assertTrue()
      if (pending !== undefined) {
        expect(pending.stage).assertEqual(SessionStage.awaitingConfirmation)
        // 超时终结：按已取消终结统一会话，并复用拒绝入口释放接收侧资源
        expirePendingConfirm(pending.id)
        let expired = getSession(pending.id)
        expect(expired !== undefined).assertTrue()
        if (expired !== undefined) {
          expect(expired.stage).assertEqual(SessionStage.cancelled)
        }
        expect(rejected).assertTrue()
      }
      resetRegistry()
    })

    it('mtaSend_waitingPeerConfirmWindowAndNonTerminal', 0, () => {
      // 等待对端开始接收窗口契约不变：仍为 35000ms，且接收侧待确认超时严格大于该窗口
      expect(MTA_PEER_ACCEPT_WINDOW_MS).assertEqual(35000)
      expect(MTA_PENDING_TIMEOUT_MS > MTA_PEER_ACCEPT_WINDOW_MS).assertTrue()

      // 等待确认阶段属非终态：有活跃会话时推进（不终结）
      let advance = decideMtaSendEvent(1, 1, true, false, MtaSenderStage.WAITING_PEER_CONFIRM)
      expect(advance.terminal).assertFalse()
      expect(advance.decision).assertEqual(MtaSendEventDecision.advance)

      // 无活跃会话时创建会话并推进；终态事件才不会诞生会话
      let create = decideMtaSendEvent(1, 1, false, false, MtaSenderStage.WAITING_PEER_CONFIRM)
      expect(create.decision).assertEqual(MtaSendEventDecision.createAndAdvance)
      expect(create.decision !== MtaSendEventDecision.finish).assertTrue()
    })

    it('mtaSend_peerGroupAbandonDebounceDecision', 0, () => {
      // 防抖阈值：连续 2 次观测归零（约 1~2s）才判放弃
      let limit = MtaConstants.GROUP_CLIENT_ZERO_STREAK_LIMIT
      expect(limit).assertEqual(2)
      // 等待确认阶段：客户端数由 1 降为 0 → 累计 1 次，未达阈值不判放弃
      let first = decidePeerGroupAbandon(MtaSenderStage.WAITING_PEER_CONFIRM, 1, 0, 0)
      expect(first.zeroStreak).assertEqual(1)
      expect(first.abandoned).assertFalse()
      // 连续第二次观测归零 → 达到阈值判定放弃
      let second = decidePeerGroupAbandon(MtaSenderStage.WAITING_PEER_CONFIRM, 0, 0, first.zeroStreak)
      expect(second.zeroStreak).assertEqual(limit)
      expect(second.abandoned).assertTrue()
      // 群组信息不可得（-1）同样计入归零
      let unavailable = decidePeerGroupAbandon(MtaSenderStage.WAITING_PEER_CONFIRM, 1, -1, 0)
      expect(unavailable.zeroStreak).assertEqual(1)
      expect(unavailable.abandoned).assertFalse()
      // 非等待确认阶段不触发，且计数清零
      let other = decidePeerGroupAbandon(MtaSenderStage.TRANSFERRING, 1, 0, 1)
      expect(other.zeroStreak).assertEqual(0)
      expect(other.abandoned).assertFalse()
      // 客户端数回升 → 计数清零
      let back = decidePeerGroupAbandon(MtaSenderStage.WAITING_PEER_CONFIRM, 0, 1, 2)
      expect(back.zeroStreak).assertEqual(0)
      expect(back.abandoned).assertFalse()
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

    it('mtaReceive_textAccept_noBehaviorChange', 0, () => {
      let acceptedDownload = 0
      let acceptedText = 0
      let rejected = 0
      setMtaReceiveInvokers(
        (): void => {
          acceptedDownload++
        },
        (): void => {
          rejected++
        },
        (): void => {
        },
        (): void => {
          acceptedText++
        },
        (): Array<MediaFileInfo> => []
      )

      // 「复制」路径：界面写剪贴板后触发接受；适配器只做接受收尾（不进入下载流程）
      resetRegistry()
      handleMtaReceiveState(textReceiveState('MtaSender', '你好'))
      let copyId = findByProtocol('mta-receive', 'mta-receive-session')
      expect(copyId !== undefined).assertTrue()
      let adapter = getAdapter(MTA_RECEIVE_KEY)
      expect(adapter !== undefined).assertTrue()
      if (copyId !== undefined && adapter !== undefined) {
        // 展示描述符携带文本内容：接受但不复制，剪贴板由界面独立写入
        let display = adapter.getDisplayDescriptor(copyId.id)
        expect(display.supportsTextPreview).assertTrue()
        expect(display.textPreview).assertEqual('你好')
        adapter.confirm(copyId.id)
        expect(acceptedText).assertEqual(1)
        expect(acceptedDownload).assertEqual(0)
        let copied = getSession(copyId.id)
        if (copied !== undefined) {
          expect(copied.stage).assertEqual(SessionStage.succeeded)
        }
      }

      // 「关闭」路径：不写剪贴板、直接触发接受；终态与「复制」路径一致
      resetRegistry()
      handleMtaReceiveState(textReceiveState('MtaSender', '再见'))
      let closeId = findByProtocol('mta-receive', 'mta-receive-session')
      expect(closeId !== undefined).assertTrue()
      if (closeId !== undefined && adapter !== undefined) {
        adapter.confirm(closeId.id)
        expect(acceptedText).assertEqual(2)
        let closed = getSession(closeId.id)
        if (closed !== undefined) {
          expect(closed.stage).assertEqual(SessionStage.succeeded)
        }
      }

      // 拒绝路径不受命名统一影响：不触发接受入口
      resetRegistry()
      handleMtaReceiveState(textReceiveState('MtaSender', '拒绝'))
      let rejectId = findByProtocol('mta-receive', 'mta-receive-session')
      expect(rejectId !== undefined).assertTrue()
      if (rejectId !== undefined && adapter !== undefined) {
        adapter.decline(rejectId.id)
        expect(rejected).assertEqual(1)
        expect(acceptedText).assertEqual(2)
        let pending = getSession(rejectId.id)
        if (pending !== undefined) {
          expect(pending.stage).assertEqual(SessionStage.awaitingConfirmation)
        }
      }
      resetRegistry()
    })

    it('protocolSessionId_semanticsAcrossProtocols', 0, () => {
      resetRegistry()

      // 局域网发送：创建时协议标识尚不可知 → 为空；应用内部业务编号不得出现在该字段
      let businessId = 'multi_1790000000000_1'
      let sendId = beginLocalSendSession(businessId, device(), [
        { fileId: 'f1', filePath: '/a', fileName: 'a', fileType: '', size: 10 }
      ])
      let sendSession = getSession(sendId)
      expect(sendSession !== undefined ? sendSession.protocolSessionId : 'x').assertEqual('')
      expect(sendSession !== undefined && sendSession.protocolSessionId !== businessId).assertTrue()

      // 互传接收：使用请求携带的协议任务标识
      let state = new ReceiverState()
      state.stage = ReceiverStage.REQUEST_RECEIVED
      let request = new ReceiveRequest()
      request.taskId = 'mta-task-7'
      request.senderName = 'MtaSender'
      request.fileName = 'a.bin'
      request.totalSize = 10
      state.receiveRequest = request
      handleMtaReceiveState(state)
      expect(findByProtocol('mta-receive', 'mta-task-7') !== undefined).assertTrue()
      resetRegistry()

      // 互传接收：请求未携带任务标识 → 回退既有常量
      let noTaskState = new ReceiverState()
      noTaskState.stage = ReceiverStage.REQUEST_RECEIVED
      let noTaskRequest = new ReceiveRequest()
      noTaskRequest.senderName = 'MtaSender'
      noTaskRequest.fileName = 'a.bin'
      noTaskRequest.totalSize = 10
      noTaskState.receiveRequest = noTaskRequest
      handleMtaReceiveState(noTaskState)
      expect(findByProtocol('mta-receive', 'mta-receive-session') !== undefined).assertTrue()
      resetRegistry()

      // 网页下载：协议层无会话标识概念 → 为空；内部突发身份不上屏
      let webId = beginWebDownloadBurst('192.168.1.60', true)
      let web = getSession(webId)
      expect(web !== undefined ? web.protocolSessionId : 'x').assertEqual('')

      resetRegistry()
    })

    it('textAsFile_renameRule_pathPassthrough_andTextPredicate', 0, () => {
      // 文本类判定唯一来源（MIME 或扩展名）
      expect(isTextFile('text/plain', 'a.bin')).assertTrue()
      expect(isTextFile('', 'note.txt')).assertTrue()
      expect(isTextFile('application/octet-stream', 'a.bin')).assertFalse()

      let ctx = getTestAppContext()
      if (ctx === undefined) {
        expect(true).assertTrue()
        return
      }
      // 重名规则（文本与普通文件同一规则）：同名自动加序号、不覆盖
      let dir = ctx.cacheDir + '/adapters_text_test'
      try {
        fs.mkdirSync(dir, true)
      } catch (_e) {
      }
      let p = dir + '/sharedText.txt'
      let file = fs.openSync(p, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY)
      fs.closeSync(file)
      expect(uniquePath(dir, 'sharedText.txt')).assertEqual('sharedText (1).txt')
      expect(uniquePath(dir, 'other.txt')).assertEqual('other.txt')

      // 局域网发送会话描述符携带发送条目路径（含文本条目）
      resetRegistry()
      let id = beginLocalSendSession('single_path', device(), [
        { fileId: 'f1', filePath: p, fileName: 'sharedText.txt', fileType: 'text/plain', size: 0 }
      ])
      let s = getSession(id)
      expect(s !== undefined).assertTrue()
      if (s !== undefined) {
        expect(s.files[0].path).assertEqual(p)
      }
      // 运行期写入/更新会话文件路径
      expect(updateSessionFilePath(id, 'f1', dir + '/sharedText (1).txt')).assertTrue()
      let updated = getSession(id)
      if (updated !== undefined) {
        expect(updated.files[0].path).assertEqual(dir + '/sharedText (1).txt')
      }
      // 会话不存在/文件标识未命中：空操作
      expect(updateSessionFilePath('no-such', 'f1', p)).assertFalse()
      expect(updateSessionFilePath(id, 'no-file', p)).assertFalse()
      try {
        fs.unlinkSync(p)
      } catch (_e) {
      }
      resetRegistry()
    })

    it('mtaReceiveText_pathBackfill_liveThenHistory_andTerminalNoOp', 0, () => {
      resetRegistry()
      resetSessionHistoryCache()
      // 互传接收文本请求到达：创建待确认会话，文本文件条目为 mta-0
      handleMtaReceiveState(textReceiveState('MtaSender', '你好世界'))
      let found = findByProtocol(MTA_RECEIVE_KEY, 'mta-receive-session')
      expect(found !== undefined).assertTrue()
      if (found === undefined) {
        resetRegistry()
        return
      }
      // 初始无路径（协议标识与落盘均未就绪）
      expect(found.files[0].path).assertEqual('')

      // 落盘路径由接收服务上抛 → 适配器回填：会话文件条目带有该路径（实时态可预览）
      let savedPath = '/storage/Download/com.example/sharedText.txt'
      notifyMtaTextSaved(savedPath)
      let live = getSession(found.id)
      expect(live !== undefined ? live.files[0].path : 'x').assertEqual(savedPath)

      // 终结归档：历史逐文件条目透传同一路径（历史态同样可按路径预览）
      finish(found.id, SessionStage.succeeded)
      let entries = getHistory()
      let matched = false
      for (let i = 0; i < entries.length; i++) {
        if (entries[i].sessionId === found.id) {
          matched = true
          expect(entries[i].files[0].path).assertEqual(savedPath)
        }
      }
      expect(matched).assertTrue()

      // 会话已终态：回填为 no-op（不覆盖、不抛异常）
      expect(updateSessionFilePath(found.id, 'mta-0', '/other/path.txt')).assertFalse()
      notifyMtaTextSaved('/other/path.txt')
      let after = getSession(found.id)
      expect(after !== undefined ? after.files[0].path : 'x').assertEqual(savedPath)

      resetRegistry()
      resetSessionHistoryCache()
    })
  })
}
