import { describe, it, expect } from '@ohos/hypium'
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
  getActiveCount,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  collectActiveSessionIds,
  filterBySource,
  groupSessions,
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
  })
}
