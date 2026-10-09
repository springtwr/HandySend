import { describe, it, expect, beforeAll } from '@ohos/hypium'
import {
  buildHistoryEntry,
  clearSessionHistory,
  getSessionHistory,
  isSameEntries,
  removeSessionHistoryByIds,
  resetSessionHistoryCache
} from '../../../../main/ets/service/transfer/SessionHistoryStore'
import {
  SESSION_HISTORY_SCHEMA_VERSION,
  SESSION_HISTORY_TIMELINE_CAPACITY,
  SessionHistoryEntry,
  SessionHistoryFile,
  SessionHistoryFileEntry,
  boundTimeline,
  collectSelfBuiltFilePaths,
  emptyHistoryFile,
  isSelfBuiltFilePath,
  persistedTimelineOf,
  queryHistory,
  removeHistoryByIds,
  sanitizeHistory,
  trimHistory,
  upsertHistory
} from '../../../../main/ets/model/transfer/SessionHistory'
import {
  HISTORY_SEGMENT_SIZE,
  RECEIVE_HISTORY_CAPACITY,
  SESSION_HISTORY_CAPACITY,
  SESSION_HISTORY_SEGMENT_COUNT
} from '../../../../main/ets/model/HistoryCapacity'
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
import { initAllPreferences, sessionHistoryPreferencesUtil } from '../../../../main/ets/utils/PreferencesUtil'
import { segmentKey } from '../../../../main/ets/model/HistorySegments'
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

/** 构造携带逐文件路径的历史条目（path 可为 undefined 模拟旧条目缺省）。 */
function entryWithPaths(id: string, finishedAt: number,
  paths: Array<string | undefined>): SessionHistoryEntry {
  let result: SessionHistoryEntry = cleanEntry(id, finishedAt, [1])
  let files: Array<SessionHistoryFileEntry> = []
  for (let i = 0; i < paths.length; i++) {
    let file: SessionHistoryFileEntry = {
      fileId: 'f' + i,
      fileName: 'x' + i,
      fileType: 'text/plain',
      size: 1,
      stage: SessionFileStage.completed,
      checksum: ''
    }
    if (paths[i] !== undefined) {
      file.path = paths[i]
    }
    files.push(file)
  }
  result.files = files
  result.fileCount = files.length
  return result
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

    // ── 保留容量常量：上限是持久化行为的一部分，锁定取值避免无声变更 ──

    it('capacity_constants_are_pinned', 0, () => {
      expect(SESSION_HISTORY_CAPACITY).assertEqual(2000)
      expect(RECEIVE_HISTORY_CAPACITY).assertEqual(2000)
      expect(SESSION_HISTORY_SEGMENT_COUNT).assertEqual(8)
      expect(HISTORY_SEGMENT_SIZE).assertEqual(250)
      // 归档条目的 schema 版本参与持久化契约，变更需显式确认读侧兼容性
      expect(SESSION_HISTORY_SCHEMA_VERSION).assertEqual(4)
    })

    // ── 分段存储：容量为段大小整数倍，裁剪只丢弃最旧整段 ──

    it('segments_capacityIsMultipleOfSegmentSize', 0, () => {
      // 容量必须可由整段表达，否则裁剪需段内处理，破坏「只重写末段」的代价假设
      expect(SESSION_HISTORY_CAPACITY % HISTORY_SEGMENT_SIZE).assertEqual(0)
      expect(SESSION_HISTORY_CAPACITY / HISTORY_SEGMENT_SIZE).assertEqual(SESSION_HISTORY_SEGMENT_COUNT)
    })

    it('segments_survivesColdReloadAcrossSegmentBoundary', 0, () => {
      clearSessionHistory()
      // 条目数跨过段边界：强制落盘后失效内存缓存，由偏好存储重新读回
      let total = HISTORY_SEGMENT_SIZE + 3
      for (let i = 0; i < total; i++) {
        let s = createSession(terminalInput())
        finish(s.id, SessionStage.succeeded)
      }
      expect(getSessionHistory().length).assertEqual(total)
      resetSessionHistoryCache()
      let reloaded = getSessionHistory()
      expect(reloaded.length).assertEqual(total)
      // getSessionHistory 按时间倒序返回（展示口径）：分段拼接不引入重复或丢失
      let seen: Set<string> = new Set()
      for (let i = 0; i < reloaded.length; i++) {
        expect(seen.has(reloaded[i].sessionId)).assertFalse()
        seen.add(reloaded[i].sessionId)
      }
      for (let i = 1; i < reloaded.length; i++) {
        expect(reloaded[i].finishedAt <= reloaded[i - 1].finishedAt).assertTrue()
      }
      clearSessionHistory()
    })

    it('segments_writesSegmentKeysNotLegacyKey', 0, () => {
      clearSessionHistory()
      let s = createSession(terminalInput())
      finish(s.id, SessionStage.succeeded)
      expect(getSessionHistory().length).assertEqual(1)
      // 落盘形态为段键；老单键不再写入
      expect(sessionHistoryPreferencesUtil.has(segmentKey('transferSessionHistory', 0))).assertTrue()
      expect(sessionHistoryPreferencesUtil.has('transferSessionHistory')).assertFalse()
      clearSessionHistory()
    })

    it('segments_clearRemovesAllSegmentKeys', 0, () => {
      clearSessionHistory()
      let total = HISTORY_SEGMENT_SIZE + 1
      for (let i = 0; i < total; i++) {
        let s = createSession(terminalInput())
        finish(s.id, SessionStage.succeeded)
      }
      expect(sessionHistoryPreferencesUtil.has(segmentKey('transferSessionHistory', 0))).assertTrue()
      // 清除必须删键而非写空段：残留段键会在下次读取时拼接回来使已清空的历史重现
      clearSessionHistory()
      for (let i = 0; i < SESSION_HISTORY_SEGMENT_COUNT; i++) {
        expect(sessionHistoryPreferencesUtil.has(segmentKey('transferSessionHistory', i))).assertFalse()
      }
      resetSessionHistoryCache()
      expect(getSessionHistory().length).assertEqual(0)
    })

    it('segments_clearThenReload_staysEmpty', 0, () => {
      clearSessionHistory()
      for (let i = 0; i < 3; i++) {
        let s = createSession(terminalInput())
        finish(s.id, SessionStage.succeeded)
      }
      clearSessionHistory()
      resetSessionHistoryCache()
      expect(getSessionHistory().length).assertEqual(0)
    })

    it('segments_staleLegacyKey_removedWhenSegmentsExist', 0, () => {
      clearSessionHistory()
      let s = createSession(terminalInput())
      finish(s.id, SessionStage.succeeded)
      expect(getSessionHistory().length).assertEqual(1)
      // 模拟崩溃窗口残留：分段已存在时老键仍在（迁移写入后、删老键前退出）
      sessionHistoryPreferencesUtil.setObject('transferSessionHistory', emptyHistoryFile())
      expect(sessionHistoryPreferencesUtil.has('transferSessionHistory')).assertTrue()
      // 下次读取以段为准并顺手删除老键，避免清空后老键复活历史
      resetSessionHistoryCache()
      expect(getSessionHistory().length).assertEqual(1)
      expect(sessionHistoryPreferencesUtil.has('transferSessionHistory')).assertFalse()
      expect(sessionHistoryPreferencesUtil.has(segmentKey('transferSessionHistory', 0))).assertTrue()
      clearSessionHistory()
    })

    it('segments_clearRemovesStaleLegacyKey', 0, () => {
      clearSessionHistory()
      let s = createSession(terminalInput())
      finish(s.id, SessionStage.succeeded)
      sessionHistoryPreferencesUtil.setObject('transferSessionHistory', emptyHistoryFile())
      // 清空删段的同时删除老键：否则段键清空后的下次读取会误命中老键
      clearSessionHistory()
      expect(sessionHistoryPreferencesUtil.has('transferSessionHistory')).assertFalse()
      resetSessionHistoryCache()
      expect(getSessionHistory().length).assertEqual(0)
    })

    it('segments_removeAcrossSegments_persists', 0, () => {
      clearSessionHistory()
      let ids: string[] = []
      let total = HISTORY_SEGMENT_SIZE + 2
      for (let i = 0; i < total; i++) {
        let s = createSession(terminalInput())
        finish(s.id, SessionStage.succeeded)
        ids.push(s.id)
      }
      // 删除跨越段边界的条目：变更区间覆盖多段，须全部落盘
      expect(removeSessionHistoryByIds([ids[0], ids[HISTORY_SEGMENT_SIZE]])).assertEqual(2)
      resetSessionHistoryCache()
      let reloaded = getSessionHistory()
      expect(reloaded.length).assertEqual(total - 2)
      for (let i = 0; i < reloaded.length; i++) {
        expect(reloaded[i].sessionId === ids[0]).assertFalse()
        expect(reloaded[i].sessionId === ids[HISTORY_SEGMENT_SIZE]).assertFalse()
      }
      clearSessionHistory()
    })

    it('segments_migrateFromLegacySingleKey', 0, () => {
      clearSessionHistory()
      // 构造分段之前的历史：单键 JSON 数组
      let legacy: Array<SessionHistoryEntry> = [cleanEntry('legacy-1', 10, [5]),
        cleanEntry('legacy-2', 20, [7])]
      let legacyFile: SessionHistoryFile = {
        schemaVersion: SESSION_HISTORY_SCHEMA_VERSION,
        entries: legacy
      }
      sessionHistoryPreferencesUtil.setObject('transferSessionHistory', legacyFile)
      expect(sessionHistoryPreferencesUtil.has('transferSessionHistory')).assertTrue()
      // 读取即触发一次性迁移：数据转为段键，老键删除
      resetSessionHistoryCache()
      let loaded = getSessionHistory()
      expect(loaded.length).assertEqual(2)
      // getSessionHistory 按时间倒序返回：legacy-2（finishedAt 20）在前
      expect(loaded[0].sessionId).assertEqual('legacy-2')
      expect(loaded[1].sessionId).assertEqual('legacy-1')
      expect(sessionHistoryPreferencesUtil.has('transferSessionHistory')).assertFalse()
      expect(sessionHistoryPreferencesUtil.has(segmentKey('transferSessionHistory', 0))).assertTrue()
      // 迁移幂等：再次失效缓存重读，数据一致且老键不再出现
      resetSessionHistoryCache()
      expect(getSessionHistory().length).assertEqual(2)
      clearSessionHistory()
    })

    it('segments_migrationIsIdempotentAcrossReloads', 0, () => {
      clearSessionHistory()
      let legacy: Array<SessionHistoryEntry> = [cleanEntry('once-1', 10, [5])]
      let legacyFile: SessionHistoryFile = {
        schemaVersion: SESSION_HISTORY_SCHEMA_VERSION,
        entries: legacy
      }
      sessionHistoryPreferencesUtil.setObject('transferSessionHistory', legacyFile)
      resetSessionHistoryCache()
      expect(getSessionHistory().length).assertEqual(1)
      resetSessionHistoryCache()
      expect(getSessionHistory().length).assertEqual(1)
      resetSessionHistoryCache()
      expect(getSessionHistory().length).assertEqual(1)
      clearSessionHistory()
    })

    it('segments_emptyStore_noMigration', 0, () => {
      clearSessionHistory()
      resetSessionHistoryCache()
      expect(getSessionHistory().length).assertEqual(0)
      expect(sessionHistoryPreferencesUtil.has('transferSessionHistory')).assertFalse()
    })

    // ── 清洗前后等价判定：驱动「仅在清洗确有改动时回写」的落盘分支 ──

    it('isSameEntries_identicalRefs_true', 0, () => {
      let list: Array<SessionHistoryEntry> = [entry('a', 1), entry('b', 2)]
      expect(isSameEntries(list, list.slice())).assertTrue()
    })

    it('isSameEntries_lengthDiff_false', 0, () => {
      let list: Array<SessionHistoryEntry> = [entry('a', 1)]
      expect(isSameEntries(list, [entry('a', 1), entry('b', 2)])).assertFalse()
    })

    it('isSameEntries_cleanEntries_notRewritten', 0, () => {
      // 聚合字段与逐文件清单一致的条目：清洗保持原引用，判定为「无改动」不触发回写
      let list: Array<SessionHistoryEntry> = [cleanEntry('a', 1, [10]), cleanEntry('b', 2, [4, 6])]
      let sanitized: Array<SessionHistoryEntry> = sanitizeHistory(list)
      expect(sanitized.length).assertEqual(2)
      expect(isSameEntries(list, sanitized)).assertTrue()
    })

    it('isSameEntries_rebuiltAggregates_false', 0, () => {
      // 聚合字段与逐文件清单不一致：清洗重建聚合字段产生新引用，须识别为「已改动」
      let list: Array<SessionHistoryEntry> = [cleanEntry('a', 1, [10])]
      list[0].totalBytes = 999
      list[0].fileCount = 7
      let sanitized: Array<SessionHistoryEntry> = sanitizeHistory(list)
      expect(sanitized.length).assertEqual(1)
      expect(sanitized[0].totalBytes).assertEqual(10)
      expect(sanitized[0].fileCount).assertEqual(1)
      expect(isSameEntries(list, sanitized)).assertFalse()
    })

    it('isSameEntries_droppedDirtyEntry_false', 0, () => {
      // entry() 构造的是空清单但 fileCount>0 的脏条目：清洗直接剔除，条数变化即已改动
      let list: Array<SessionHistoryEntry> = [entry('a', 1)]
      let sanitized: Array<SessionHistoryEntry> = sanitizeHistory(list)
      expect(sanitized.length).assertEqual(0)
      expect(isSameEntries(list, sanitized)).assertFalse()
    })

    it('isSameEntries_emptyArrays_true', 0, () => {
      expect(isSameEntries([], [])).assertTrue()
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

    it('isSelfBuiltFilePath_onlyMatchesSendTextDir', 0, () => {
      let dir = '/data/.../files/text_send/'
      let recvDir = '/data/.../files/text_recv/'
      // 自建发送文本目录内的文件：可随记录删除
      expect(isSelfBuiltFilePath(dir + 'text_1.txt', dir)).assertTrue()
      // 自建接收文本目录内的文件：同样可随记录删除
      expect(isSelfBuiltFilePath(recvDir + 'text_1.txt', dir, recvDir)).assertTrue()
      // 未传入接收目录时接收文本目录不命中（旧调用口径不变）
      expect(isSelfBuiltFilePath(recvDir + 'text_1.txt', dir)).assertFalse()
      // picker 选中的用户原始文件：绝不删除
      expect(isSelfBuiltFilePath('file://media/Photo/100001.jpg', dir, recvDir)).assertFalse()
      expect(isSelfBuiltFilePath('/storage/Users/me/Documents/report.pdf', dir, recvDir)).assertFalse()
      // 接收落盘文件：删除权归文件接收历史页，此处不删
      expect(isSelfBuiltFilePath('/storage/Users/me/Download/HandySend/a.png', dir, recvDir)).assertFalse()
      // 目录前缀相同但仅字符前缀（无斜杠边界）不算命中，避免误判同级目录
      expect(isSelfBuiltFilePath('/data/.../files/text_send_backup/a.txt', dir, recvDir)).assertFalse()
      expect(isSelfBuiltFilePath('/data/.../files/text_recv_backup/a.txt', dir, recvDir)).assertFalse()
      // 路径缺省 / 空串 / 应用上下文不可得：保守判为不可删
      expect(isSelfBuiltFilePath(undefined, dir, recvDir)).assertFalse()
      expect(isSelfBuiltFilePath('', dir, recvDir)).assertFalse()
      expect(isSelfBuiltFilePath(dir + 'a.txt', '')).assertFalse()
    })

    it('collectSelfBuiltFilePaths_keepsOnlySelfBuilt_deduped', 0, () => {
      let dir = '/data/.../files/text_send/'
      let recvDir = '/data/.../files/text_recv/'
      let list: Array<SessionHistoryEntry> = [
        entryWithPaths('a', 1, [dir + 't1.txt']),
        // 混合：自建文本 + picker 原始文件 + 接收落盘文件
        entryWithPaths('b', 2, ['file://media/Photo/1.jpg', dir + 't2.txt',
          '/storage/Users/me/Download/HandySend/x.png']),
        // 同一路径重复出现只保留首次
        entryWithPaths('c', 3, [dir + 't1.txt']),
        // 旧条目无 path
        entryWithPaths('d', 4, [undefined]),
        // 接收文本目录文件同样汇集
        entryWithPaths('e', 5, [recvDir + 'r1.txt'])
      ]
      let paths: Array<string> = collectSelfBuiltFilePaths(list, dir, recvDir)
      expect(paths.length).assertEqual(3)
      expect(paths[0]).assertEqual(dir + 't1.txt')
      expect(paths[1]).assertEqual(dir + 't2.txt')
      expect(paths[2]).assertEqual(recvDir + 'r1.txt')
      // 应用上下文不可得时一个都不删
      expect(collectSelfBuiltFilePaths(list, '').length).assertEqual(0)
    })

    it('removeByIds_dropsMatched_keepsOrderAndUnmatched', 0, () => {
      let list: Array<SessionHistoryEntry> = [entry('a', 1), entry('b', 5), entry('c', 3)]
      let removed = removeHistoryByIds(list, ['a', 'c'])
      // 命中即剔除，未命中条目保持原有相对顺序
      expect(removed.length).assertEqual(1)
      expect(removed[0].sessionId).assertEqual('b')
      // 无命中与空集合：原样返回，不改变内容
      expect(removeHistoryByIds(list, ['none']).length).assertEqual(3)
      expect(removeHistoryByIds(list, []).length).assertEqual(3)
    })

    it('removeSessionHistoryByIds_persistsRemoval', 0, () => {
      clearSessionHistory()
      let session = createSession(terminalInput())
      finish(session.id, SessionStage.succeeded)
      expect(getSessionHistory().length).assertEqual(1)
      expect(removeSessionHistoryByIds([session.id])).assertEqual(1)
      expect(getSessionHistory().length).assertEqual(0)
      // 空集合与重复移除均为无命中：返回 0 且不产生变更
      expect(removeSessionHistoryByIds([])).assertEqual(0)
      expect(removeSessionHistoryByIds([session.id])).assertEqual(0)
      resetRegistry()
      clearSessionHistory()
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

    // ── 落盘形态时间线：剥离逐事件的会话标识与 detail ──

    it('persistedTimelineOf_stripsSessionIdAndDetail', 0, () => {
      let events: Array<SessionTimelineEvent> = [
        { kind: SessionEventKind.created, timestamp: 10, sessionId: 's1', detail: 'localsend' },
        { kind: SessionEventKind.started, timestamp: 20, sessionId: 's1' },
        { kind: SessionEventKind.failed, timestamp: 30, sessionId: 's1', detail: '连接中断' }
      ]
      let persisted = persistedTimelineOf(events)
      expect(persisted.length).assertEqual(3)
      for (let i = 0; i < persisted.length; i++) {
        expect(persisted[i].sessionId).assertEqual('')
        expect(persisted[i].detail).assertEqual(undefined)
      }
      // 展示与读侧实际消费的字段原样保留，顺序不变
      expect(persisted[0].kind).assertEqual(SessionEventKind.created)
      expect(persisted[0].timestamp).assertEqual(10)
      expect(persisted[2].kind).assertEqual(SessionEventKind.failed)
      expect(persisted[2].timestamp).assertEqual(30)
    })

    it('persistedTimelineOf_doesNotMutateSource', 0, () => {
      let events: Array<SessionTimelineEvent> = [
        { kind: SessionEventKind.created, timestamp: 1, sessionId: 's1', detail: 'keep' }
      ]
      persistedTimelineOf(events)
      // 内存中的活跃会话时间线不受影响
      expect(events[0].sessionId).assertEqual('s1')
      expect(events[0].detail).assertEqual('keep')
    })

    it('persistedTimelineOf_empty_staysEmpty', 0, () => {
      expect(persistedTimelineOf([]).length).assertEqual(0)
    })

    it('persistedTimelineOf_shrinksSerializedSize', 0, () => {
      // 剥离的收益随事件数放大：满容量时间线的落盘体积应显著小于内存形态
      let events: Array<SessionTimelineEvent> = []
      for (let i = 0; i < SESSION_HISTORY_TIMELINE_CAPACITY; i++) {
        events.push({ kind: SessionEventKind.started, timestamp: 1700000000000 + i,
          sessionId: 'localsend_1700000000000_42', detail: '一段较长的错误描述文本用于放大体积' })
      }
      let full = JSON.stringify(events).length
      let persisted = JSON.stringify(persistedTimelineOf(events)).length
      expect(persisted < full).assertTrue()
      // 剥离后体积降至约一半以内（仅剩 kind 与 timestamp）
      expect(persisted * 2 < full * 1.5).assertTrue()
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
