import { describe, it, expect } from '@ohos/hypium'
import { buildTrayHoverText } from '../../../../main/ets/service/TrayManager'
import {
  OverallTransferSnapshot,
  TransferDirection,
  TransferSessionSnapshot
} from '../../../../main/ets/utils/TransferProgressUtil'

// 托盘 hover 文案决策纯函数单测（文案标签由用例直接传入，与资源解耦）。

// 构造单会话快照（模块级辅助，避免嵌套函数）
function makeSnapshot(sessionId: string, active: boolean, success: boolean): TransferSessionSnapshot {
  let snapshot: TransferSessionSnapshot = {
    sessionId: sessionId,
    direction: TransferDirection.send,
    displayName: 'peer',
    bytesSent: 1,
    totalBytes: 2,
    active: active,
    success: success
  }
  return snapshot
}

// 构造整体聚合快照
function makeOverall(active: boolean, percent: number, allFinished: boolean,
  hasFailure: boolean): OverallTransferSnapshot {
  let overall: OverallTransferSnapshot = {
    active: active,
    percent: percent,
    bytesSent: 1,
    totalBytes: 2,
    sessionCount: 1,
    deviceCount: 1,
    allFinished: allFinished,
    hasFailure: hasFailure
  }
  return overall
}

export default function TrayManagerTest() {
  describe('TrayManagerTest', () => {
    // ── buildTrayHoverText：活跃中 ──

    it('hover_active_appendsRoundedPercent', 0, () => {
      // 活跃中 → "传输中 xx%"，百分比四舍五入取整
      let text = buildTrayHoverText([makeSnapshot('s1', true, false)], makeOverall(true, 44.6, false, false),
        '传输中', '传输完成', '传输失败', '传输完成（部分失败）')
      expect(text).assertEqual('传输中 45%')
    })

    it('hover_active_lowPercent_roundsDown', 0, () => {
      let text = buildTrayHoverText([makeSnapshot('s1', true, false)], makeOverall(true, 30.4, false, false),
        '传输中', '传输完成', '传输失败', '传输完成（部分失败）')
      expect(text).assertEqual('传输中 30%')
    })

    // ── buildTrayHoverText：全部终态 ──

    it('hover_allFinished_success_usesDoneLabel', 0, () => {
      let snapshots = [makeSnapshot('s1', false, true), makeSnapshot('s2', false, true)]
      let text = buildTrayHoverText(snapshots, makeOverall(false, 100, true, false),
        '传输中', '传输完成', '传输失败', '传输完成（部分失败）')
      expect(text).assertEqual('传输完成')
    })

    it('hover_allFinished_allFailed_usesFailedLabel', 0, () => {
      let snapshots = [makeSnapshot('s1', false, false), makeSnapshot('s2', false, false)]
      let text = buildTrayHoverText(snapshots, makeOverall(false, 50, true, true),
        '传输中', '传输完成', '传输失败', '传输完成（部分失败）')
      expect(text).assertEqual('传输失败')
    })

    it('hover_allFinished_mixed_usesPartialLabel', 0, () => {
      let snapshots = [makeSnapshot('s1', false, true), makeSnapshot('s2', false, false)]
      let text = buildTrayHoverText(snapshots, makeOverall(false, 75, true, true),
        '传输中', '传输完成', '传输失败', '传输完成（部分失败）')
      expect(text).assertEqual('传输完成（部分失败）')
    })

    // ── buildTrayHoverText：无会话 ──

    it('hover_noSessions_returnsEmptyToSkipUpdate', 0, () => {
      // 无会话（输入为空且非全部终态）→ 空串，调用方跳过更新
      let text = buildTrayHoverText([], makeOverall(false, 0, false, false),
        '传输中', '传输完成', '传输失败', '传输完成（部分失败）')
      expect(text).assertEqual('')
    })
  })
}
