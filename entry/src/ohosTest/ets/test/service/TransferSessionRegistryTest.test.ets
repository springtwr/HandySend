import { describe, it, expect } from '@ohos/hypium'
import {
  createSession,
  appendFiles,
  updateFileProgress,
  finish,
  setStage,
  getSession,
  getOverallSnapshot,
  getActiveCount,
  querySessions,
  resetRegistry,
  reclaimDelayMs,
  deriveOverall,
  recomputeTotals,
  SUCCESS_VISIBLE_MS,
  FAILURE_VISIBLE_MS
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  SessionCreateInput,
  SessionDataFlow,
  SessionInitiator,
  SessionStage,
  SessionFilter,
  TransferSession,
  defaultCapabilities,
  emptyPeer,
  isTerminalStage,
  outcomeForStage,
  SessionHistoryOutcome
} from '../../../../main/ets/model/transfer/TransferSession'

// 会话注册表纯逻辑单测：生命周期、聚合、回收窗口、分母增长容忍。
function makeInput(): SessionCreateInput {
  return {
    protocolKey: 'test',
    protocolSessionId: 'p1',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: emptyPeer(),
    files: [{ fileId: 'f1', fileName: 'a.bin', fileType: 'application/octet-stream', totalBytes: 100 }],
    capabilities: defaultCapabilities()
  }
}

export default function TransferSessionRegistryTest() {
  describe('TransferSessionRegistryTest', () => {
    it('create_session_initialState', 0, () => {
      resetRegistry()
      let s = createSession(makeInput())
      expect(s.stage).assertEqual(SessionStage.active)
      expect(s.timeline.length).assertEqual(2) // created + started
      expect(getActiveCount()).assertEqual(1)
      expect(getSession(s.id) !== undefined).assertTrue()
      resetRegistry()
    })

    it('first_terminal_wins', 0, () => {
      resetRegistry()
      let s = createSession(makeInput())
      finish(s.id, SessionStage.succeeded)
      // 终态后再改状态应被忽略（取消/完成竞态给出唯一结果）
      setStage(s.id, SessionStage.failed, 'late')
      finish(s.id, SessionStage.cancelled)
      let current = getSession(s.id)
      expect(current !== undefined).assertTrue()
      if (current !== undefined) {
        expect(current.stage).assertEqual(SessionStage.succeeded)
        expect(current.finishedAt > 0).assertTrue()
      }
      resetRegistry()
    })

    it('denominator_growth_no_regression', 0, () => {
      resetRegistry()
      let s = createSession(makeInput())
      // 首文件传一半
      updateFileProgress(s.id, 'f1', 50)
      let before = getSession(s.id)
      expect(before !== undefined).assertTrue()
      if (before !== undefined) {
        expect(before.bytesSent).assertEqual(50)
      }
      // 会话进行中追加文件：分母增长，整体进度不得回跳
      appendFiles(s.id, [{ fileId: 'f2', fileName: 'b.bin', fileType: 'application/octet-stream', totalBytes: 100 }])
      let after = getSession(s.id)
      expect(after !== undefined).assertTrue()
      if (after !== undefined) {
        expect(after.totalBytes).assertEqual(200)
        expect(after.bytesSent).assertEqual(50)
      }
      resetRegistry()
    })

    it('file_progress_monotonic', 0, () => {
      resetRegistry()
      let s = createSession(makeInput())
      updateFileProgress(s.id, 'f1', 80)
      updateFileProgress(s.id, 'f1', 30) // 迟到的小值不回跳
      let current = getSession(s.id)
      if (current !== undefined) {
        expect(current.files[0].bytesSent).assertEqual(80)
      }
      resetRegistry()
    })

    it('aggregate_activeOnly', 0, () => {
      resetRegistry()
      let done = createSession(makeInput())
      finish(done.id, SessionStage.succeeded)
      let running = createSession(makeInput())
      let snap = getOverallSnapshot(0)
      expect(snap.active).assertTrue()
      expect(snap.sessionCount).assertEqual(1)
      expect(snap.allFinished).assertFalse()
      expect(snap.hasFailure).assertFalse()
      expect(running.id.length > 0).assertTrue()
      resetRegistry()
    })

    it('aggregate_monotonic_percent', 0, () => {
      resetRegistry()
      let a = createSession(makeInput())
      // 先占到 50%
      updateFileProgress(a.id, 'f1', 50)
      let first = getOverallSnapshot(0)
      let second = getOverallSnapshot(90)
      expect(second.percent >= first.percent).assertTrue()
      resetRegistry()
    })

    it('reclaim_window_successVsFailure', 0, () => {
      expect(reclaimDelayMs(SessionStage.succeeded)).assertEqual(SUCCESS_VISIBLE_MS)
      expect(reclaimDelayMs(SessionStage.failed)).assertEqual(FAILURE_VISIBLE_MS)
      expect(reclaimDelayMs(SessionStage.cancelled)).assertEqual(FAILURE_VISIBLE_MS)
    })

    it('query_filter_byProtocolAndFlow', 0, () => {
      resetRegistry()
      createSession(makeInput())
      let inbound: SessionCreateInput = {
        protocolKey: 'other',
        protocolSessionId: 'p2',
        dataFlow: SessionDataFlow.inbound,
        initiatedBy: SessionInitiator.remote,
        peer: emptyPeer(),
        files: [],
        capabilities: defaultCapabilities()
      }
      createSession(inbound)
      let filter: SessionFilter = { protocolKey: 'other' }
      expect(querySessions(filter).length).assertEqual(1)
      let flowFilter: SessionFilter = { dataFlow: SessionDataFlow.inbound }
      expect(querySessions(flowFilter).length).assertEqual(1)
      expect(querySessions().length).assertEqual(2)
      resetRegistry()
    })

    it('derive_overall_allTerminal', 0, () => {
      resetRegistry()
      let s = createSession(makeInput())
      finish(s.id, SessionStage.succeeded)
      updateFileProgress(s.id, 'f1', 100)
      let list: Array<TransferSession> = []
      let current = getSession(s.id)
      if (current !== undefined) {
        list.push(current)
      }
      let snap = deriveOverall(list, 0)
      expect(snap.active).assertFalse()
      expect(snap.allFinished).assertTrue()
      resetRegistry()
    })

    it('stage_helpers', 0, () => {
      expect(isTerminalStage(SessionStage.active)).assertFalse()
      expect(isTerminalStage(SessionStage.succeeded)).assertTrue()
      expect(outcomeForStage(SessionStage.succeeded)).assertEqual(SessionHistoryOutcome.succeeded)
      expect(outcomeForStage(SessionStage.active)).assertEqual(undefined)
    })

    it('recompute_totals_sumsFiles', 0, () => {
      resetRegistry()
      let s = createSession(makeInput())
      updateFileProgress(s.id, 'f1', 25)
      let current = getSession(s.id)
      if (current !== undefined) {
        recomputeTotals(current)
        expect(current.totalBytes).assertEqual(100)
        expect(current.bytesSent).assertEqual(25)
      }
      resetRegistry()
    })
  })
}
