import { describe, it, expect } from '@ohos/hypium'
import {
  throttleDelayMs,
  resolveTerminalKind,
  TransferTerminalKind as TerminalKind
} from '../../../../main/ets/service/BackgroundTransferService'
import {
  SessionCreateInput,
  SessionDataFlow,
  SessionInitiator,
  SessionStage,
  defaultCapabilities,
  emptyPeer
} from '../../../../main/ets/model/transfer/TransferSession'
import {
  createSession,
  finish,
  getOverallSnapshot,
  updateFileProgress,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'

function input(key: string, id: string): SessionCreateInput {
  return {
    protocolKey: key,
    protocolSessionId: id,
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: emptyPeer(),
    files: [{
      fileId: 'f-' + id,
      fileName: 'a',
      fileType: '',
      totalBytes: 100
    }],
    capabilities: defaultCapabilities()
  }
}

export default function BackgroundAggregateTest() {
  describe('BackgroundAggregateTest', () => {
    // ── 节流决策 ──
    it('throttle_decisions', 0, () => {
      // 首帧（尚未发布）与已达间隔立即发布
      expect(throttleDelayMs(100000, -1, 1000)).assertEqual(0)
      expect(throttleDelayMs(101000, 100000, 1000)).assertEqual(0)
      expect(throttleDelayMs(105000, 100000, 1000)).assertEqual(0)
      // 未到间隔返回剩余毫秒数
      expect(throttleDelayMs(100500, 100000, 1000)).assertEqual(500)
      expect(throttleDelayMs(100999, 100000, 1000)).assertEqual(1)
    })

    // ── 三档终态文案决策 ──
    it('terminalKind_threeTiers', 0, () => {
      expect(resolveTerminalKind(false, false)).assertEqual(TerminalKind.success)
      expect(resolveTerminalKind(true, true)).assertEqual(TerminalKind.failed)
      expect(resolveTerminalKind(true, false)).assertEqual(TerminalKind.partial)
    })

    // ── 协议无关聚合（来自注册表） ──
    it('overall_activeAndProgress', 0, () => {
      resetRegistry()
      let a = createSession(input('localsend-send', 'a'))
      createSession(input('mta-send', 'b'))
      updateFileProgress(a.id, 'f-a', 50)
      let overall = getOverallSnapshot(0)
      expect(overall.active).assertTrue()
      expect(overall.sessionCount).assertEqual(2)
      expect(overall.deviceCount).assertEqual(0) // 匿名对端（无展示名）不计数
      expect(overall.allFinished).assertFalse()
      resetRegistry()
    })

    it('overall_allFinished_success', 0, () => {
      resetRegistry()
      let a = createSession(input('localsend-send', 'a'))
      finish(a.id, SessionStage.succeeded)
      let overall = getOverallSnapshot(0)
      expect(overall.active).assertFalse()
      expect(overall.allFinished).assertTrue()
      expect(overall.hasFailure).assertFalse()
      resetRegistry()
    })

    it('overall_mixedTerminal_hasFailure', 0, () => {
      resetRegistry()
      let a = createSession(input('localsend-send', 'a'))
      let b = createSession(input('mta-send', 'b'))
      finish(a.id, SessionStage.succeeded)
      finish(b.id, SessionStage.failed)
      let overall = getOverallSnapshot(0)
      expect(overall.active).assertFalse()
      expect(overall.allFinished).assertTrue()
      expect(overall.hasFailure).assertTrue()
      resetRegistry()
    })

    it('overall_percentMonotonic', 0, () => {
      resetRegistry()
      let a = createSession(input('localsend-send', 'a'))
      updateFileProgress(a.id, 'f-a', 30)
      let first = getOverallSnapshot(0)
      let second = getOverallSnapshot(80)
      expect(second.percent >= first.percent).assertTrue()
      resetRegistry()
    })

    it('overall_pendingExcludedFromActive', 0, () => {
      // 仅有待确认请求、无任何已开始传输：活跃口径全部为 0
      resetRegistry()
      let pendingInput = input('localsend-receive', 'pending')
      pendingInput.stage = SessionStage.awaitingConfirmation
      pendingInput.peer = { displayName: 'PendingPeer', badges: [] }
      createSession(pendingInput)
      let overall = getOverallSnapshot(0)
      expect(overall.active).assertFalse()
      expect(overall.sessionCount).assertEqual(0)
      expect(overall.deviceCount).assertEqual(0)
      expect(overall.bytesSent).assertEqual(0)
      expect(overall.totalBytes).assertEqual(0)
      expect(overall.percent).assertEqual(0)
      // 仅有待确认时不得误判为全部完成（避免提前发布终态通知）
      expect(overall.allFinished).assertFalse()
      resetRegistry()
    })
  })
}
