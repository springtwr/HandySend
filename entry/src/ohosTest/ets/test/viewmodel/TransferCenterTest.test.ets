import { describe, it, expect, beforeAll } from '@ohos/hypium'
import {
  SessionCapabilities,
  SessionCreateInput,
  SessionDataFlow,
  SessionDisplayDescriptor,
  SessionFile,
  SessionFileStage,
  SessionHistoryOutcome,
  SessionInitiator,
  SessionStage,
  defaultCapabilities,
  emptyPeer
} from '../../../../main/ets/model/transfer/TransferSession'
import { SessionHistoryEntry, SessionHistoryFileEntry } from '../../../../main/ets/model/transfer/SessionHistory'
import {
  createSession,
  finish,
  getActiveCount,
  getSession,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import { SessionAdapter, registerAdapter } from '../../../../main/ets/service/transfer/adapters/SessionAdapter'
import { resetSessionHistoryCache } from '../../../../main/ets/service/transfer/SessionHistoryStore'
import {
  CenterRow,
  collectActiveSessionIds,
  dedupeSessionRows,
  describeCenterRows,
  groupSessions,
  historyEntryRow,
  liveSessionRow,
  mergeSessionRows,
  ROW_EMPTY,
  ROW_SESSION,
  rowAwaitingConfirm,
  rowHasByteProgress,
  rowIsTerminal,
  rowIsTextSession,
  rowStage,
  sessionSourceKey,
  SessionRowModel,
  sortSessionRows,
  isSingleTextFileTask,
  TransferCenterGroups,
  TransferCenterViewModel,
  RowValidationResult,
  validateSessionRows
} from '../../../../main/ets/viewmodel/TransferCenterViewModel'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import { getTestAppContext } from '../helper/TestContext'

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

/** 统计视图中指向指定会话的行数（用于断言同一会话渲染条数）。 */
function countRowsForSession(vm: TransferCenterViewModel, sessionId: string): number {
  let matches = 0
  for (let i = 0; i < vm.rows.length; i++) {
    let row = vm.rows[i].session
    if (row !== undefined && row.sessionId === sessionId) {
      matches++
    }
  }
  return matches
}

/** 把行模型包装为列表条目行（与组装行序列同构）。 */
function centerRowOf(row: SessionRowModel): CenterRow {
  return { key: row.key, kind: ROW_SESSION, session: row }
}

/** 统计行序列描述中的行标记数（每个行标记形如「[索引]」）。 */
function describedRowCount(text: string): number {
  return text.split('[').length - 1
}

/** 构造带逐文件清单的会话创建输入（文件数量与类型可控）。 */
function inputWithFiles(protocolSessionId: string, files: Array<SessionFile>): SessionCreateInput {
  let createInput = input('localsend-send', protocolSessionId)
  createInput.files = files
  return createInput
}

/** 构造会话逐文件条目。 */
function sessionFileOf(fileName: string, fileType: string): SessionFile {
  let file = new SessionFile()
  file.fileId = fileName
  file.fileName = fileName
  file.fileType = fileType
  file.totalBytes = 1
  return file
}

/** 构造带逐文件清单的历史条目（聚合字段与清单一致）。 */
function historyEntryWithFiles(sessionId: string,
  files: Array<SessionHistoryFileEntry>): SessionHistoryEntry {
  let entry = historyEntry(sessionId, Date.now())
  entry.files = files
  entry.fileCount = files.length
  return entry
}

/** 构造历史逐文件条目。 */
function historyFileOf(fileName: string, fileType: string): SessionHistoryFileEntry {
  return {
    fileId: fileName,
    fileName: fileName,
    fileType: fileType,
    size: 1,
    stage: SessionFileStage.completed,
    checksum: ''
  }
}

/** 取行模型文件数量文案的资源键（非资源形态返回 -1，使断言失败可见）。 */
function fileCountTextId(row: SessionRowModel): number {
  let value: ResourceStr = row.fileCountText
  if (typeof value === 'string') {
    return -1
  }
  return (value as Resource).id
}

// 文本消息适配器：展示描述符携带文本内容，行模型据此预计算文本会话标志
const TEXT_ROW_KEY: string = 'test-text-row'

const textRowAdapter: SessionAdapter = {
  key: TEXT_ROW_KEY,
  initialize: (): void => {
  },
  getCapabilities: defaultCapabilities,
  getDisplayDescriptor: (sessionId: string): SessionDisplayDescriptor => {
    return {
      peerTitle: 'TextPeer',
      peerSubtitle: '10.0.0.3',
      badges: [],
      deviceType: 'mobile',
      directionLabel: '接收',
      supportsTextPreview: true,
      textPreview: '文本内容'
    };
  },
  confirm: (): void => {
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

export default function TransferCenterTest() {
  describe('TransferCenterTest', () => {
    beforeAll(() => {
      // 初始化偏好存储：列表合并用例依赖会话历史持久化
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        initAllPreferences(ctx)
      }
    })

    it('sourceKey_derivedFromProtocolKey', 0, () => {
      expect(sessionSourceKey('localsend-send')).assertEqual('localsend')
      expect(sessionSourceKey('mta-receive')).assertEqual('mta')
      expect(sessionSourceKey('web-download')).assertEqual('web')
      expect(sessionSourceKey('plain')).assertEqual('plain')
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

    it('viewModel_dedupesLiveAndHistory_intoSingleEnterableRow', 0, () => {
      resetRegistry()
      resetSessionHistoryCache()
      let s = createSession(input('localsend-send', 'a'))
      finish(s.id, SessionStage.declined)
      // 同一会话同时处于终态可见窗口内与已归档历史：合并后只渲染一次，且仍可进入详情
      let vm = new TransferCenterViewModel()
      vm.refresh()
      let matches = 0
      for (let i = 0; i < vm.rows.length; i++) {
        let row = vm.rows[i].session
        if (row !== undefined && row.sessionId === s.id) {
          matches++
        }
      }
      expect(matches).assertEqual(1)
      // 读取列表不改变会话状态（从详情页返回同样不取消会话）
      let current = getSession(s.id)
      expect(current !== undefined).assertTrue()
      if (current !== undefined) {
        expect(current.stage).assertEqual(SessionStage.declined)
      }
      vm.stop()
      resetRegistry()
      resetSessionHistoryCache()
    })

    it('validateSessionRows_dropsUnresolvable_keepsResolvable', 0, () => {
      resetRegistry()
      let s = createSession(input('localsend-send', 'a'))
      let liveRow = liveSessionRow(s)
      let keptHistoryRow = historyEntryRow(historyEntry('hist-1', Date.now()))
      // 不可解析行：不持有实时会话对象，且标识不命中任何实时/历史集合
      let orphanRow = historyEntryRow(historyEntry('orphan-1', Date.now()))
      let result: RowValidationResult = validateSessionRows(
        [liveRow, keptHistoryRow, orphanRow], [s.id], ['hist-1'])
      expect(result.kept.length).assertEqual(2)
      expect(result.dropped.length).assertEqual(1)
      expect(result.kept[0].sessionId).assertEqual(s.id)
      expect(result.kept[1].sessionId).assertEqual('hist-1')
      expect(result.dropped[0].sessionId).assertEqual('orphan-1')
      resetRegistry()
    })

    it('validateSessionRows_emptyAndAllDropped', 0, () => {
      // 空序列边界：无双侧结果
      let empty: RowValidationResult = validateSessionRows([], [], [])
      expect(empty.kept.length).assertEqual(0)
      expect(empty.dropped.length).assertEqual(0)
      // 全不可解析序列边界：全部归入被剔除
      let orphanRow = historyEntryRow(historyEntry('orphan-2', 1))
      let allDropped: RowValidationResult = validateSessionRows([orphanRow], [], [])
      expect(allDropped.kept.length).assertEqual(0)
      expect(allDropped.dropped.length).assertEqual(1)
      expect(allDropped.dropped[0].sessionId).assertEqual('orphan-2')
    })

    it('liveRow_textSessionFlag_andActionSet', 0, () => {
      registerAdapter(textRowAdapter)
      resetRegistry()
      // 文本消息会话：行模型携带文本标志与内容，待确认行动作为「关闭 + 复制」
      let textInput = input(TEXT_ROW_KEY, 'txt')
      textInput.stage = SessionStage.awaitingConfirmation
      let textRow = liveSessionRow(createSession(textInput))
      expect(rowAwaitingConfirm(textRow)).assertTrue()
      expect(rowIsTextSession(textRow)).assertTrue()
      expect(textRow.textPreview).assertEqual('文本内容')

      // 文件会话行：无文本标志，动作为「确认 + 拒绝」
      let fileRow = liveSessionRow(createSession(input('localsend-send', 'file')))
      expect(rowIsTextSession(fileRow)).assertFalse()
      resetRegistry()
    })

    it('rowKey_stableAcrossLiveAndHistorySources', 0, () => {
      resetRegistry()
      let s = createSession(input('localsend-send', 'a'))
      let liveRow = liveSessionRow(s)
      // 同一会话标识在「实时条目」与「历史条目」两种来源下行键完全相同
      let historyRow = historyEntryRow(historyEntry(s.id, Date.now()))
      expect(liveRow.key).assertEqual(historyRow.key)
      // 行键即会话标识：不携带来源信息，与会话生命周期同寿命
      expect(liveRow.key).assertEqual(s.id)
      // 历史 schemaVersion 变化不改变行键（键不由历史格式参与构成）
      let otherVersion = historyEntry(s.id, Date.now())
      otherVersion.schemaVersion = 99
      expect(historyEntryRow(otherVersion).key).assertEqual(liveRow.key)
      // 不同会话的行键互不相同（条目身份全局唯一）
      let s2 = createSession(input('localsend-send', 'b'))
      expect(liveSessionRow(s2).key === liveRow.key).assertFalse()
      expect(historyEntryRow(historyEntry(s2.id, Date.now())).key === liveRow.key).assertFalse()
      resetRegistry()
    })

    it('rows_dedupedAcrossSourceTransition_keepsSingleLiveRow', 0, () => {
      resetRegistry()
      let s = createSession(input('localsend-send', 'a'))
      finish(s.id, SessionStage.succeeded)
      let liveRow = liveSessionRow(s)
      let historyRow = historyEntryRow(historyEntry(s.id, Date.now()))
      // 同一会话先以实时条目存在、再出现同标识历史条目：合并去重后仅一行
      let merged = mergeSessionRows([liveRow], [historyRow])
      expect(merged.length).assertEqual(1)
      expect(merged[0].session !== undefined).assertTrue()
      // 兜底去重：同标识重复行（含实时/历史同源）只保留首现，即实时条目
      let deduped = dedupeSessionRows([liveRow, historyRow, liveRow])
      expect(deduped.length).assertEqual(1)
      expect(deduped[0].session !== undefined).assertTrue()
      expect(deduped[0].sessionId).assertEqual(s.id)
      resetRegistry()
    })

    it('rows_sortedByTimeDesc_withDeterministicTieBreak', 0, () => {
      // 主键：会话时间倒序
      let older = historyEntryRow(historyEntry('session-old', 1000))
      let newer = historyEntryRow(historyEntry('session-new', 3000))
      let mid = historyEntryRow(historyEntry('session-mid', 2000))
      let byTime = sortSessionRows([older, newer, mid])
      expect(byTime[0].sessionId).assertEqual('session-new')
      expect(byTime[1].sessionId).assertEqual('session-mid')
      expect(byTime[2].sessionId).assertEqual('session-old')
      // 次级键：同时间戳按会话标识字典序升序，且与输入顺序无关（顺序完全确定）
      let same = 2000
      let rowB = historyEntryRow(historyEntry('session-b', same))
      let rowA = historyEntryRow(historyEntry('session-a', same))
      let forward = sortSessionRows([rowB, rowA])
      expect(forward[0].sessionId).assertEqual('session-a')
      expect(forward[1].sessionId).assertEqual('session-b')
      let reversed = sortSessionRows([rowA, rowB])
      expect(reversed[0].sessionId).assertEqual('session-a')
      expect(reversed[1].sessionId).assertEqual('session-b')
    })

    it('viewModel_clearHistory_removesRowWithoutRevival', 0, () => {
      resetRegistry()
      resetSessionHistoryCache()
      let s = createSession(input('localsend-send', 'a'))
      finish(s.id, SessionStage.failed)
      let vm = new TransferCenterViewModel()
      vm.refresh()
      // 终态可见窗口内与已归档历史同源：仅一行且可进入
      expect(countRowsForSession(vm, s.id)).assertEqual(1)
      vm.clearHistory()
      vm.refresh()
      // 清除历史后对应行消失
      expect(countRowsForSession(vm, s.id)).assertEqual(0)
      // 再次刷新不因身份复用而复活
      vm.refresh()
      expect(countRowsForSession(vm, s.id)).assertEqual(0)
      vm.stop()
      resetRegistry()
      resetSessionHistoryCache()
    })

    it('fileCountText_singleTextFile_showsTextLabel_liveAndHistory', 0, () => {
      resetRegistry()
      // 实时行：恰好一个文本类文件 → 文件数量位置显示「文本」标签
      let textFiles: Array<SessionFile> = [sessionFileOf('note.txt', 'text/plain')]
      let liveRow = liveSessionRow(createSession(inputWithFiles('txt-live', textFiles)))
      expect(fileCountTextId(liveRow)).assertEqual($r('app.string.transfer_center_text_label').id)

      // 历史行：同一会话转为历史条目后判定不变（实时行与历史行同口径）
      let historyRow = historyEntryRow(
        historyEntryWithFiles('txt-hist', [historyFileOf('note.txt', 'text/plain')]))
      expect(fileCountTextId(historyRow)).assertEqual($r('app.string.transfer_center_text_label').id)
      resetRegistry()
    })

    it('fileCountText_multiFileOrNonText_keepsFileCount', 0, () => {
      resetRegistry()
      // 多文件（含文本类）：一律显示文件数量，不显示「文本」
      let multiFiles: Array<SessionFile> = [
        sessionFileOf('note.txt', 'text/plain'),
        sessionFileOf('pic.png', 'image/png')
      ]
      let multiLive = liveSessionRow(createSession(inputWithFiles('multi-live', multiFiles)))
      expect(fileCountTextId(multiLive)).assertEqual($r('app.string.transfer_center_file_count', 2).id)
      let multiHistory = historyEntryRow(historyEntryWithFiles('multi-hist', [
        historyFileOf('note.txt', 'text/plain'),
        historyFileOf('pic.png', 'image/png')
      ]))
      expect(fileCountTextId(multiHistory)).assertEqual($r('app.string.transfer_center_file_count', 2).id)

      // 单非文本文件：显示文件数量
      let binaryFiles: Array<SessionFile> = [sessionFileOf('archive.bin', 'application/octet-stream')]
      let binaryLive = liveSessionRow(createSession(inputWithFiles('binary-live', binaryFiles)))
      expect(fileCountTextId(binaryLive)).assertEqual($r('app.string.transfer_center_file_count', 1).id)
      let binaryHistory = historyEntryRow(historyEntryWithFiles('binary-hist',
        [historyFileOf('archive.bin', 'application/octet-stream')]))
      expect(fileCountTextId(binaryHistory)).assertEqual($r('app.string.transfer_center_file_count', 1).id)

      // 无文件：保持文件数量（0）
      let emptyLive = liveSessionRow(createSession(input('localsend-send', 'empty-live')))
      expect(fileCountTextId(emptyLive)).assertEqual($r('app.string.transfer_center_file_count', 0).id)
      resetRegistry()
    })

    it('singleTextFilePredicate_reusesTextFileJudgement', 0, () => {
      // 恰好一个文本类文件：MIME 命中或扩展名命中均判为真（判定唯一来源为统一文本类判定）
      expect(isSingleTextFileTask(1, 'text/plain', 'payload')).assertTrue()
      expect(isSingleTextFileTask(1, '', 'readme.md')).assertTrue()
      // 多文件、单非文本、空清单均判为假
      expect(isSingleTextFileTask(2, 'text/plain', 'a.txt')).assertFalse()
      expect(isSingleTextFileTask(1, 'application/octet-stream', 'archive.bin')).assertFalse()
      expect(isSingleTextFileTask(0, '', '')).assertFalse()
    })

    it('describeCenterRows_threeDistinctSessions_eachLineOwnContent', 0, () => {
      // 三条会话：标识 / 时间 / 阶段各异（成功 / 失败 / 被拒）
      let e1 = historyEntry('sess-a', 1790011787000)
      let e2 = historyEntry('sess-b', 1790011801000)
      e2.outcome = SessionHistoryOutcome.failed
      let e3 = historyEntry('sess-c', 1790011817000)
      e3.outcome = SessionHistoryOutcome.declined
      let r1 = historyEntryRow(e1)
      let r2 = historyEntryRow(e2)
      let r3 = historyEntryRow(e3)
      let rows: Array<CenterRow> = [centerRowOf(r1), centerRowOf(r2), centerRowOf(r3)]

      let text = describeCenterRows(rows)
      expect(text.indexOf('行数=3') === 0).assertTrue()
      let segments = text.split(' [')
      expect(segments.length).assertEqual(4)
      // 每行摘要互不相同（作为「数据侧正确」的对照基线）
      expect(segments[1] === segments[2]).assertFalse()
      expect(segments[2] === segments[3]).assertFalse()
      expect(segments[1] === segments[3]).assertFalse()
      // 每行的会话标识与其时间 / 阶段同属一条会话
      expect(segments[1].indexOf('会话标识=' + r1.sessionId) >= 0).assertTrue()
      expect(segments[1].indexOf('时间=' + r1.timeText) >= 0).assertTrue()
      expect(segments[1].indexOf(`阶段=${SessionStage.succeeded}`) >= 0).assertTrue()
      expect(segments[2].indexOf('会话标识=' + r2.sessionId) >= 0).assertTrue()
      expect(segments[2].indexOf('时间=' + r2.timeText) >= 0).assertTrue()
      expect(segments[2].indexOf(`阶段=${SessionStage.failed}`) >= 0).assertTrue()
      expect(segments[3].indexOf('会话标识=' + r3.sessionId) >= 0).assertTrue()
      expect(segments[3].indexOf('时间=' + r3.timeText) >= 0).assertTrue()
      expect(segments[3].indexOf(`阶段=${SessionStage.declined}`) >= 0).assertTrue()
    })

    it('describeCenterRows_boundariesAndConsistency', 0, () => {
      resetRegistry()
      // 空序列：行数 0，无行标记
      let emptyText = describeCenterRows([])
      expect(emptyText).assertEqual('行数=0')
      expect(describedRowCount(emptyText)).assertEqual(0)

      // 单行
      let s = createSession(input('localsend-send', 'a'))
      let singleRows: Array<CenterRow> = [centerRowOf(liveSessionRow(s))]
      let singleText = describeCenterRows(singleRows)
      expect(singleText.indexOf('行数=1') === 0).assertTrue()
      expect(describedRowCount(singleText)).assertEqual(1)

      // 含空态标记：空态行无会话对象，以类别标记，仍计为一行
      let emptyRow: CenterRow = { key: 'empty', kind: ROW_EMPTY }
      let emptyStateText = describeCenterRows([emptyRow])
      expect(emptyStateText.indexOf('行数=1') === 0).assertTrue()
      expect(emptyStateText.indexOf('类别=' + ROW_EMPTY) >= 0).assertTrue()
      expect(describedRowCount(emptyStateText)).assertEqual(1)

      // 多行：描述行数与输入长度严格一致
      let b = createSession(input('localsend-send', 'b'))
      let c = createSession(input('localsend-send', 'c'))
      let manyRows: Array<CenterRow> = [
        centerRowOf(liveSessionRow(s)),
        centerRowOf(liveSessionRow(b)),
        centerRowOf(liveSessionRow(c))
      ]
      let manyText = describeCenterRows(manyRows)
      expect(manyText.indexOf('行数=3') === 0).assertTrue()
      expect(describedRowCount(manyText)).assertEqual(manyRows.length)
      resetRegistry()
    })
  })
}
