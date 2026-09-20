import { describe, it, expect, beforeAll } from '@ohos/hypium'
import {
  buildHistoryEntry,
  clearSessionHistory,
  getSessionHistory,
  resetSessionHistoryCache
} from '../../../../main/ets/service/transfer/SessionHistoryStore'
import {
  SESSION_HISTORY_CAPACITY,
  SESSION_HISTORY_SCHEMA_VERSION,
  SessionHistoryEntry,
  SessionHistoryFile,
  migrateHistoryFile,
  queryHistory,
  trimHistory,
  upsertHistory
} from '../../../../main/ets/model/transfer/SessionHistory'
import {
  SessionCreateInput,
  SessionDataFlow,
  SessionInitiator,
  SessionHistoryOutcome,
  SessionStage,
  defaultCapabilities,
  emptyPeer
} from '../../../../main/ets/model/transfer/TransferSession'
import {
  createSession,
  finish,
  getSession,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import { preferencesUtil } from '../../../../main/ets/utils/PreferencesUtil'
import { getTestAppContext } from '../helper/TestContext'

function entry(id: string, finishedAt: number): SessionHistoryEntry {
  return {
    sessionId: id,
    protocolKey: 'test',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peerName: 'peer',
    fileCount: 1,
    totalBytes: 10,
    outcome: SessionHistoryOutcome.succeeded,
    startedAt: finishedAt - 5,
    finishedAt: finishedAt,
    schemaVersion: SESSION_HISTORY_SCHEMA_VERSION
  }
}

function terminalInput(): SessionCreateInput {
  return {
    protocolKey: 'test',
    protocolSessionId: 'p-cache',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: emptyPeer(),
    files: [{ fileId: 'f', fileName: 'x', fileType: 'text/plain', totalBytes: 4 }],
    capabilities: defaultCapabilities()
  }
}

export default function SessionHistoryStoreTest() {
  describe('SessionHistoryStoreTest', () => {
    beforeAll(() => {
      // 初始化偏好存储（测试环境未走 App 主流程，preferences 未初始化；
      // 内存缓存与落盘一致性用例依赖它）
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        preferencesUtil.init(ctx)
      }
    })
    it('trim_keepsNewest', 0, () => {
      let list: Array<SessionHistoryEntry> = []
      for (let i = 0; i < 5; i++) {
        list.push(entry('s' + i, i))
      }
      let trimmed = trimHistory(list, 3)
      expect(trimmed.length).assertEqual(3)
      expect(trimmed[0].sessionId).assertEqual('s2')
      expect(trimmed[2].sessionId).assertEqual('s4')
    })

    it('trim_noopUnderCapacity', 0, () => {
      let list: Array<SessionHistoryEntry> = [entry('a', 1)]
      expect(trimHistory(list, 10).length).assertEqual(1)
    })

    it('upsert_idempotentById', 0, () => {
      let list: Array<SessionHistoryEntry> = [entry('a', 1)]
      let updated = upsertHistory(list, entry('a', 9))
      expect(updated.length).assertEqual(1)
      expect(updated[0].finishedAt).assertEqual(9)
      let appended = upsertHistory(updated, entry('b', 3))
      expect(appended.length).assertEqual(2)
    })

    it('query_filtersAndSortsDesc', 0, () => {
      let list: Array<SessionHistoryEntry> = [entry('a', 1), entry('b', 5), entry('c', 3)]
      let result = queryHistory(list)
      expect(result[0].sessionId).assertEqual('b')
      expect(result[2].sessionId).assertEqual('a')
      let filtered = queryHistory(list, { protocolKey: 'none' })
      expect(filtered.length).assertEqual(0)
    })

    it('migrate_fillsSchemaVersion', 0, () => {
      let legacy: SessionHistoryFile = { schemaVersion: 0, entries: [entry('a', 1)] }
      let migrated = migrateHistoryFile(legacy)
      expect(migrated.schemaVersion).assertEqual(SESSION_HISTORY_SCHEMA_VERSION)
      expect(migrated.entries[0].schemaVersion).assertEqual(SESSION_HISTORY_SCHEMA_VERSION)
    })

    it('migrate_currentVersion_noop', 0, () => {
      let file: SessionHistoryFile = { schemaVersion: SESSION_HISTORY_SCHEMA_VERSION, entries: [] }
      expect(migrateHistoryFile(file).schemaVersion).assertEqual(SESSION_HISTORY_SCHEMA_VERSION)
    })

    it('build_entry_onlyForTerminal', 0, () => {
      resetRegistry()
      let input: SessionCreateInput = {
        protocolKey: 'test',
        protocolSessionId: 'p',
        dataFlow: SessionDataFlow.inbound,
        initiatedBy: SessionInitiator.remote,
        peer: emptyPeer(),
        files: [{ fileId: 'f', fileName: 'x', fileType: 'text/plain', totalBytes: 4 }],
        capabilities: defaultCapabilities()
      }
      let s = createSession(input)
      // 非终态不归档
      expect(buildHistoryEntry(s)).assertEqual(undefined)
      finish(s.id, SessionStage.declined)
      let current = getSession(s.id)
      expect(current !== undefined).assertTrue()
      if (current !== undefined) {
        let built = buildHistoryEntry(current)
        expect(built !== undefined).assertTrue()
        if (built !== undefined) {
          expect(built.outcome).assertEqual(SessionHistoryOutcome.declined)
          expect(built.fileCount).assertEqual(1)
        }
      }
      resetRegistry()
    })

    it('capacity_constantPositive', 0, () => {
      expect(SESSION_HISTORY_CAPACITY > 0).assertTrue()
    })

    it('memory_authority_readsMemoryAndReloadsFromPreferences', 0, () => {
      resetRegistry()
      resetSessionHistoryCache()
      clearSessionHistory()
      expect(getSessionHistory().length).assertEqual(0)

      // 归档一个终态会话：写入后内存权威列表立即可读
      let s = createSession(terminalInput())
      finish(s.id, SessionStage.succeeded)
      expect(getSessionHistory().length).assertEqual(1)

      // 失效缓存后从偏好存储重新加载，持久化结果与内存一致
      resetSessionHistoryCache()
      expect(getSessionHistory().length).assertEqual(1)
      expect(getSessionHistory()[0].sessionId).assertEqual(s.id)

      // 清空同步更新内存与持久化；再次失效后仍为空
      clearSessionHistory()
      expect(getSessionHistory().length).assertEqual(0)
      resetSessionHistoryCache()
      expect(getSessionHistory().length).assertEqual(0)

      resetRegistry()
    })
  })
}
