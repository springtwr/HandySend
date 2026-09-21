import { describe, it, expect } from '@ohos/hypium'
import {
  MtaSendEndPlan,
  MtaSendEventDecision,
  MtaSendEventIgnoreReason,
  decideMtaSendEvent,
  decideMtaSendInstanceEnd
} from '../../../../main/ets/service/transfer/adapters/MtaSendAdapter'
import { MtaSenderStage } from '../../../../main/ets/model/mta/MtaSendModels'

// 发送会话注册与生命周期修复的确定性用例：
// 竞态由适配器导出的两个纯决策函数驱动复现，不依赖真机多次发送。
export default function SendSessionRegistrationTest() {
  describe('SendSessionRegistrationTest', () => {
    it('mtaSendEvent_staleGenerationIgnored', 0, () => {
      // 上一次发送（代次 1）的迟到事件在本次发送（代次 2）开始后到达：一律丢弃且零副作用
      let stale = decideMtaSendEvent(2, 1, false, false, MtaSenderStage.TRANSFERRING)
      expect(stale.decision).assertEqual(MtaSendEventDecision.ignore)
      expect(stale.ignoreReason).assertEqual(MtaSendEventIgnoreReason.staleGeneration)
      expect(stale.terminal).assertFalse()
      // 迟到的终态事件同样被丢弃：不得终结当前会话
      let staleTerminal = decideMtaSendEvent(2, 1, true, false, MtaSenderStage.FAILED)
      expect(staleTerminal.decision).assertEqual(MtaSendEventDecision.ignore)
      expect(staleTerminal.ignoreReason).assertEqual(MtaSendEventIgnoreReason.staleGeneration)
    })

    it('mtaSendEvent_terminalDoesNotCreateSession', 0, () => {
      // 无活跃会话时终态事件不得诞生会话（幽灵会话的结构性防御）
      let stages: Array<MtaSenderStage> = [MtaSenderStage.COMPLETED, MtaSenderStage.PARTIAL,
        MtaSenderStage.FAILED, MtaSenderStage.CANCELLED]
      for (let i = 0; i < stages.length; i++) {
        let plan = decideMtaSendEvent(1, 1, false, false, stages[i])
        expect(plan.decision).assertEqual(MtaSendEventDecision.ignore)
        expect(plan.ignoreReason).assertEqual(MtaSendEventIgnoreReason.terminalWithoutActiveSession)
        expect(plan.terminal).assertTrue()
      }
    })

    it('mtaSendEvent_closedOrNotStartedIgnored', 0, () => {
      // 已终结且无活跃会话：迟到的非终态事件不得改变状态
      let closed = decideMtaSendEvent(1, 1, false, true, MtaSenderStage.TRANSFERRING)
      expect(closed.decision).assertEqual(MtaSendEventDecision.ignore)
      expect(closed.ignoreReason).assertEqual(MtaSendEventIgnoreReason.closedWithoutActiveSession)
      // 未开始（空闲）：不得生成会话
      let idle = decideMtaSendEvent(1, 1, false, false, MtaSenderStage.IDLE)
      expect(idle.ignoreReason).assertEqual(MtaSendEventIgnoreReason.notStarted)
    })

    it('mtaSendEvent_createAdvanceFinish', 0, () => {
      // 进行中且无活跃会话 → 创建并推进
      let create = decideMtaSendEvent(1, 1, false, false, MtaSenderStage.TRANSFERRING)
      expect(create.decision).assertEqual(MtaSendEventDecision.createAndAdvance)
      // 进行中且已有活跃会话 → 仅推进
      let advance = decideMtaSendEvent(1, 1, true, false, MtaSenderStage.WAITING_WS)
      expect(advance.decision).assertEqual(MtaSendEventDecision.advance)
      // 终态且已有活跃会话 → 终结
      let finish = decideMtaSendEvent(1, 1, true, false, MtaSenderStage.CANCELLED)
      expect(finish.decision).assertEqual(MtaSendEventDecision.finish)
      expect(finish.terminal).assertTrue()
      // 取消通知中为非终态：只推进、不终结
      let notifying = decideMtaSendEvent(1, 1, true, false, MtaSenderStage.CANCEL_NOTIFYING)
      expect(notifying.decision).assertEqual(MtaSendEventDecision.advance)
      expect(notifying.terminal).assertFalse()
    })

    it('mtaSendInstanceEnd_generationAwareTeardown', 0, () => {
      // 当前代次：归还接收服务记账 + 安排资源延迟回收
      let current: MtaSendEndPlan = decideMtaSendInstanceEnd(3, 3)
      expect(current.resumeReceiveAccounting).assertTrue()
      expect(current.scheduleTeardown).assertTrue()
      // 旧代次：仍归还记账，但不得安排回收（防旧实例销毁当前生效实例）
      let stale: MtaSendEndPlan = decideMtaSendInstanceEnd(2, 3)
      expect(stale.resumeReceiveAccounting).assertTrue()
      expect(stale.scheduleTeardown).assertFalse()
    })

    it('mtaSendInstanceEnd_accountingNetZero', 0, () => {
      // 等价假实例序列：实例 1 暂停接收服务后，实例 2 取代它（再次暂停）；
      // 实例 1 随后异步收尾结束，实例 2 再结束。断言记账净变化为 0 且回收只安排一次。
      let accounting = 1 // 实例 1 开始：暂停接收服务
      accounting++ // 实例 2 开始：再次暂停接收服务
      let stale = decideMtaSendInstanceEnd(1, 2)
      if (stale.resumeReceiveAccounting) {
        accounting--
      }
      let teardownScheduled = stale.scheduleTeardown ? 1 : 0
      let current = decideMtaSendInstanceEnd(2, 2)
      if (current.resumeReceiveAccounting) {
        accounting--
      }
      if (current.scheduleTeardown) {
        teardownScheduled++
      }
      expect(accounting).assertEqual(0)
      expect(teardownScheduled).assertEqual(1)
    })
  })
}
