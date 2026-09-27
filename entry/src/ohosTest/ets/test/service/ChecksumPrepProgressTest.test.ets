import { describe, it, expect, beforeAll } from '@ohos/hypium'
import {
  SessionCreateInput,
  SessionDataFlow,
  SessionInitiator,
  SessionStage,
  TransferSession,
  defaultCapabilities,
  emptyPeer,
  isPreparing,
  isTerminalStage
} from '../../../../main/ets/model/transfer/TransferSession'
import {
  cancel,
  clearPrep,
  createSession,
  finish,
  getActiveCount,
  getSession,
  resetRegistry,
  setPrepProgress,
  setStageProgress
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  liveSessionRow,
  rowHasByteProgress,
  rowPercent,
  SessionRowModel
} from '../../../../main/ets/viewmodel/TransferCenterViewModel'
import { SessionDetailViewModel } from '../../../../main/ets/viewmodel/SessionDetailViewModel'
import { sessionBadgeText } from '../../../../main/ets/views/transfer/SessionStatusBadge'
import { shouldEmitChecksumAggregate } from '../../../../main/ets/service/repository/ChecksumRepository'
import { hasActiveUnifiedSession } from '../../../../main/ets/service/repository/SendRepository'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import { getTestAppContext } from '../helper/TestContext'

// 准备阶段文案与非准备阶段文案（用字符串承载，避免测试 HAP 对三语言资源的依赖）
const CHECKSUM_STAGE_TEXT: string = '正在计算校验和'
const OTHER_STAGE_TEXT: string = '传输中'

// 准备态（校验和计算）进度口径测试：注册表准备进度、任务行与详情页进度取值。

/** 两文件输入：用于验证准备进度分母与传输进度互不混用。 */
function twoFileInput(): SessionCreateInput {
  return {
    protocolKey: 'test-prep',
    protocolSessionId: 'prep-1',
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

export default function ChecksumPrepProgressTest() {
  describe('ChecksumPrepProgressTest', () => {
    beforeAll(() => {
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        initAllPreferences(ctx)
      }
    })

    it('setPrepProgress_setsAndMonotonic', 0, () => {
      resetRegistry()
      let s = createSession(twoFileInput())
      // 初值：不处于准备态
      expect(isPreparing(s)).assertFalse()
      setPrepProgress(s.id, 0, 200)
      let started = getSession(s.id)
      expect(started !== undefined).assertTrue()
      if (started !== undefined) {
        expect(started.prepBytes).assertEqual(0)
        expect(started.prepTotalBytes).assertEqual(200)
        expect(isPreparing(started)).assertTrue()
      }
      setPrepProgress(s.id, 50, 200)
      let midway = getSession(s.id)
      if (midway !== undefined) {
        expect(midway.prepBytes).assertEqual(50)
      }
      // 迟到的小值不回跳
      setPrepProgress(s.id, 30, 200)
      let afterLate = getSession(s.id)
      if (afterLate !== undefined) {
        expect(afterLate.prepBytes).assertEqual(50)
      }
      resetRegistry()
    })

    it('clearPrep_zeroesBoth', 0, () => {
      resetRegistry()
      let s = createSession(twoFileInput())
      setPrepProgress(s.id, 120, 200)
      clearPrep(s.id)
      let cleared = getSession(s.id)
      expect(cleared !== undefined).assertTrue()
      if (cleared !== undefined) {
        expect(cleared.prepBytes).assertEqual(0)
        expect(cleared.prepTotalBytes).assertEqual(0)
        expect(isPreparing(cleared)).assertFalse()
      }
      resetRegistry()
    })

    it('clearPrep_clearsPrepProgressAndStageText', 0, () => {
      resetRegistry()
      let s = createSession(twoFileInput())
      // 进入准备态：写入准备阶段文案 + 置准备分母
      setStageProgress(s.id, CHECKSUM_STAGE_TEXT)
      setPrepProgress(s.id, 0, 200)
      let preparing = getSession(s.id)
      expect(preparing !== undefined).assertTrue()
      if (preparing !== undefined) {
        expect(isPreparing(preparing)).assertTrue()
        expect(typeof preparing.stageText === 'string' && preparing.stageText.length === 0).assertFalse()
      }
      // 结束准备：准备进度与准备阶段文案一并清零（徽标回落到统一状态映射）
      clearPrep(s.id)
      let cleared = getSession(s.id)
      expect(cleared !== undefined).assertTrue()
      if (cleared !== undefined) {
        expect(cleared.prepBytes).assertEqual(0)
        expect(cleared.prepTotalBytes).assertEqual(0)
        expect(isPreparing(cleared)).assertFalse()
        // stageText 必须清空，否则徽标/详情页会残留「正在计算校验和」
        expect(typeof cleared.stageText === 'string').assertTrue()
        if (typeof cleared.stageText === 'string') {
          expect(cleared.stageText).assertEqual('')
        }
        // 徽标文案回落为统一状态标签（active → 传输中），不再展示准备文案
        let badge = sessionBadgeText(cleared.stage, cleared.stageText)
        expect(badge !== CHECKSUM_STAGE_TEXT).assertTrue()
      }
      resetRegistry()
    })

    it('clearPrep_notPreparing_keepsStageText', 0, () => {
      resetRegistry()
      let s = createSession(twoFileInput())
      // 未处于准备态（无准备进度）：先写入一个非准备阶段文案
      setStageProgress(s.id, OTHER_STAGE_TEXT)
      clearPrep(s.id)
      let kept = getSession(s.id)
      expect(kept !== undefined).assertTrue()
      if (kept !== undefined) {
        // 提前返回语义：未处于准备态的会话其既有 stageText 不被清除
        expect(typeof kept.stageText === 'string').assertTrue()
        if (typeof kept.stageText === 'string') {
          expect(kept.stageText).assertEqual(OTHER_STAGE_TEXT)
        }
      }
      resetRegistry()
    })

    it('finish_clearsPrepFields', 0, () => {
      resetRegistry()
      let s = createSession(twoFileInput())
      setPrepProgress(s.id, 80, 200)
      finish(s.id, SessionStage.cancelled)
      let done = getSession(s.id)
      expect(done !== undefined).assertTrue()
      if (done !== undefined) {
        // 终态清零准备进度，避免终态行残留准备态
        expect(done.prepBytes).assertEqual(0)
        expect(done.prepTotalBytes).assertEqual(0)
        expect(isPreparing(done)).assertFalse()
      }
      // 终态后写入准备进度为空操作
      setPrepProgress(s.id, 200, 200)
      let after = getSession(s.id)
      if (after !== undefined) {
        expect(after.prepTotalBytes).assertEqual(0)
      }
      resetRegistry()
    })

    it('prepCancel_terminalLands_noActiveHang', 0, () => {
      resetRegistry()
      let s1 = createSession(twoFileInput())
      let s2 = createSession(twoFileInput())
      setPrepProgress(s1.id, 40, 200)
      setPrepProgress(s2.id, 90, 200)
      // 准备期取消（统一取消入口）：终态必然落地，active 不悬挂
      cancel(s1.id)
      cancel(s2.id)
      let d1 = getSession(s1.id)
      let d2 = getSession(s2.id)
      expect(d1 !== undefined).assertTrue()
      expect(d2 !== undefined).assertTrue()
      if (d1 !== undefined && d2 !== undefined) {
        expect(isTerminalStage(d1.stage)).assertTrue()
        expect(isTerminalStage(d2.stage)).assertTrue()
        expect(isPreparing(d1)).assertFalse()
        expect(isPreparing(d2)).assertFalse()
      }
      // 无进行中会话悬挂
      expect(getActiveCount()).assertEqual(0)
      expect(hasActiveUnifiedSession([s1.id, s2.id])).assertFalse()
      resetRegistry()
    })

    it('rowPrep_progressOverridesTransfer', 0, () => {
      resetRegistry()
      let s = createSession(twoFileInput())
      // 准备态：分母为准备总量，取准备进度
      setPrepProgress(s.id, 50, 200)
      let row: SessionRowModel = liveSessionRow(s)
      expect(rowHasByteProgress(row)).assertTrue()
      expect(rowPercent(row)).assertEqual(25)
      clearPrep(s.id)
      // 非准备态维持传输口径（bytesSent=0 / totalBytes=200 → 0%）
      let row2: SessionRowModel = liveSessionRow(s)
      expect(rowHasByteProgress(row2)).assertTrue()
      expect(rowPercent(row2)).assertEqual(0)
      resetRegistry()
    })

    it('detailPrep_progressAndStage', 0, () => {
      resetRegistry()
      let s = createSession(twoFileInput())
      setPrepProgress(s.id, 50, 200)
      let vm = new SessionDetailViewModel()
      vm.load(s.id)
      expect(vm.isPreparingState()).assertTrue()
      expect(vm.hasByteProgress()).assertTrue()
      expect(vm.percent()).assertEqual(25)
      clearPrep(s.id)
      vm.load(s.id)
      expect(vm.isPreparingState()).assertFalse()
      expect(vm.percent()).assertEqual(0)
      vm.unload()
      resetRegistry()
    })

    it('batch_continueJudgement_allTerminalStops', 0, () => {
      resetRegistry()
      // 空集合不继续
      expect(hasActiveUnifiedSession([])).assertFalse()
      let s1 = createSession(twoFileInput())
      let s2 = createSession(twoFileInput())
      // 存在非终态参与会话：继续
      expect(hasActiveUnifiedSession([s1.id, s2.id])).assertTrue()
      // 一台终态、一台进行中：仍继续
      finish(s1.id, SessionStage.cancelled)
      expect(hasActiveUnifiedSession([s1.id, s2.id])).assertTrue()
      // 全部终态：停止
      finish(s2.id, SessionStage.cancelled)
      expect(hasActiveUnifiedSession([s1.id, s2.id])).assertFalse()
      // 未登记标识视为终态：不继续
      expect(hasActiveUnifiedSession(['no-such-session'])).assertFalse()
      resetRegistry()
    })

    it('throttle_pureFunction_suppressesSmallFast', 0, () => {
      // 同值不写
      expect(shouldEmitChecksumAggregate(100, 1000, 100, 10, 1000, 900)).assertFalse()
      // 百分比变化不足 1% 且间隔不足 200ms：合并（不写）
      expect(shouldEmitChecksumAggregate(105, 1000, 100, 10, 1000, 900)).assertFalse()
      // 间隔达到 200ms：即使变化不足 1% 也写
      expect(shouldEmitChecksumAggregate(105, 1000, 100, 10, 1200, 900)).assertTrue()
      // 百分比变化达到 1%：写
      expect(shouldEmitChecksumAggregate(120, 1000, 100, 10, 950, 900)).assertTrue()
    })
  })
}
