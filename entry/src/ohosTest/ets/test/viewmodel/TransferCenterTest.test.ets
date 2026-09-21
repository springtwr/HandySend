import { describe, it, expect } from '@ohos/hypium'
import {
  SessionCapabilities,
  SessionCreateInput,
  SessionDataFlow,
  SessionHistoryOutcome,
  SessionInitiator,
  SessionStage,
  defaultCapabilities,
  emptyPeer
} from '../../../../main/ets/model/transfer/TransferSession'
import { SessionHistoryEntry } from '../../../../main/ets/model/transfer/SessionHistory'
import {
  createSession,
  finish,
  getActiveCount,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  collectActiveSessionIds,
  filterBySource,
  groupSessions,
  historyEntryRow,
  liveSessionRow,
  mergeSessionRows,
  rowHasByteProgress,
  rowIsTerminal,
  rowStage,
  sessionSourceKey,
  TransferCenterGroups
} from '../../../../main/ets/viewmodel/TransferCenterViewModel'

function input(protocolKey: string, protocolSessionId: string): SessionCreateInput {
  return {
    protocolKey: protocolKey,
    protocolSessionId: protocolSessionId,
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: emptyPeer(),
    files: [],
    capabilities: defaultCapabilities()
  }
}

function historyEntry(sessionId: string, finishedAt: number): SessionHistoryEntry {
  return {
    sessionId: sessionId,
    protocolKey: 'localsend-send',
    protocolSessionId: 'p',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peerName: 'peer',
    peerFingerprint: '',
    peerIp: '',
    peerDeviceType: '',
    peerDeviceModel: '',
    files: [],
    fileCount: 0,
    totalBytes: 0,
    outcome: SessionHistoryOutcome.succeeded,
    errorMessage: '',
    errorCode: '',
    startedAt: finishedAt - 10,
    finishedAt: finishedAt,
    durationMs: 10,
    averageSpeedBps: 0,
    peakSpeedBps: 0,
    timeline: [],
    localAlias: '',
    localIp: '',
    localInterfaceName: '',
    schemaVersion: 2
  }
}

function withByteProgress(hasProgress: boolean): SessionCapabilities {
  let caps = defaultCapabilities()
  caps.hasByteProgress = hasProgress
  return caps
}

export default function TransferCenterTest() {
  describe('TransferCenterTest', () => {
    it('sourceKey_derivedFromProtocolKey', 0, () => {
      expect(sessionSourceKey('localsend-send')).assertEqual('localsend')
      expect(sessionSourceKey('mta-receive')).assertEqual('mta')
      expect(sessionSourceKey('web-download')).assertEqual('web')
      expect(sessionSourceKey('plain')).assertEqual('plain')
    })

    it('filterBySource_matchesPrefix', 0, () => {
      resetRegistry()
      let a = createSession(input('localsend-send', 'a'))
      let b = createSession(input('mta-send', 'b'))
      let all = [a, b]
      let filtered = filterBySource(all, 'mta')
      expect(filtered.length).assertEqual(1)
      expect(filterBySource(all, '').length).assertEqual(2)
      resetRegistry()
    })

    it('groupSessions_activePendingTerminal', 0, () => {
      resetRegistry()
      let a = createSession(input('localsend-send', 'a'))
      let pendingInput = input('localsend-receive', 'b')
      pendingInput.stage = SessionStage.awaitingConfirmation
      let b = createSession(pendingInput)
      let c = createSession(input('web-download', 'c'))
      finish(c.id, SessionStage.failed)

      let groups: TransferCenterGroups = groupSessions([a, b, c])
      expect(groups.active.length).assertEqual(1)
      expect(groups.pending.length).assertEqual(1)
      expect(groups.terminal.length).assertEqual(1)
      resetRegistry()
    })

    it('collectActiveIds_excludesTerminal', 0, () => {
      resetRegistry()
      let a = createSession(input('localsend-send', 'a'))
      let b = createSession(input('mta-send', 'b'))
      let c = createSession(input('web-download', 'c'))
      finish(c.id, SessionStage.succeeded)
      let ids = collectActiveSessionIds([a, b, c])
      expect(ids.length).assertEqual(2)
      expect(ids.indexOf(a.id) >= 0).assertTrue()
      expect(ids.indexOf(b.id) >= 0).assertTrue()
      expect(ids.indexOf(c.id) < 0).assertTrue()
      resetRegistry()
    })

    it('activeCount_tracksNonTerminal', 0, () => {
      resetRegistry()
      let a = createSession(input('localsend-send', 'a'))
      expect(getActiveCount()).assertEqual(1)
      finish(a.id, SessionStage.cancelled)
      expect(getActiveCount()).assertEqual(0)
      resetRegistry()
    })

    it('liveRow_reflectsTerminalWithoutRebuild', 0, () => {
      resetRegistry()
      let s = createSession(input('localsend-send', 'a'))
      let row = liveSessionRow(s)
      // 实时行直接绑定会话对象：未重建行模型即可反映后续状态变化（同源同口径）
      expect(rowIsTerminal(row)).assertFalse()
      expect(rowStage(row)).assertEqual(SessionStage.active)
      finish(s.id, SessionStage.succeeded)
      expect(rowIsTerminal(row)).assertTrue()
      expect(rowStage(row)).assertEqual(SessionStage.succeeded)
      resetRegistry()
    })

    it('liveRow_byteProgressFollowsSessionCapability', 0, () => {
      resetRegistry()
      let textInput = input('localsend-send', 'text')
      textInput.capabilities = withByteProgress(false)
      let textSession = createSession(textInput)
      expect(rowHasByteProgress(liveSessionRow(textSession))).assertFalse()

      let fileInput = input('localsend-send', 'file')
      fileInput.capabilities = withByteProgress(true)
      fileInput.files = [{ fileId: 'f', fileName: 'a.bin', fileType: '', totalBytes: 100 }]
      let fileSession = createSession(fileInput)
      expect(rowHasByteProgress(liveSessionRow(fileSession))).assertTrue()
      resetRegistry()
    })

    it('merge_dedupesBySessionId_keepsLiveRow', 0, () => {
      resetRegistry()
      let s = createSession(input('localsend-send', 'a'))
      finish(s.id, SessionStage.failed)
      let live = [liveSessionRow(s)]
      let history = [historyEntryRow(historyEntry(s.id, Date.now()))]
      let merged = mergeSessionRows(live, history)
      expect(merged.length).assertEqual(1)
      // 去重保留实时行：状态取自实时会话而非历史台账
      expect(merged[0].session !== undefined).assertTrue()
      expect(rowStage(merged[0])).assertEqual(SessionStage.failed)
      resetRegistry()
    })
  })
}
