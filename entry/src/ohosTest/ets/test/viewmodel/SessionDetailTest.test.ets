import { describe, it, expect } from '@ohos/hypium'
import {
  SessionCreateInput,
  SessionCapabilities,
  SessionDataFlow,
  SessionDisplayDescriptor,
  SessionEventKind,
  SessionInitiator,
  SessionStage,
  emptyPeer
} from '../../../../main/ets/model/transfer/TransferSession'
import {
  createSession,
  confirmSession,
  finish,
  getSession,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  SessionAdapter,
  registerAdapter
} from '../../../../main/ets/service/transfer/adapters/SessionAdapter'
import { SessionDetailViewModel } from '../../../../main/ets/viewmodel/SessionDetailViewModel'

const DETAIL_KEY: string = 'test-detail'

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
      stageLabel: '传输中',
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

export default function SessionDetailTest() {
  describe('SessionDetailTest', () => {
    it('capabilities_driveActionAvailability', 0, () => {
      registerAdapter(testAdapter)
      resetRegistry()
      let s = createSession(input())
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      // 进行中：可取消，不可重试；needsConfirm 但状态非待确认 → 不可确认
      expect(vm.canCancel()).assertTrue()
      expect(vm.canRetry()).assertFalse()
      expect(vm.canConfirm()).assertFalse()
      expect(vm.canDecline()).assertFalse()
      expect(vm.capabilities.canSaveToGallery).assertTrue()
      // 终态：可重试（发送方向 + canRetry），不可取消
      finish(s.id, SessionStage.failed)
      vm.refresh()
      expect(vm.canRetry()).assertTrue()
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
  })
}
