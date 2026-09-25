import { describe, it, expect, beforeAll } from '@ohos/hypium'
import {
  buildHistoryEntry,
  clearSessionHistory,
  getSessionHistory,
  resetSessionHistoryCache
} from '../../../../main/ets/service/transfer/SessionHistoryStore'
import {
  SESSION_HISTORY_SCHEMA_VERSION,
  SESSION_HISTORY_TIMELINE_CAPACITY,
  SessionHistoryEntry,
  SessionHistoryFileEntry,
  boundTimeline,
  queryHistory,
  sanitizeHistory,
  trimHistory,
  upsertHistory
} from '../../../../main/ets/model/transfer/SessionHistory'
import {
  SessionCreateInput,
  SessionDataFlow,
  SessionEventKind,
  SessionFileStage,
  SessionHistoryOutcome,
  SessionInitiator,
  SessionStage,
  SessionTimelineEvent,
  defaultCapabilities,
  emptyPeer
} from '../../../../main/ets/model/transfer/TransferSession'
import {
  createSession,
  declineSession,
  finish,
  getSession,
  resetRegistry,
  updateFileProgress
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import { getTestAppContext } from '../helper/TestContext'

function entry(id: string, finishedAt: number): SessionHistoryEntry {
  return {
    sessionId: id,
    protocolKey: 'test',
    protocolSessionId: 'p',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peerName: 'peer',
    peerFingerprint: '',
    peerIp: '',
    peerDeviceType: '',
    peerDeviceModel: '',
    files: [],
    fileCount: 1,
    totalBytes: 10,
    outcome: SessionHistoryOutcome.succeeded,
    errorMessage: '',
    errorCode: '',
    startedAt: finishedAt - 5,
    finishedAt: finishedAt,
    durationMs: 5,
    averageSpeedBps: 0,
    peakSpeedBps: 0,
    timeline: [],
    localAlias: '',
    localIp: '',
    localInterfaceName: '',
    schemaVersion: SESSION_HISTORY_SCHEMA_VERSION
  }
}

/** 构造逐文件清单与聚合字段一致的条目（非脏条目，供去重/自愈用例按源摆放）。 */
function cleanEntry(id: string, finishedAt: number, sizes: Array<number>): SessionHistoryEntry {
  let files: Array<SessionHistoryFileEntry> = []
  let totalBytes: number = 0
  for (let i = 0; i < sizes.length; i++) {
    files.push({
      fileId: 'f' + i,
      fileName: 'x' + i,
      fileType: 'text/plain',
      size: sizes[i],
      stage: SessionFileStage.completed,
      checksum: ''
    })
    totalBytes += sizes[i]
  }
  return {
    sessionId: id,
    protocolKey: 'test',
    protocolSessionId: 'p',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peerName: 'peer',
    peerFingerprint: '',
    peerIp: '',
    peerDeviceType: '',
    peerDeviceModel: '',
    files: files,
    fileCount: files.length,
    totalBytes: totalBytes,
    outcome: SessionHistoryOutcome.succeeded,
    errorMessage: '',
    errorCode: '',
    startedAt: finishedAt - 5,
    finishedAt: finishedAt,
    durationMs: 5,
    averageSpeedBps: 0,
    peakSpeedBps: 0,
    timeline: [],
    localAlias: '',
    localIp: '',
    localInterfaceName: '',
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
    files: [{
      fileId: 'f',
      fileName: 'x',
      fileType: 'text/plain',
      totalBytes: 4
    }],
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
        initAllPreferences(ctx)
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

    it('boundTimeline_capsSize', 0, () => {
      let events: Array<SessionTimelineEvent> = []
      for (let i = 0; i < SESSION_HISTORY_TIMELINE_CAPACITY + 10; i++) {
        events.push({ kind: SessionEventKind.created, timestamp: i, sessionId: 's' })
      }
      let bounded = boundTimeline(events)
      expect(bounded.length).assertEqual(SESSION_HISTORY_TIMELINE_CAPACITY)
      // 保留最近的事件（丢弃最早 10 条）
      expect(bounded[0].timestamp).assertEqual(10)
    })

    it('sanitize_dedupesBySessionIdKeepsNewest', 0, () => {
      // 同一 sessionId 出现多条（历史污染）：仅保留 finishedAt 最新的一条，其余条目保持相对顺序
      let list: Array<SessionHistoryEntry> = [cleanEntry('s', 10, [1]), cleanEntry('s', 5, [1]),
        cleanEntry('t', 3, [1])]
      let sanitized = sanitizeHistory(list)
      expect(sanitized.length).assertEqual(2)
      expect(sanitized[0].sessionId).assertEqual('s')
      expect(sanitized[0].finishedAt).assertEqual(10)
      expect(sanitized[1].sessionId).assertEqual('t')
    })

    it('sanitize_repairsAggregatesFromFiles', 0, () => {
      // 聚合字段与逐文件清单不一致（fileCount/totalBytes 被污染）时以清单为准自愈
      let bad = cleanEntry('s', 10, [7, 13])
      bad.fileCount = 3
      bad.totalBytes = 999
      let sanitized = sanitizeHistory([bad])
      expect(sanitized.length).assertEqual(1)
      expect(sanitized[0].fileCount).assertEqual(2)
      expect(sanitized[0].totalBytes).assertEqual(20)
      expect(sanitized[0].files.length).assertEqual(2)
    })

    it('sanitize_dropsDirtyEntriesWithEmptyFiles', 0, () => {
      // files 为空但 fileCount>0 的脏条目（如被错误标记成多文件的文本会话）不参与展示
      let clean = cleanEntry('s', 10, [5])
      let dirty = entry('d', 8)
      let sanitized = sanitizeHistory([dirty, clean])
      expect(sanitized.length).assertEqual(1)
      expect(sanitized[0].sessionId).assertEqual('s')
    })

    it('build_entry_onlyForTerminal', 0, () => {
      resetRegistry()
      let input: SessionCreateInput = {
        protocolKey: 'test',
        protocolSessionId: 'p',
        dataFlow: SessionDataFlow.inbound,
        initiatedBy: SessionInitiator.remote,
        peer: emptyPeer(),
        files: [{
          fileId: 'f',
          fileName: 'x',
          fileType: 'text/plain',
          totalBytes: 4
        }],
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

    it('build_entry_assemblesV2Fields', 0, () => {
      resetRegistry()
      let input: SessionCreateInput = {
        protocolKey: 'localsend-send',
        protocolSessionId: 'proto-1',
        dataFlow: SessionDataFlow.outbound,
        initiatedBy: SessionInitiator.local,
        peer: {
          displayName: 'Peer',
          ip: '10.0.0.9',
          fingerprint: 'fp-1',
          deviceType: 'mobile',
          badges: ['Model X']
        },
        files: [{
          fileId: 'f1',
          fileName: 'a.bin',
          fileType: 'application/octet-stream',
          totalBytes: 100,
          checksum: 'sha-abc'
        }],
        capabilities: defaultCapabilities()
      }
      let s = createSession(input)
      finish(s.id, SessionStage.succeeded)
      let current = getSession(s.id)
      expect(current !== undefined).assertTrue()
      if (current !== undefined) {
        let built = buildHistoryEntry(current)
        expect(built !== undefined).assertTrue()
        if (built !== undefined) {
          // 对端设备信息
          expect(built.peerName).assertEqual('Peer')
          expect(built.peerFingerprint).assertEqual('fp-1')
          expect(built.peerIp).assertEqual('10.0.0.9')
          expect(built.peerDeviceType).assertEqual('mobile')
          expect(built.peerDeviceModel).assertEqual('Model X')
          // 逐文件清单（含校验和）
          expect(built.files.length).assertEqual(1)
          expect(built.files[0].fileName).assertEqual('a.bin')
          expect(built.files[0].size).assertEqual(100)
          expect(built.files[0].checksum).assertEqual('sha-abc')
          // 时间与耗时
          expect(built.finishedAt >= built.startedAt).assertTrue()
          expect(built.durationMs >= 0).assertTrue()
          // 完整时间线（创建 + 开始 + 完成/终结事件）
          expect(built.timeline.length > 0).assertTrue()
          expect(built.protocolSessionId).assertEqual('proto-1')
          expect(built.schemaVersion).assertEqual(SESSION_HISTORY_SCHEMA_VERSION)
        }
      }
      resetRegistry()
    })

    it('build_entry_durationMs_matchesTimelineScope', 0, () => {
      resetRegistry()
      let s = createSession(terminalInput())
      // 复现偏差场景：start=..00.900, end=..02.100 → 时间线口径差 2 秒 → durationMs 应为 2000
      s.startedAt = 1000000000900
      finish(s.id, SessionStage.succeeded)
      let current = getSession(s.id)
      expect(current !== undefined).assertTrue()
      if (current !== undefined) {
        current.finishedAt = 1000000002100
        let built = buildHistoryEntry(current)
        expect(built !== undefined).assertTrue()
        if (built !== undefined) {
          expect(built.durationMs).assertEqual(2000)
        }
      }
      resetRegistry()
    })

    it('archive_pendingTerminal_paths_writeCorrectOutcome', 0, () => {
      // 待确认会话在拒绝 / 撤回 / 超时三条终结路径下都必须写入历史且结果正确，
      // 保证终态可见窗口结束后用户仍有唯一可进入的条目
      resetRegistry()
      resetSessionHistoryCache()
      clearSessionHistory()

      let declinedInput = terminalInput()
      declinedInput.protocolSessionId = 'p-declined'
      declinedInput.stage = SessionStage.awaitingConfirmation
      let declined = createSession(declinedInput)
      declineSession(declined.id)

      let withdrawnInput = terminalInput()
      withdrawnInput.protocolSessionId = 'p-withdrawn'
      withdrawnInput.stage = SessionStage.awaitingConfirmation
      let withdrawn = createSession(withdrawnInput)
      finish(withdrawn.id, SessionStage.cancelled, '对端撤回', 'withdrawn')

      let timeoutInput = terminalInput()
      timeoutInput.protocolSessionId = 'p-timeout'
      timeoutInput.stage = SessionStage.awaitingConfirmation
      let timeout = createSession(timeoutInput)
      finish(timeout.id, SessionStage.cancelled, '待确认超时', 'pending_timeout')

      let history = getSessionHistory()
      let outcomeById: Map<string, SessionHistoryOutcome> = new Map()
      for (let i = 0; i < history.length; i++) {
        outcomeById.set(history[i].sessionId, history[i].outcome)
      }
      expect(outcomeById.get(declined.id)).assertEqual(SessionHistoryOutcome.declined)
      expect(outcomeById.get(withdrawn.id)).assertEqual(SessionHistoryOutcome.cancelled)
      expect(outcomeById.get(timeout.id)).assertEqual(SessionHistoryOutcome.cancelled)

      resetRegistry()
      resetSessionHistoryCache()
      clearSessionHistory()
    })

    it('archive_failureClass_snapshotMatchesDetail', 0, () => {
      // 失败类终态：逐文件补齐（已完成保持成功、未完成置失败）写进历史快照，
      // 且与详情页读取的实时会话同口径（无等待中/传输中）
      resetRegistry()
      resetSessionHistoryCache()
      clearSessionHistory()
      let input: SessionCreateInput = {
        protocolKey: 'test',
        protocolSessionId: 'p-fail',
        dataFlow: SessionDataFlow.outbound,
        initiatedBy: SessionInitiator.local,
        peer: emptyPeer(),
        files: [
          {
            fileId: 'f1',
            fileName: 'a.bin',
            fileType: 'application/octet-stream',
            totalBytes: 100
          },
          {
            fileId: 'f2',
            fileName: 'b.bin',
            fileType: 'application/octet-stream',
            totalBytes: 100
          }
        ],
        capabilities: defaultCapabilities()
      }
      let s = createSession(input)
      updateFileProgress(s.id, 'f1', 100)
      updateFileProgress(s.id, 'f2', 30)
      finish(s.id, SessionStage.failed, 'boom')

      let entry: SessionHistoryEntry | undefined = undefined
      let history = getSessionHistory()
      for (let i = 0; i < history.length; i++) {
        if (history[i].sessionId === s.id) {
          entry = history[i]
        }
      }
      expect(entry !== undefined).assertTrue()
      if (entry !== undefined) {
        expect(entry.files[0].stage).assertEqual(SessionFileStage.completed)
        expect(entry.files[1].stage).assertEqual(SessionFileStage.failed)
      }
      let live = getSession(s.id)
      expect(live !== undefined).assertTrue()
      if (live !== undefined && entry !== undefined) {
        for (let i = 0; i < live.files.length; i++) {
          expect(live.files[i].stage).assertEqual(entry.files[i].stage)
        }
      }
      resetRegistry()
      resetSessionHistoryCache()
      clearSessionHistory()
    })

    it('archive_cancelledFiles_andPeerMtaBrandId', 0, () => {
      resetRegistry()
      resetSessionHistoryCache()
      clearSessionHistory()
      let input: SessionCreateInput = {
        protocolKey: 'mta-send',
        protocolSessionId: 'p-mta',
        dataFlow: SessionDataFlow.outbound,
        initiatedBy: SessionInitiator.local,
        peer: {
          displayName: 'MtaPeer',
          deviceType: 'mobile',
          badges: [],
          mtaBrandId: 30
        },
        files: [
          {
            fileId: 'f1',
            fileName: 'a.bin',
            fileType: 'application/octet-stream',
            totalBytes: 100
          },
          {
            fileId: 'f2',
            fileName: 'b.bin',
            fileType: 'application/octet-stream',
            totalBytes: 100
          }
        ],
        capabilities: defaultCapabilities()
      }
      let s = createSession(input)
      updateFileProgress(s.id, 'f1', 100)
      updateFileProgress(s.id, 'f2', 40)
      finish(s.id, SessionStage.cancelled)
      let entry: SessionHistoryEntry | undefined = undefined
      let history = getSessionHistory()
      for (let i = 0; i < history.length; i++) {
        if (history[i].sessionId === s.id) {
          entry = history[i]
        }
      }
      expect(entry !== undefined).assertTrue()
      if (entry !== undefined) {
        // MTA 品牌标识随历史归档（历史态设备卡据此渲染品牌图标）
        expect(entry.peerMtaBrandId).assertEqual(30)
        // 取消后的逐文件终态归档：已完成保持、未完成置为已取消
        expect(entry.files[0].stage).assertEqual(SessionFileStage.completed)
        expect(entry.files[1].stage).assertEqual(SessionFileStage.cancelled)
      }
      resetRegistry()
      resetSessionHistoryCache()
      clearSessionHistory()
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
