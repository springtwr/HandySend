import { describe, it, expect } from '@ohos/hypium'
import {
  throttleDelayMs,
  resolveTerminalKind,
  shouldExecuteStop,
  isUserCancel,
  TransferTerminalKind as TerminalKind
} from '../../../../main/ets/service/BackgroundTransferService'
import {
  AttentionKind,
  resolveAttentionKind
} from '../../../../main/ets/service/BackgroundAttentionNotifier'
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
  getPendingSessionIds,
  hasSessionOrHistory,
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

    // ── 停止决策：有任务 Id 按 Id 停，无 Id 才依赖代次 ──
    it('stopTarget_byTaskIdOrGeneration', 0, () => {
      // 有任务 Id：即使新周期已启动，也必须停止旧任务
      expect(shouldExecuteStop(7, 2, 3)).assertTrue()
      // 无任务 Id：代次一致才允许停全部
      expect(shouldExecuteStop(-1, 2, 2)).assertTrue()
      expect(shouldExecuteStop(-1, 2, 3)).assertFalse()
    })

    // ── 用户取消判定：兼容 reason 与 API 26 detailedReason ──
    it('userCancel_reasonAndDetailed', 0, () => {
      expect(isUserCancel(1, undefined)).assertTrue()
      expect(isUserCancel(3, undefined)).assertTrue()
      expect(isUserCancel(2, 3)).assertTrue()
      expect(isUserCancel(2, 4)).assertFalse()
      expect(isUserCancel(2, undefined)).assertFalse()
    })

    // ── 后台关注类别：待确认请求优先于网页访问 ──
    it('attentionKind_pendingFirst', 0, () => {
      expect(resolveAttentionKind(0)).assertEqual(AttentionKind.none)
      expect(resolveAttentionKind(2)).assertEqual(AttentionKind.pendingRequest)
      expect(resolveAttentionKind(1)).assertEqual(AttentionKind.pendingRequest)
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

    // ── 待确认会话标识：后台关注通知的详情跳转依据 ──
    it('pendingSessionIds_onlyAwaiting', 0, () => {
      resetRegistry()
      let pendingFirstInput = input('localsend-receive', 'pending-1')
      pendingFirstInput.stage = SessionStage.awaitingConfirmation
      let first = createSession(pendingFirstInput)
      let active = createSession(input('localsend-send', 'active-1'))
      let pendingSecondInput = input('mta-receive', 'pending-2')
      pendingSecondInput.stage = SessionStage.awaitingConfirmation
      let second = createSession(pendingSecondInput)
      let ids = getPendingSessionIds()
      expect(ids.length).assertEqual(2)
      expect(ids[0]).assertEqual(first.id)
      expect(ids[1]).assertEqual(second.id)
      // 进行中会话不得混入待确认集合
      expect(ids.indexOf(active.id)).assertEqual(-1)
      resetRegistry()
    })

    // ── 通知深链落点有效性：实时会话或历史至少存在其一 ──
    it('hasSessionOrHistory_liveSession', 0, () => {
      resetRegistry()
      let session = createSession(input('localsend-send', 'live'))
      expect(hasSessionOrHistory(session.id)).assertTrue()
      expect(hasSessionOrHistory('missing-session-id')).assertFalse()
      resetRegistry()
    })
  })
}
