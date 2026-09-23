import { describe, it, expect } from '@ohos/hypium'
import {
  createSession,
  appendFiles,
  setSessionFiles,
  updateFileProgress,
  finish,
  setStage,
  setStageProgress,
  getSession,
  getOverallSnapshot,
  getActiveCount,
  querySessions,
  resetRegistry,
  clearHistory,
  getClearableCount,
  getHistory,
  reclaimDelayMs,
  deriveOverall,
  recomputeTotals,
  isSamePeer,
  replaceTerminalSessionsForPeer,
  isNoProgressTimeout,
  checkNoProgress,
  updateProtocolSessionId,
  subscribeSessions,
  unsubscribeSessions,
  PeerIdentity,
  SUCCESS_VISIBLE_MS,
  FAILURE_VISIBLE_MS,
  NO_PROGRESS_TIMEOUT_MS,
  NO_PROGRESS_ERROR_CODE
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  SessionCreateInput,
  SessionDataFlow,
  SessionFileStage,
  SessionInitiator,
  SessionPeer,
  SessionStage,
  SessionFilter,
  TransferSession,
  defaultCapabilities,
  emptyPeer,
  isTerminalStage,
  outcomeForStage,
  SessionHistoryOutcome
} from '../../../../main/ets/model/transfer/TransferSession'
import { clearSessionHistory } from '../../../../main/ets/service/transfer/SessionHistoryStore'

// 会话注册表纯逻辑单测：生命周期、聚合、回收窗口、分母增长容忍。
function makeInput(): SessionCreateInput {
  return {
    protocolKey: 'test',
    protocolSessionId: 'p1',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: emptyPeer(),
    files: [{
      fileId: 'f1',
      fileName: 'a.bin',
      fileType: 'application/octet-stream',
      totalBytes: 100
    }],
    capabilities: defaultCapabilities()
  }
}

/** 两文件输入：f1 已完成、f2 仍传输中，用于验证终态逐文件补齐三档规则。 */
function twoFileInput(): SessionCreateInput {
  return {
    protocolKey: 'test',
    protocolSessionId: 'p2',
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
}

/** 三文件输入：用于验证取消后逐文件终态改写（f1 已完成、f2 传输中、f3 等待中）。 */
function threeFileInput(): SessionCreateInput {
  return {
    protocolKey: 'test',
    protocolSessionId: 'p3',
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
      },
      {
        fileId: 'f3',
        fileName: 'c.bin',
        fileType: 'application/octet-stream',
        totalBytes: 100
      }
    ],
    capabilities: defaultCapabilities()
  }
}

/** 构造具名对端（name 为空表示匿名；ip 为空表示协议未携带）。 */
function namedPeer(name: string, ip: string): SessionPeer {
  return { displayName: name, ip: ip, badges: [] }
}

/** 构造带指定对端的会话输入。 */
function inputForPeer(name: string, ip: string, protocolKey: string): SessionCreateInput {
  let base = makeInput()
  base.protocolKey = protocolKey
  base.peer = namedPeer(name, ip)
  return base
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
      appendFiles(s.id, [{
        fileId: 'f2',
        fileName: 'b.bin',
        fileType: 'application/octet-stream',
        totalBytes: 100
      }])
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

    it('finish_clears_stale_stage_text', 0, () => {
      resetRegistry()
      let input = makeInput()
      input.stageText = '传输中'
      let s = createSession(input)
      let running = getSession(s.id)
      expect(running !== undefined).assertTrue()
      if (running !== undefined) {
        expect(running.stageText).assertEqual('传输中')
      }
      finish(s.id, SessionStage.succeeded)
      let done = getSession(s.id)
      expect(done !== undefined).assertTrue()
      if (done !== undefined) {
        // 终态清空进行中阶段残留文案，终态文案由统一状态映射决定
        expect(done.stageText).assertEqual('')
      }
      // 终态后不得再写入阶段文案（防止终态被回写成进行中）
      setStageProgress(s.id, '传输中')
      let after = getSession(s.id)
      expect(after !== undefined).assertTrue()
      if (after !== undefined) {
        expect(after.stageText).assertEqual('')
        expect(after.stage).assertEqual(SessionStage.succeeded)
      }
      resetRegistry()
    })

    it('finish_failureClass_marksUnfinishedFailed', 0, () => {
      resetRegistry()
      let s = createSession(twoFileInput())
      // f1 已完成、f2 仍传输中
      updateFileProgress(s.id, 'f1', 100)
      updateFileProgress(s.id, 'f2', 40)
      let mid = getSession(s.id)
      expect(mid !== undefined).assertTrue()
      if (mid !== undefined) {
        expect(mid.files[0].stage).assertEqual(SessionFileStage.completed)
        expect(mid.files[1].stage).assertEqual(SessionFileStage.transferring)
      }
      // 失败类终态：已完成保持成功，未完成（传输中/等待中）变更为失败
      finish(s.id, SessionStage.failed, 'boom')
      let done = getSession(s.id)
      expect(done !== undefined).assertTrue()
      if (done !== undefined) {
        expect(done.files[0].stage).assertEqual(SessionFileStage.completed)
        expect(done.files[1].stage).assertEqual(SessionFileStage.failed)
      }
      resetRegistry()
    })

    it('finish_partialFailure_sameRule', 0, () => {
      resetRegistry()
      let s = createSession(twoFileInput())
      updateFileProgress(s.id, 'f1', 100)
      finish(s.id, SessionStage.partiallyFailed, 'boom')
      let done = getSession(s.id)
      expect(done !== undefined).assertTrue()
      if (done !== undefined) {
        expect(done.files[0].stage).assertEqual(SessionFileStage.completed)
        expect(done.files[1].stage).assertEqual(SessionFileStage.failed)
      }
      resetRegistry()
    })

    it('finish_cancelled_marksUnfinishedCancelled_completedKept', 0, () => {
      resetRegistry()
      let s = createSession(threeFileInput())
      // f1 已完成、f2 传输中、f3 等待中
      updateFileProgress(s.id, 'f1', 100)
      updateFileProgress(s.id, 'f2', 40)
      finish(s.id, SessionStage.cancelled)
      let done = getSession(s.id)
      expect(done !== undefined).assertTrue()
      if (done !== undefined) {
        // 取消类终态：已完成文件保持，未完成（传输中/等待中）文件置为已取消
        expect(done.files[0].stage).assertEqual(SessionFileStage.completed)
        expect(done.files[1].stage).assertEqual(SessionFileStage.cancelled)
        expect(done.files[2].stage).assertEqual(SessionFileStage.cancelled)
      }
      resetRegistry()
    })

    it('finish_declined_keepsFileStages', 0, () => {
      resetRegistry()
      let input = twoFileInput()
      input.stage = SessionStage.awaitingConfirmation
      let s = createSession(input)
      finish(s.id, SessionStage.declined)
      let done = getSession(s.id)
      expect(done !== undefined).assertTrue()
      if (done !== undefined) {
        // 拒绝类终态不改写逐文件状态
        expect(done.files[0].stage).assertEqual(SessionFileStage.waiting)
        expect(done.files[1].stage).assertEqual(SessionFileStage.waiting)
      }
      resetRegistry()
    })

    it('finish_success_allCompletedAndBytesFilled', 0, () => {
      resetRegistry()
      let s = createSession(twoFileInput())
      updateFileProgress(s.id, 'f1', 100)
      finish(s.id, SessionStage.succeeded)
      let done = getSession(s.id)
      expect(done !== undefined).assertTrue()
      if (done !== undefined) {
        expect(done.files[0].stage).assertEqual(SessionFileStage.completed)
        expect(done.files[1].stage).assertEqual(SessionFileStage.completed)
        expect(done.files[1].bytesSent).assertEqual(100)
      }
      resetRegistry()
    })

    it('setSessionFiles_replacesWholeList_onNonTerminal', 0, () => {
      resetRegistry()
      let s = createSession(makeInput())
      let notifications = 0
      let cb = (): void => {
        notifications++;
      }
      subscribeSessions(cb)
      // 整体替换：以真实落盘逐文件清单取代创建期的占位条目（保留描述符携带的路径）
      let replaced = setSessionFiles(s.id, [
        {
          fileId: 'mta-0',
          fileName: 'photo.jpg',
          fileType: 'image/jpeg',
          totalBytes: 200,
          path: '/d/photo.jpg'
        },
        {
          fileId: 'mta-1',
          fileName: 'note.txt',
          fileType: 'text/plain',
          totalBytes: 100,
          path: '/d/note.txt'
        }
      ])
      expect(replaced).assertTrue()
      // 发布一次变更通知
      expect(notifications).assertEqual(1)
      let current = getSession(s.id)
      expect(current !== undefined).assertTrue()
      if (current !== undefined) {
        expect(current.files.length).assertEqual(2)
        expect(current.files[0].fileName).assertEqual('photo.jpg')
        expect(current.files[0].totalBytes).assertEqual(200)
        expect(current.files[0].path).assertEqual('/d/photo.jpg')
        expect(current.files[1].fileName).assertEqual('note.txt')
        expect(current.files[1].totalBytes).assertEqual(100)
        expect(current.files[1].path).assertEqual('/d/note.txt')
        // fileId 互异且不再保留原占位条目 f1
        expect(current.files[0].fileId === current.files[1].fileId).assertFalse()
        expect(current.files[0].fileId).assertEqual('mta-0')
        expect(current.files[1].fileId).assertEqual('mta-1')
        // 会话总字节按新清单重算
        expect(current.totalBytes).assertEqual(300)
      }
      unsubscribeSessions(cb)
      resetRegistry()
    })

    it('setSessionFiles_noOp_onTerminal_emptyOrMissing', 0, () => {
      resetRegistry()
      let s = createSession(makeInput())
      // 空清单：空操作
      expect(setSessionFiles(s.id, [])).assertFalse()
      // 会话不存在 / 会话标识为空：空操作
      expect(setSessionFiles('no-such-session', [{
        fileId: 'mta-0',
        fileName: 'x.bin',
        fileType: '',
        totalBytes: 5
      }])).assertFalse()
      expect(setSessionFiles('', [{
        fileId: 'mta-0',
        fileName: 'x.bin',
        fileType: '',
        totalBytes: 5
      }])).assertFalse()
      // 终态：空操作（终态不改写），原清单保持不变
      finish(s.id, SessionStage.succeeded)
      expect(setSessionFiles(s.id, [{
        fileId: 'mta-0',
        fileName: 'x.bin',
        fileType: '',
        totalBytes: 5
      }])).assertFalse()
      let done = getSession(s.id)
      expect(done !== undefined).assertTrue()
      if (done !== undefined) {
        expect(done.files.length).assertEqual(1)
        expect(done.files[0].fileName).assertEqual('a.bin')
      }
      resetRegistry()
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

    it('isSamePeer_ipThenNicknameFallback', 0, () => {
      // 双方 IP 均非空：按 IP 判定，昵称不同也视为同一对端
      let a: PeerIdentity = { ip: '10.0.0.1', name: '甲' }
      let b: PeerIdentity = { ip: '10.0.0.1', name: '乙' }
      expect(isSamePeer(a, b)).assertTrue()
      // IP 不同即不同对端（昵称相同也不合并）
      let c: PeerIdentity = { ip: '10.0.0.2', name: '甲' }
      expect(isSamePeer(a, c)).assertFalse()
      // 一方 IP 缺失：回退昵称匹配（跨协议场景）
      let noIp: PeerIdentity = { ip: '', name: '甲' }
      expect(isSamePeer(noIp, a)).assertTrue()
      // 双方 ID 均缺失：不匹配（匿名对端不参与同设备判定）
      let blank: PeerIdentity = { ip: '', name: '' }
      expect(isSamePeer(blank, blank)).assertFalse()
      // 一方昵称缺失：不匹配
      let nameMissing: PeerIdentity = { ip: '', name: '' }
      expect(isSamePeer(noIp, nameMissing)).assertFalse()
    })

    it('replace_samePeer_removesOnlyTerminalEntries', 0, () => {
      resetRegistry()
      // 同设备：一条已终态（应被移除）与一条进行中（不受影响）
      let done = createSession(inputForPeer('Peer', '10.0.0.1', 'localsend-send'))
      finish(done.id, SessionStage.succeeded)
      let running = createSession(inputForPeer('Peer', '10.0.0.1', 'localsend-send'))
      // 其它对端：已终态（不受影响）
      let other = createSession(inputForPeer('Other', '10.0.0.2', 'localsend-send'))
      finish(other.id, SessionStage.succeeded)
      let identity: PeerIdentity = { ip: '10.0.0.1', name: 'Peer' }
      let removed = replaceTerminalSessionsForPeer(identity)
      expect(removed).assertEqual(1)
      expect(getSession(done.id) === undefined).assertTrue()
      expect(getSession(running.id) !== undefined).assertTrue()
      expect(getSession(other.id) !== undefined).assertTrue()
      resetRegistry()
    })

    it('replace_anonymousPeer_notMisjudged', 0, () => {
      resetRegistry()
      // 匿名对端（无昵称、无 IP）的已终态会话：任何身份声明都不得误判为同一对端
      let anon = createSession(makeInput())
      finish(anon.id, SessionStage.succeeded)
      let byIp: PeerIdentity = { ip: '10.0.0.9', name: '' }
      expect(replaceTerminalSessionsForPeer(byIp)).assertEqual(0)
      let byName: PeerIdentity = { ip: '', name: '某人' }
      expect(replaceTerminalSessionsForPeer(byName)).assertEqual(0)
      expect(getSession(anon.id) !== undefined).assertTrue()
      resetRegistry()
    })

    it('replace_crossProtocol_nicknameFallback', 0, () => {
      resetRegistry()
      // 局域网发送（携带 IP 与昵称）后经互传发送（仅昵称）再次发送同一设备：
      // 互传侧以昵称声明身份，回退昵称匹配并移除局域网旧终态条目
      let local = createSession(inputForPeer('同一设备', '10.0.0.5', 'localsend-send'))
      finish(local.id, SessionStage.succeeded)
      let byNickname: PeerIdentity = { ip: '', name: '同一设备' }
      expect(replaceTerminalSessionsForPeer(byNickname)).assertEqual(1)
      expect(getSession(local.id) === undefined).assertTrue()
      resetRegistry()
    })

    it('clearHistory_clearsPersistedAndTerminalVisible_notActive', 0, () => {
      resetRegistry()
      // 显式清空持久化历史，排除其它套件残留，保证计数口径可确定
      clearSessionHistory()
      // 一条已终态：既已归档为历史，又是终态可见条目
      let done = createSession(inputForPeer('Peer', '10.0.0.1', 'localsend-send'))
      finish(done.id, SessionStage.succeeded)
      // 进行中与待确认：清除不得触碰
      let running = createSession(inputForPeer('Peer2', '10.0.0.2', 'localsend-send'))
      let pendingInput = inputForPeer('Peer3', '10.0.0.3', 'mta-receive')
      pendingInput.stage = SessionStage.awaitingConfirmation
      let pending = createSession(pendingInput)
      // 可清除计数 = 历史条数(1) + 已终态可见会话数(1)
      expect(getClearableCount()).assertEqual(2)
      clearHistory()
      // 历史与已终态可见条目一并被清除
      expect(getHistory().length).assertEqual(0)
      expect(getSession(done.id) === undefined).assertTrue()
      // 进行中/待确认不受影响
      expect(getSession(running.id) !== undefined).assertTrue()
      expect(getSession(pending.id) !== undefined).assertTrue()
      // 清除后无可清除内容
      expect(getClearableCount()).assertEqual(0)
      resetRegistry()
      clearSessionHistory()
    })

    it('clearableCount_terminalVisibleWithoutHistory', 0, () => {
      resetRegistry()
      clearSessionHistory()
      let done = createSession(inputForPeer('Peer', '10.0.0.1', 'localsend-send'))
      finish(done.id, SessionStage.succeeded)
      // 丢弃历史后仅剩已终态可见会话：可清除计数不为零（入口不置灰）
      clearSessionHistory()
      expect(getClearableCount()).assertEqual(1)
      resetRegistry()
      clearSessionHistory()
    })

    it('noProgress_decision_pureFunction', 0, () => {
      expect(NO_PROGRESS_TIMEOUT_MS).assertEqual(60000)
      // 超过阈值 → 应终结
      expect(isNoProgressTimeout(100000, 30000, NO_PROGRESS_TIMEOUT_MS)).assertTrue()
      // 未超过阈值 → 不终结
      expect(isNoProgressTimeout(40000, 30000, NO_PROGRESS_TIMEOUT_MS)).assertFalse()
      // 恰好等于阈值：不终结（严格大于阈值才终结）
      expect(isNoProgressTimeout(90000, 30000, NO_PROGRESS_TIMEOUT_MS)).assertFalse()
    })

    it('noProgress_check_terminatesStalledOutbound', 0, () => {
      resetRegistry()
      let s = createSession(inputForPeer('Peer', '10.0.0.1', 'localsend-send'))
      // 创建后无任何进度与阶段变化，注入超过阈值的时刻 → 按失败终结
      let terminated = checkNoProgress(Date.now() + NO_PROGRESS_TIMEOUT_MS + 1000)
      expect(terminated).assertEqual(1)
      let done = getSession(s.id)
      expect(done !== undefined).assertTrue()
      if (done !== undefined) {
        expect(done.stage).assertEqual(SessionStage.failed)
        expect(done.errorCode).assertEqual(NO_PROGRESS_ERROR_CODE)
        expect(done.errorMessage.length > 0).assertTrue()
      }
      resetRegistry()
    })

    it('noProgress_inboundSession_notAffected', 0, () => {
      resetRegistry()
      // 接收方向会话不参与看门狗：即便注入远超阈值的时刻也不得被终结
      let inboundInput = inputForPeer('Peer', '10.0.0.1', 'localsend-receive')
      inboundInput.dataFlow = SessionDataFlow.inbound
      inboundInput.initiatedBy = SessionInitiator.remote
      let inbound = createSession(inboundInput)
      let terminated = checkNoProgress(Date.now() + NO_PROGRESS_TIMEOUT_MS * 100)
      expect(terminated).assertEqual(0)
      expect(getSession(inbound.id) !== undefined).assertTrue()
      resetRegistry()
    })

    it('noProgress_continuousProgress_neverTerminated', 0, () => {
      resetRegistry()
      let s = createSession(inputForPeer('Peer', '10.0.0.1', 'localsend-send'))
      // 每轮先产生字节进度（刷新活动基准），再注入「距上次活动半个阈值」的检查时刻；
      // 连续 20 轮累计检查跨度远超阈值，但从未连续无进展 → 绝不终结（不存在总存活上限）
      for (let i = 0; i < 20; i++) {
        updateFileProgress(s.id, 'f1', 1 + i, 100)
        expect(checkNoProgress(Date.now() + 30000)).assertEqual(0)
      }
      let alive = getSession(s.id)
      expect(alive !== undefined).assertTrue()
      if (alive !== undefined) {
        expect(alive.stage).assertEqual(SessionStage.active)
      }
      resetRegistry()
    })

    it('noProgress_firstTerminalWins', 0, () => {
      resetRegistry()
      let s = createSession(inputForPeer('Peer', '10.0.0.1', 'localsend-send'))
      finish(s.id, SessionStage.succeeded)
      // 已终态会话再触发无进展检查：结果不变（幂等，首次终态为准）
      let terminated = checkNoProgress(Date.now() + NO_PROGRESS_TIMEOUT_MS * 10)
      expect(terminated).assertEqual(0)
      let done = getSession(s.id)
      expect(done !== undefined).assertTrue()
      if (done !== undefined) {
        expect(done.stage).assertEqual(SessionStage.succeeded)
      }
      resetRegistry()
    })

    it('updateProtocolSessionId_onlyEmptyToNonEmpty_onNonTerminal', 0, () => {
      resetRegistry()
      let blank = makeInput()
      blank.protocolSessionId = ''
      let s = createSession(blank)
      // 创建时协议标识尚不可知：初始为空
      expect(s.protocolSessionId).assertEqual('')
      // 空 → 非空：写入、返回真、并发布一次变更通知
      let notifications = 0
      let cb = (): void => {
        notifications++;
      }
      subscribeSessions(cb)
      expect(updateProtocolSessionId(s.id, 'uuid-1')).assertTrue()
      expect(notifications).assertEqual(1)
      let loaded = getSession(s.id)
      expect(loaded !== undefined ? loaded.protocolSessionId : '').assertEqual('uuid-1')
      // 已非空不覆盖
      expect(updateProtocolSessionId(s.id, 'uuid-2')).assertFalse()
      let kept = getSession(s.id)
      expect(kept !== undefined ? kept.protocolSessionId : '').assertEqual('uuid-1')
      expect(notifications).assertEqual(1)
      // 终态不写入
      finish(s.id, SessionStage.succeeded)
      expect(updateProtocolSessionId(s.id, 'uuid-3')).assertFalse()
      let terminal = getSession(s.id)
      expect(terminal !== undefined ? terminal.protocolSessionId : '').assertEqual('uuid-1')
      // 参数为空 / 会话不存在：空操作
      expect(updateProtocolSessionId(s.id, '')).assertFalse()
      expect(updateProtocolSessionId('', 'uuid-4')).assertFalse()
      expect(updateProtocolSessionId('no-such-session', 'uuid-4')).assertFalse()
      unsubscribeSessions(cb)
      resetRegistry()
    })

    it('updateProtocolSessionId_onTerminalSession_noWrite', 0, () => {
      resetRegistry()
      let blank = makeInput()
      blank.protocolSessionId = ''
      let s = createSession(blank)
      finish(s.id, SessionStage.failed)
      // 终结后不得回填：保证归档值等于终态时刻的实际值
      expect(updateProtocolSessionId(s.id, 'uuid-late')).assertFalse()
      let done = getSession(s.id)
      expect(done !== undefined ? done.protocolSessionId : 'x').assertEqual('')
      resetRegistry()
    })
  })
}
