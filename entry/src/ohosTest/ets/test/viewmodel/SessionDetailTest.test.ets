import { describe, it, expect, beforeAll } from '@ohos/hypium'
import {
  SessionCreateInput,
  SessionCapabilities,
  SessionDataFlow,
  SessionDisplayDescriptor,
  SessionEventKind,
  SessionFile,
  SessionInitiator,
  SessionStage,
  emptyPeer
} from '../../../../main/ets/model/transfer/TransferSession'
import {
  createSession,
  confirmSession,
  finish,
  getSession,
  resetRegistry,
  updateProtocolSessionId,
  updateSessionFilePath
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  SessionAdapter,
  registerAdapter
} from '../../../../main/ets/service/transfer/adapters/SessionAdapter'
import { resetSessionHistoryCache } from '../../../../main/ets/service/transfer/SessionHistoryStore'
import { SessionDetailViewModel, SessionPreviewMode, canCopyMetaValue,
  decidePreviewMode } from '../../../../main/ets/viewmodel/SessionDetailViewModel'
import { copyText } from '../../../../main/ets/utils/ClipboardUtil'
import { preferencesUtil } from '../../../../main/ets/utils/PreferencesUtil'
import { getTestAppContext } from '../helper/TestContext'
import { writeTestFileToSandbox } from '../helper/TestHelper'

const DETAIL_KEY: string = 'test-detail'
const TEXT_DETAIL_KEY: string = 'test-text-detail'
const TEXT_PREVIEW: string = '你好，这是一条文本消息'

let lastCancelled: string = ''

function testCapabilities(): SessionCapabilities {
  return {
    canCancel: true,
    canRetry: true,
    needsConfirm: true,
    hasByteProgress: true,
    canSaveToGallery: true,
    hasVerify: false
  };
}

const testAdapter: SessionAdapter = {
  key: DETAIL_KEY,
  initialize: (): void => {
  },
  getCapabilities: testCapabilities,
  getDisplayDescriptor: (sessionId: string): SessionDisplayDescriptor => {
    return {
      peerTitle: 'TestPeer',
      peerSubtitle: '10.0.0.1',
      badges: ['Model'],
      deviceType: 'mobile',
      directionLabel: '发送',
      supportsTextPreview: false
    };
  },
  confirm: (): void => {
  },
  decline: (): void => {
  },
  cancel: (sessionId: string): void => {
    lastCancelled = sessionId;
  },
  retry: (): void => {
  },
  dispose: (): void => {
  }
};

function input(): SessionCreateInput {
  return {
    protocolKey: DETAIL_KEY,
    protocolSessionId: 'p1',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: emptyPeer(),
    files: [{ fileId: 'f1', fileName: 'a', fileType: 'text/plain', totalBytes: 100 }],
    capabilities: testCapabilities()
  }
}

// 文本消息适配器：正向动作（确认）即「接受文本」收尾，按成功终态并回接受语义
function textCapabilities(): SessionCapabilities {
  return {
    canCancel: true,
    canRetry: false,
    needsConfirm: true,
    hasByteProgress: false,
    canSaveToGallery: false,
    hasVerify: false
  };
}

const textAdapter: SessionAdapter = {
  key: TEXT_DETAIL_KEY,
  initialize: (): void => {
  },
  getCapabilities: textCapabilities,
  getDisplayDescriptor: (sessionId: string): SessionDisplayDescriptor => {
    return {
      peerTitle: 'TextPeer',
      peerSubtitle: '10.0.0.2',
      badges: [],
      deviceType: 'mobile',
      directionLabel: '接收',
      supportsTextPreview: true,
      textPreview: TEXT_PREVIEW
    };
  },
  confirm: (sessionId: string): void => {
    // 文本接受无下载流程、协议侧不产生终态信号，接受收尾即成功
    finish(sessionId, SessionStage.succeeded);
  },
  decline: (): void => {
  },
  cancel: (): void => {
  },
  retry: (): void => {
  },
  dispose: (): void => {
  }
};

function textInput(): SessionCreateInput {
  return {
    protocolKey: TEXT_DETAIL_KEY,
    protocolSessionId: 'ptxt',
    dataFlow: SessionDataFlow.inbound,
    initiatedBy: SessionInitiator.remote,
    peer: emptyPeer(),
    files: [{ fileId: 'f1', fileName: 'message.txt', fileType: 'text/plain', totalBytes: 5 }],
    capabilities: textCapabilities(),
    stage: SessionStage.awaitingConfirmation
  }
}

export default function SessionDetailTest() {
  describe('SessionDetailTest', () => {
    beforeAll(() => {
      // 初始化偏好存储：历史条目取数用例依赖会话历史持久化
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        preferencesUtil.init(ctx)
      }
    })

    it('capabilities_driveActionAvailability', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      let s = createSession(input())
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      // 进行中：可取消；needsConfirm 但状态非待确认 → 不可确认
      expect(vm.canCancel()).assertTrue()
      expect(vm.canConfirm()).assertFalse()
      expect(vm.canDecline()).assertFalse()
      expect(vm.capabilities.canSaveToGallery).assertTrue()
      // 终态：不可取消
      finish(s.id, SessionStage.failed)
      vm.refresh()
      expect(vm.canCancel()).assertFalse()
      vm.unload()
      resetRegistry()
    })

    it('confirm_movesToActive_andTimelineGrows', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      let createInput = input()
      createInput.stage = SessionStage.awaitingConfirmation
      createInput.capabilities = testCapabilities()
      let s = createSession(createInput)
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      expect(vm.canConfirm()).assertTrue()
      let before: number = vm.timeline.length
      confirmSession(s.id)
      vm.refresh()
      let current = getSession(s.id)
      expect(current !== undefined).assertTrue()
      if (current !== undefined) {
        expect(current.stage).assertEqual(SessionStage.active)
      }
      expect(vm.timeline.length > before).assertTrue()
      let hasConfirmed: boolean = false
      for (let i = 0; i < vm.timeline.length; i++) {
        if (vm.timeline[i].kind === SessionEventKind.confirmed) {
          hasConfirmed = true;
        }
      }
      expect(hasConfirmed).assertTrue()
      vm.unload()
      resetRegistry()
    })

    it('back_doesNotCancelSession', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      lastCancelled = ''
      let s = createSession(input())
      let vm = new SessionDetailViewModel()
      // 进入详情页仅订阅与刷新，不触发取消
      vm.load(s.id)
      vm.refresh()
      vm.unload()
      expect(lastCancelled.length).assertEqual(0)
      let current = getSession(s.id)
      expect(current !== undefined).assertTrue()
      if (current !== undefined) {
        expect(current.stage).assertEqual(SessionStage.active)
      }
      resetRegistry()
    })

    it('cancel_isExplicit_andDispatchesToAdapter', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      lastCancelled = ''
      let s = createSession(input())
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      vm.cancelTransfer()
      expect(lastCancelled).assertEqual(s.id)
      let current = getSession(s.id)
      if (current !== undefined) {
        expect(current.stage).assertEqual(SessionStage.cancelled)
      }
      vm.unload()
      resetRegistry()
    })

    it('displayDescriptor_fromAdapter', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      let s = createSession(input())
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      expect(vm.display.peerTitle).assertEqual('TestPeer')
      expect(vm.display.badges.length).assertEqual(1)
      vm.unload()
      resetRegistry()
    })

    it('meta_exposesLiveCompleteInfo', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      let createInput = input()
      createInput.peer = {
        displayName: 'Peer',
        ip: '10.0.0.9',
        fingerprint: 'fp-1',
        deviceType: 'mobile',
        badges: ['Model X']
      }
      let s = createSession(createInput)
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      // 对端设备信息和标识统一取数
      expect(vm.meta.peerFingerprint).assertEqual('fp-1')
      expect(vm.meta.peerIp).assertEqual('10.0.0.9')
      expect(vm.meta.peerDeviceModel).assertEqual('Model X')
      expect(vm.meta.protocolSessionId).assertEqual('p1')
      expect(vm.meta.sessionId).assertEqual(s.id)
      // 逐文件清单与时间线
      expect(vm.detailFiles().length).assertEqual(1)
      expect(vm.detailTimeline().length > 0).assertTrue()
      // 终结后错误信息与错误码写入完整信息
      finish(s.id, SessionStage.failed, 'boom', 'E42')
      vm.refresh()
      expect(vm.meta.errorMessage).assertEqual('boom')
      expect(vm.meta.errorCode).assertEqual('E42')
      expect(vm.currentStage()).assertEqual(SessionStage.failed)
      vm.unload()
      resetRegistry()
    })

    it('meta_durationMs_matchesTimelineScope_whenMsOverflow', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      let s = createSession(input())
      // 复现偏差场景：start=..00.900, end=..02.100（实际 1200ms）。
      // 时间线显示 10:00:00 → 10:00:02（差 2 秒），耗时须按时间线口径为 2000ms
      s.startedAt = 1000000000900
      finish(s.id, SessionStage.succeeded)
      let current = getSession(s.id)
      expect(current !== undefined).assertTrue()
      if (current !== undefined) {
        current.finishedAt = 1000000002100
      }
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      expect(vm.meta.durationMs).assertEqual(2000)
      vm.unload()
      resetRegistry()
    })

    it('meta_durationMs_matchesTimelineScope_withinSameSecond', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      let s = createSession(input())
      // start=..00.900, end=..01.100（实际 200ms）：时间线显示差 1 秒，耗时须为 1000ms
      s.startedAt = 1000000000900
      finish(s.id, SessionStage.succeeded)
      let current = getSession(s.id)
      expect(current !== undefined).assertTrue()
      if (current !== undefined) {
        current.finishedAt = 1000000001100
      }
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      expect(vm.meta.durationMs).assertEqual(1000)
      vm.unload()
      resetRegistry()
    })

    it('meta_emptyProtocolSessionId_placeholderSemantics', 0, () => {
      resetRegistry()
      let createInput = input()
      createInput.protocolSessionId = ''
      let s = createSession(createInput)
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      // 该栏来源即会话上的协议会话 ID：为空时展示层统一降级为占位，不得回退为内部业务编号
      expect(vm.meta.protocolSessionId).assertEqual('')
      expect(vm.meta.protocolSessionId.indexOf('multi_') < 0).assertTrue()
      expect(vm.meta.sessionId).assertEqual(s.id)
      // 协议标识回填后发布变更通知，详情刷新为新值
      expect(updateProtocolSessionId(s.id, 'recv-uuid-9')).assertTrue()
      vm.refresh()
      expect(vm.meta.protocolSessionId).assertEqual('recv-uuid-9')
      vm.unload()
      resetRegistry()
    })

    it('meta_fromHistoryEntry_whenSessionReclaimed', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      resetSessionHistoryCache()
      let createInput = input()
      createInput.peer = {
        displayName: 'Peer',
        ip: '10.0.0.9',
        fingerprint: 'fp-2',
        deviceType: 'mobile',
        badges: ['Model X']
      }
      let s = createSession(createInput)
      finish(s.id, SessionStage.succeeded)
      // 模拟会话回收：注册表清空后仅历史台账可读
      resetRegistry()
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      expect(vm.isReadOnly()).assertTrue()
      // 对端设备信息、逐文件清单仍可读
      expect(vm.meta.peerFingerprint).assertEqual('fp-2')
      expect(vm.meta.peerIp).assertEqual('10.0.0.9')
      expect(vm.detailFiles().length).assertEqual(1)
      expect(vm.currentStage()).assertEqual(SessionStage.succeeded)
      vm.unload()
      resetRegistry()
    })

    it('textSession_closeAndCopy_bothSucceed', 0, () => {
      registerAdapter(textAdapter)
      resetRegistry()
      // 文本会话：正向动作可用（关闭＝接受），并携带可复制的文本内容
      let closeSession = createSession(textInput())
      let closeVm = new SessionDetailViewModel()
      closeVm.load(closeSession.id)
      expect(closeVm.hasTextPreview()).assertTrue()
      expect(closeVm.canConfirm()).assertTrue()
      expect(closeVm.textPreview()).assertEqual(TEXT_PREVIEW)
      // 关闭＝直接触发接受，不写入剪贴板，收尾为成功终态
      closeVm.confirm()
      let closed = getSession(closeSession.id)
      expect(closed !== undefined).assertTrue()
      if (closed !== undefined) {
        expect(closed.stage).assertEqual(SessionStage.succeeded)
      }
      closeVm.unload()

      // 复制＝先写剪贴板（设备端粘贴板可用），写入成功后再按接受收尾
      let copySession = createSession(textInput())
      let copyVm = new SessionDetailViewModel()
      copyVm.load(copySession.id)
      expect(copyText(copyVm.textPreview())).assertTrue()
      copyVm.confirm()
      let copied = getSession(copySession.id)
      expect(copied !== undefined).assertTrue()
      if (copied !== undefined) {
        expect(copied.stage).assertEqual(SessionStage.succeeded)
      }
      copyVm.unload()
      resetRegistry()
    })

    it('releasedSession_fallsBackToHistoryReadOnly', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      resetSessionHistoryCache()
      let s = createSession(input())
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      expect(vm.isReadOnly()).assertFalse()
      // 页面保持打开期间会话被终结，随后在可见窗口结束后被回收
      finish(s.id, SessionStage.failed)
      vm.refresh()
      resetRegistry()
      vm.refresh()
      // 已归档：优先回退历史只读摘要，动作全部不可用
      expect(vm.isReadOnly()).assertTrue()
      expect(vm.canConfirm()).assertFalse()
      expect(vm.canDecline()).assertFalse()
      expect(vm.canCancel()).assertFalse()
      expect(vm.currentStage()).assertEqual(SessionStage.failed)
      vm.unload()
      resetRegistry()
    })

    it('releasedSession_withoutHistory_disablesAllActions', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      let s = createSession(input())
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      expect(vm.canCancel()).assertTrue()
      // 未终结即离开注册表（无可回退历史）：保留最后快照但全部动作不可用
      resetRegistry()
      vm.refresh()
      expect(vm.isReadOnly()).assertFalse()
      expect(vm.liveReleased).assertTrue()
      expect(vm.canConfirm()).assertFalse()
      expect(vm.canDecline()).assertFalse()
      expect(vm.canCancel()).assertFalse()
      vm.unload()
      resetRegistry()
    })

    it('previewMode_singleTextInline_multiOrBinaryList', 0, () => {
      let text = new SessionFile()
      text.fileType = 'text/plain'
      text.fileName = 'a.txt'
      let binary = new SessionFile()
      binary.fileType = 'application/octet-stream'
      binary.fileName = 'a.bin'
      // 单文本文件 → 内联预览
      expect(decidePreviewMode([text])).assertEqual(SessionPreviewMode.inline)
      // 用户经文件选择器选中的 .txt 与文本消息表现一致（不做区分）
      let picked = new SessionFile()
      picked.fileType = ''
      picked.fileName = 'note.txt'
      expect(decidePreviewMode([picked])).assertEqual(SessionPreviewMode.inline)
      // 多文件（含文本）→ 清单 + 点击预览
      expect(decidePreviewMode([text, binary])).assertEqual(SessionPreviewMode.list)
      // 单非文本文件与空文件集合 → 仅清单
      expect(decidePreviewMode([binary])).assertEqual(SessionPreviewMode.list)
      expect(decidePreviewMode([])).assertEqual(SessionPreviewMode.list)
    })

    it('previewMode_historyState_sameRule_andUnavailableByPath', 0, () => {
      resetRegistry()
      resetSessionHistoryCache()
      // 历史态：逐文件条目仅带 fileType/fileName（无实时对象），同一规则判定
      let createInput = input()
      createInput.protocolSessionId = ''
      let s = createSession(createInput)
      finish(s.id, SessionStage.succeeded)
      resetRegistry()
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      expect(vm.isReadOnly()).assertTrue()
      // 单文本文件：内联模式；无路径 → 内容不可用（明确标记，不空白）
      expect(vm.isInlinePreview()).assertTrue()
      expect(vm.previewUnavailable).assertTrue()
      expect(vm.textPreview()).assertEqual('')
      vm.unload()
      resetRegistry()
      resetSessionHistoryCache()
    })

    it('metaCopyAvailability_nonEmptyOnly', 0, () => {
      // 非空可复制；空值不可复制（展示统一占位）
      expect(canCopyMetaValue('recv-uuid-1')).assertTrue()
      expect(canCopyMetaValue('')).assertFalse()
    })

    it('historyState_filePath_propagatesToDetailEntry_andPreviewReadable', 0, () => {
      registerAdapter(textAdapter)
      resetRegistry()
      resetSessionHistoryCache()
      let path = writeTestFileToSandbox('session_detail_text.txt', '历史态文本内容')
      let createInput = textInput()
      createInput.stage = SessionStage.active
      let s = createSession(createInput)
      // 接收侧在会话终结前回填文本文件的落盘路径
      expect(updateSessionFilePath(s.id, 'f1', path)).assertTrue()
      finish(s.id, SessionStage.succeeded)
      // 模拟会话回收：注册表清空后仅历史台账可读
      resetRegistry()
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      expect(vm.isReadOnly()).assertTrue()
      // 历史逐文件条目携带的路径透传到详情文件条目（会话离开运行时映射后路径不丢失）
      expect(vm.detailFiles().length).assertEqual(1)
      expect(vm.detailFiles()[0].path).assertEqual(path)
      // 历史态内联预览按该路径读取到内容，不误报「内容不可用」
      expect(vm.isInlinePreview()).assertTrue()
      expect(vm.previewUnavailable).assertFalse()
      expect(vm.textPreview()).assertEqual('历史态文本内容')
      vm.unload()
      resetRegistry()
      resetSessionHistoryCache()
    })
  })
}
