import { describe, it, expect } from '@ohos/hypium'
import {
  computeTransferFileProgress, computeSessionProgress,
  buildSendSessionSnapshots, buildReceiveSessionSnapshots,
  buildMtaReceiveSessionSnapshot, computeOverallTransferSnapshot,
  TransferDirection, TransferSessionSnapshot, ReceiveSessionData
} from '../../../../main/ets/utils/TransferProgressUtil'
import {
  TransferFileDescriptor,
  SendSessionState,
  TransferProgress,
  SendSessionStatus
} from '../../../../main/ets/model/Types'
import {
  ReceiverState,
  ReceiverStage,
  ReceiveRequest,
  DownloadProgress,
  isMtaReceivingStage
} from '../../../../main/ets/model/mta/MtaProtocolModels'

// 传输页逐文件进度与会话进度聚合的纯逻辑单测（无 UIContext/native 依赖）。

// 构造发送会话的便捷封装（模块级：ArkTS 不允许嵌套函数）
function makeSendSession(id: string, alias: string, status: SendSessionStatus,
  fileSizes: Array<number>): SendSessionState {
  let state: SendSessionState = {
    sessionId: id,
    targetIp: '10.0.0.1',
    targetAlias: alias,
    status: status,
    files: [],
    hashedFileCount: 0,
    totalFiles: fileSizes.length
  }
  for (let i = 0; i < fileSizes.length; i++) {
    state.files.push({
      fileId: id + '_f' + i,
      filePath: 'p' + i,
      fileName: 'f' + i + '.bin',
      fileType: 'x',
      size: fileSizes[i]
    })
  }
  return state
}

// 构造单会话快照的便捷封装
function makeSnapshot(id: string, direction: TransferDirection, name: string,
  bytesSent: number, totalBytes: number, active: boolean, success: boolean): TransferSessionSnapshot {
  let snapshot: TransferSessionSnapshot = {
    sessionId: id,
    direction: direction,
    displayName: name,
    bytesSent: bytesSent,
    totalBytes: totalBytes,
    active: active,
    success: success
  }
  return snapshot
}

export default function TransferProgressTest() {
  describe('TransferProgressTest', () => {
    it('singleFile_waiting_0', 0, () => {
      let infos: Array<TransferFileDescriptor> = [
        {
          fileId: 'f1',
          fileName: 'a.bin',
          size: 1000,
          fileType: 'application/octet-stream'
        }
      ]
      let result = computeTransferFileProgress(infos, {})
      expect(result.length).assertEqual(1)
      expect(result[0].percent).assertEqual(0)
      expect(result[0].status).assertEqual('waiting')
    })

    it('singleFile_partial_percent', 0, () => {
      let infos: Array<TransferFileDescriptor> = [
        {
          fileId: 'f1',
          fileName: 'a.bin',
          size: 200,
          fileType: 'application/octet-stream'
        }
      ]
      let perFile: Record<string, number> = { 'f1': 50 }
      let result = computeTransferFileProgress(infos, perFile)
      expect(result[0].percent).assertEqual(25)
      expect(result[0].bytesSent).assertEqual(50)
      expect(result[0].status).assertEqual('transferring')
    })

    it('singleFile_completed_full', 0, () => {
      let infos: Array<TransferFileDescriptor> = [
        {
          fileId: 'f1',
          fileName: 'a.bin',
          size: 100,
          fileType: 'application/octet-stream'
        }
      ]
      let perFile: Record<string, number> = { 'f1': 100 }
      let result = computeTransferFileProgress(infos, perFile)
      expect(result[0].percent).assertEqual(100)
      expect(result[0].status).assertEqual('completed')
    })

    it('multiFile_denominator_uses_each_size', 0, () => {
      let infos: Array<TransferFileDescriptor> = [
        {
          fileId: 'f1',
          fileName: 'a.bin',
          size: 1000,
          fileType: 'application/octet-stream'
        },
        {
          fileId: 'f2',
          fileName: 'b.bin',
          size: 500,
          fileType: 'application/octet-stream'
        }
      ]
      let perFile: Record<string, number> = { 'f1': 250, 'f2': 500 }
      let result = computeTransferFileProgress(infos, perFile)
      // 各文件以自身 size 为分母求百分比
      expect(result[0].percent).assertEqual(25)
      expect(result[1].percent).assertEqual(100)
      expect(result[1].status).assertEqual('completed')
    })

    it('completedFile_afterActiveProgressRemoved_kept', 0, () => {
      // perFileMaxSent 保留已完成文件的贡献（即使 activeProgress 已移除该文件条目）
      let infos: Array<TransferFileDescriptor> = [
        {
          fileId: 'f1',
          fileName: 'a.bin',
          size: 100,
          fileType: 'application/octet-stream'
        }
      ]
      let perFile: Record<string, number> = { 'f1': 100 }
      let result = computeTransferFileProgress(infos, perFile)
      expect(result[0].bytesSent).assertEqual(100)
      expect(result[0].percent).assertEqual(100)
      expect(result[0].status).assertEqual('completed')
    })

    it('existing_instances_reused_inPlace', 0, () => {
      // 传入 existing 时同 fileId 复用实例（原地更新进度），新增文件新建实例
      let infos: Array<TransferFileDescriptor> = [
        {
          fileId: 'f1',
          fileName: 'a.bin',
          size: 100,
          fileType: 'application/octet-stream'
        },
        {
          fileId: 'f2',
          fileName: 'b.bin',
          size: 200,
          fileType: 'application/octet-stream'
        }
      ]
      let first = computeTransferFileProgress(infos.slice(0, 1), { 'f1': 40 })
      let second = computeTransferFileProgress(infos, { 'f1': 80, 'f2': 200 }, first)
      expect(second.length).assertEqual(2)
      // f1 复用同一实例且进度原地更新
      expect(second[0] === first[0]).assertTrue()
      expect(second[0].percent).assertEqual(80)
      expect(second[0].status).assertEqual('transferring')
      // f2 为新增文件，新建实例
      expect(second[1] === first[0]).assertFalse()
      expect(second[1].percent).assertEqual(100)
      expect(second[1].status).assertEqual('completed')
    })

    it('sessionProgress_aggregates_per_device', 0, () => {
      let sessions: Array<SendSessionState> = [
        {
          sessionId: 's1',
          targetIp: '10.0.0.1',
          targetAlias: 'alpha',
          status: SendSessionStatus.sending,
          files: [{
            fileId: 'f1',
            filePath: 'a',
            fileName: 'a.bin',
            fileType: 'x',
            size: 1000
          }],
          hashedFileCount: 0,
          totalFiles: 1
        },
        {
          sessionId: 's2',
          targetIp: '10.0.0.2',
          targetAlias: 'beta',
          status: SendSessionStatus.sending,
          files: [{
            fileId: 'f2',
            filePath: 'b',
            fileName: 'b.bin',
            fileType: 'x',
            size: 500
          }],
          hashedFileCount: 0,
          totalFiles: 1
        }
      ]
      let active: Array<TransferProgress> = [
        {
          sessionId: 's1',
          fileId: 'f1',
          bytesSent: 250,
          totalBytes: 1000,
          filePath: 'a'
        },
        {
          sessionId: 's2',
          fileId: 'f2',
          bytesSent: 500,
          totalBytes: 500,
          filePath: 'b'
        }
      ]
      let progress = computeSessionProgress(sessions, active)
      expect(progress['s1']).assertEqual(25)
      expect(progress['s2']).assertEqual(100)
    })

    it('sessionProgress_fallback_by_fileId_when_sessionId_mismatch', 0, () => {
      // 多目标模式：逻辑会话 id（multi_xxx_i）与接收方会话 id（UUID）不一致，
      // 但进度仍应通过 fileId 归属匹配到正确会话
      let sessions: Array<SendSessionState> = [
        {
          sessionId: 'multi_abc_0',
          targetIp: '10.0.0.1',
          targetAlias: 'alpha',
          status: SendSessionStatus.sending,
          files: [{
            fileId: 'f1',
            filePath: 'a',
            fileName: 'a.bin',
            fileType: 'x',
            size: 1000
          }],
          hashedFileCount: 0,
          totalFiles: 1
        }
      ]
      // activeProgress 的 sessionId 是接收方 UUID，与逻辑会话 id 不匹配
      let active: Array<TransferProgress> = [
        {
          sessionId: 'recv-uuid-1234',
          fileId: 'f1',
          bytesSent: 500,
          totalBytes: 1000,
          filePath: 'a'
        }
      ]
      let progress = computeSessionProgress(sessions, active)
      // 通过 fileId 回退匹配，进度应为 50%
      expect(progress['multi_abc_0']).assertEqual(50)
    })

    it('sessionProgress_no_activeProgress_yields_zero', 0, () => {
      // 非终态会话 + activeProgress 为空 → 0%（进度条初始状态）
      let sessions: Array<SendSessionState> = [
        {
          sessionId: 's1',
          targetIp: '10.0.0.1',
          targetAlias: 'alpha',
          status: SendSessionStatus.sending,
          files: [{
            fileId: 'f1',
            filePath: 'a',
            fileName: 'a.bin',
            fileType: 'x',
            size: 1000
          }],
          hashedFileCount: 0,
          totalFiles: 1
        }
      ]
      let progress = computeSessionProgress(sessions, [])
      expect(progress['s1']).assertEqual(0)
    })

    it('sessionProgress_finishedWithErrors_noTransfer_zero', 0, () => {
      // finishedWithErrors 且无任何进度事件（未传输即失败，如协议不匹配被拒绝）
      // → 按实际聚合字节计算，进度为 0%，而非强制 100%
      let sessions: Array<SendSessionState> = [
        {
          sessionId: 's1',
          targetIp: '10.0.0.1',
          targetAlias: 'alpha',
          status: SendSessionStatus.finishedWithErrors,
          files: [{
            fileId: 'f1',
            filePath: 'a',
            fileName: 'a.bin',
            fileType: 'x',
            size: 1000
          }],
          hashedFileCount: 0,
          totalFiles: 1
        }
      ]
      let progress = computeSessionProgress(sessions, [])
      expect(progress['s1']).assertEqual(0)
    })

    it('sessionProgress_finishedWithErrors_partialTransfer_realPercent', 0, () => {
      // finishedWithErrors 且已有部分传输字节 → 进度按实际聚合字节呈现真实百分比
      let sessions: Array<SendSessionState> = [
        {
          sessionId: 's1',
          targetIp: '10.0.0.1',
          targetAlias: 'alpha',
          status: SendSessionStatus.finishedWithErrors,
          files: [{
            fileId: 'f1',
            filePath: 'a',
            fileName: 'a.bin',
            fileType: 'x',
            size: 1000
          }],
          hashedFileCount: 0,
          totalFiles: 1
        }
      ]
      let active: Array<TransferProgress> = [
        {
          sessionId: 's1',
          fileId: 'f1',
          bytesSent: 500,
          totalBytes: 1000,
          filePath: 'a'
        }
      ]
      let progress = computeSessionProgress(sessions, active)
      expect(progress['s1']).assertEqual(50)
    })

    it('sessionProgress_finished_display_100', 0, () => {
      let sessions: Array<SendSessionState> = [
        {
          sessionId: 's1',
          targetIp: '10.0.0.1',
          targetAlias: 'alpha',
          status: SendSessionStatus.finished,
          files: [{
            fileId: 'f1',
            filePath: 'a',
            fileName: 'a.bin',
            fileType: 'x',
            size: 1000
          }],
          hashedFileCount: 0,
          totalFiles: 1
        }
      ]
      // activeProgress 已清除，字节为 0，但终态会话仍按 100% 呈现
      let progress = computeSessionProgress(sessions, [])
      expect(progress['s1']).assertEqual(100)
    })
  })

  // ── 后台通知/托盘聚合快照（computeOverallTransferSnapshot 及构建函数） ──

  describe('OverallTransferSnapshotTest', () => {
    it('empty_input_not_active_not_finished', 0, () => {
      let overall = computeOverallTransferSnapshot([])
      expect(overall.active).assertFalse()
      expect(overall.allFinished).assertFalse()
      expect(overall.percent).assertEqual(0)
      expect(overall.sessionCount).assertEqual(0)
      expect(overall.deviceCount).assertEqual(0)
    })

    it('multiSession_weighted_aggregation', 0, () => {
      // 两台设备并发：A 1000B 已传 250，B 500B 已传 500 → 加权 50%
      let sessions: Array<TransferSessionSnapshot> = [
        makeSnapshot('s1', TransferDirection.send, 'alpha', 250, 1000, true, false),
        makeSnapshot('s2', TransferDirection.send, 'beta', 500, 500, true, false)
      ]
      let overall = computeOverallTransferSnapshot(sessions)
      expect(overall.active).assertTrue()
      expect(overall.percent).assertEqual(50)
      expect(overall.bytesSent).assertEqual(750)
      expect(overall.totalBytes).assertEqual(1500)
      expect(overall.sessionCount).assertEqual(2)
      expect(overall.deviceCount).assertEqual(2)
    })

    it('mixed_direction_counts_devices_once', 0, () => {
      // 混合方向：发送给 alpha + 从 alpha 接收 → 设备数去重为 1
      let sessions: Array<TransferSessionSnapshot> = [
        makeSnapshot('s1', TransferDirection.send, 'alpha', 100, 200, true, false),
        makeSnapshot('r1', TransferDirection.receive, 'alpha', 100, 400, true, false)
      ]
      let overall = computeOverallTransferSnapshot(sessions)
      expect(overall.sessionCount).assertEqual(2)
      expect(overall.deviceCount).assertEqual(1)
      expect(overall.percent).assertEqual(50)
    })

    it('terminal_sessions_excluded_from_progress', 0, () => {
      // 已完成会话不进入进行中进度聚合：仅剩活跃会话的进度
      let sessions: Array<TransferSessionSnapshot> = [
        makeSnapshot('s1', TransferDirection.send, 'alpha', 1000, 1000, false, true),
        makeSnapshot('s2', TransferDirection.send, 'beta', 0, 1000, true, false)
      ]
      let overall = computeOverallTransferSnapshot(sessions)
      expect(overall.active).assertTrue()
      expect(overall.percent).assertEqual(0)
      expect(overall.sessionCount).assertEqual(1)
    })

    it('all_finished_terminal_aggregation', 0, () => {
      let sessions: Array<TransferSessionSnapshot> = [
        makeSnapshot('s1', TransferDirection.send, 'alpha', 1000, 1000, false, true),
        makeSnapshot('r1', TransferDirection.receive, 'beta', 500, 500, false, true)
      ]
      let overall = computeOverallTransferSnapshot(sessions)
      expect(overall.active).assertFalse()
      expect(overall.allFinished).assertTrue()
      expect(overall.hasFailure).assertFalse()
      expect(overall.percent).assertEqual(100)
    })

    it('all_finished_with_failure_flag', 0, () => {
      let sessions: Array<TransferSessionSnapshot> = [
        makeSnapshot('s1', TransferDirection.send, 'alpha', 1000, 1000, false, true),
        makeSnapshot('s2', TransferDirection.send, 'beta', 300, 1000, false, false)
      ]
      let overall = computeOverallTransferSnapshot(sessions)
      expect(overall.allFinished).assertTrue()
      expect(overall.hasFailure).assertTrue()
      // 失败会话按实际字节：1300/2000 = 65%
      expect(overall.percent).assertEqual(65)
    })

    it('monotonic_percent_with_prev', 0, () => {
      // 会话退出导致分母骤变：原始 40% 但上次展示 60% → 防回跳保持 60%
      let sessions: Array<TransferSessionSnapshot> = [
        makeSnapshot('s2', TransferDirection.send, 'beta', 400, 1000, true, false)
      ]
      let overall = computeOverallTransferSnapshot(sessions, 60)
      expect(overall.percent).assertEqual(60)
      // 原始进度更高时按原始值
      let higher = computeOverallTransferSnapshot(sessions, 20)
      expect(higher.percent).assertEqual(40)
    })

    it('sendSnapshots_multiTarget_fileId_attribution', 0, () => {
      // 多目标：逻辑会话 id 与进度事件会话 id 不一致，按 fileId 回退归属
      let sessions: Array<SendSessionState> = [
        makeSendSession('multi_abc_0', 'alpha', SendSessionStatus.sending, [1000])
      ]
      let active: Array<TransferProgress> = [
        {
          sessionId: 'recv-uuid-1234',
          fileId: 'multi_abc_0_f0',
          bytesSent: 500,
          totalBytes: 1000,
          filePath: 'a'
        }
      ]
      let snapshots = buildSendSessionSnapshots(sessions, active)
      expect(snapshots.length).assertEqual(1)
      expect(snapshots[0].bytesSent).assertEqual(500)
      expect(snapshots[0].totalBytes).assertEqual(1000)
      expect(snapshots[0].active).assertTrue()
      expect(snapshots[0].direction).assertEqual(TransferDirection.send)
    })

    it('sendSnapshots_finished_backfills_totalBytes', 0, () => {
      // finished 会话 activeProgress 已清除 → 字节补齐到总分母（不归零）
      let sessions: Array<SendSessionState> = [
        makeSendSession('s1', 'alpha', SendSessionStatus.finished, [800, 200])
      ]
      let snapshots = buildSendSessionSnapshots(sessions, [])
      expect(snapshots[0].bytesSent).assertEqual(1000)
      expect(snapshots[0].totalBytes).assertEqual(1000)
      expect(snapshots[0].active).assertFalse()
      expect(snapshots[0].success).assertTrue()
    })

    it('sendSnapshots_failed_keeps_actual_bytes', 0, () => {
      // finishedWithErrors 按实际聚合字节（未传输即失败为 0）
      let sessions: Array<SendSessionState> = [
        makeSendSession('s1', 'alpha', SendSessionStatus.finishedWithErrors, [1000])
      ]
      let active: Array<TransferProgress> = [
        {
          sessionId: 's1',
          fileId: 's1_f0',
          bytesSent: 400,
          totalBytes: 1000,
          filePath: 'a'
        }
      ]
      let snapshots = buildSendSessionSnapshots(sessions, active)
      expect(snapshots[0].bytesSent).assertEqual(400)
      expect(snapshots[0].success).assertFalse()
    })

    it('receiveSnapshots_states_mapping', 0, () => {
      let data: Array<ReceiveSessionData> = [
        { sessionId: 'r1', senderAlias: 'alpha', state: 'sending', fileSizes: [600, 400] },
        { sessionId: 'r2', senderAlias: 'beta', state: 'finished', fileSizes: [300] },
        { sessionId: 'r3', senderAlias: 'gamma', state: 'failed', fileSizes: [200] }
      ]
      let active: Array<TransferProgress> = [
        { sessionId: 'r1', fileId: 'f1', bytesSent: 300, totalBytes: 600, filePath: 'a' },
        { sessionId: 'r1', fileId: 'f2', bytesSent: 100, totalBytes: 400, filePath: 'b' },
        { sessionId: 'r3', fileId: 'g1', bytesSent: 50, totalBytes: 200, filePath: 'c' }
      ]
      let snapshots = buildReceiveSessionSnapshots(data, active)
      expect(snapshots.length).assertEqual(3)
      // sending：400/1000
      expect(snapshots[0].active).assertTrue()
      expect(snapshots[0].bytesSent).assertEqual(400)
      expect(snapshots[0].totalBytes).assertEqual(1000)
      // finished：字节补齐到总分母
      expect(snapshots[1].active).assertFalse()
      expect(snapshots[1].bytesSent).assertEqual(300)
      expect(snapshots[1].success).assertTrue()
      // failed：按实际字节
      expect(snapshots[2].active).assertFalse()
      expect(snapshots[2].bytesSent).assertEqual(50)
      expect(snapshots[2].success).assertFalse()
    })

    it('mtaSnapshot_transferring_uses_request_totalSize', 0, () => {
      // 分母用 receiveRequest.totalSize 而非 progress.totalBytes
      let state = new ReceiverState()
      state.stage = ReceiverStage.DOWNLOADING
      let request = new ReceiveRequest()
      request.totalSize = 2000
      request.senderName = 'mta-sender'
      state.receiveRequest = request
      let progress = new DownloadProgress()
      progress.receivedBytes = 500
      progress.totalBytes = 0
      state.progress = progress
      let snapshot = buildMtaReceiveSessionSnapshot(state)
      expect(snapshot !== undefined).assertTrue()
      expect(snapshot!.bytesSent).assertEqual(500)
      expect(snapshot!.totalBytes).assertEqual(2000)
      expect(snapshot!.displayName).assertEqual('mta-sender')
      expect(snapshot!.active).assertTrue()
      expect(snapshot!.direction).assertEqual(TransferDirection.mtaReceive)
    })

    it('mtaSnapshot_request_received_excluded', 0, () => {
      // 等待用户确认阶段不进入聚合
      let state = new ReceiverState()
      state.stage = ReceiverStage.REQUEST_RECEIVED
      expect(buildMtaReceiveSessionSnapshot(state)).assertUndefined()
      // 空闲/待命同样排除
      state.stage = ReceiverStage.IDLE
      expect(buildMtaReceiveSessionSnapshot(state)).assertUndefined()
      state.stage = ReceiverStage.SERVICE_RUNNING
      expect(buildMtaReceiveSessionSnapshot(state)).assertUndefined()
    })

    it('mtaSnapshot_terminal_completed_and_failed', 0, () => {
      let state = new ReceiverState()
      state.stage = ReceiverStage.COMPLETED
      let request = new ReceiveRequest()
      request.totalSize = 1000
      request.senderName = 'mta-sender'
      state.receiveRequest = request
      let completed = buildMtaReceiveSessionSnapshot(state)
      expect(completed !== undefined).assertTrue()
      expect(completed!.active).assertFalse()
      expect(completed!.success).assertTrue()
      expect(completed!.bytesSent).assertEqual(1000)

      state.stage = ReceiverStage.FAILED
      let progress = new DownloadProgress()
      progress.receivedBytes = 200
      state.progress = progress
      let failed = buildMtaReceiveSessionSnapshot(state)
      expect(failed !== undefined).assertTrue()
      expect(failed!.success).assertFalse()
      expect(failed!.bytesSent).assertEqual(200)
    })

    it('mtaReceivingStage_boundaries', 0, () => {
      // 建链/下载/落盘为进行中
      expect(isMtaReceivingStage(ReceiverStage.P2P_INFO_RECEIVED)).assertTrue()
      expect(isMtaReceivingStage(ReceiverStage.P2P_CONNECTING)).assertTrue()
      expect(isMtaReceivingStage(ReceiverStage.P2P_CONNECTED)).assertTrue()
      expect(isMtaReceivingStage(ReceiverStage.WS_CONNECTING)).assertTrue()
      expect(isMtaReceivingStage(ReceiverStage.NEGOTIATED)).assertTrue()
      expect(isMtaReceivingStage(ReceiverStage.DOWNLOADING)).assertTrue()
      expect(isMtaReceivingStage(ReceiverStage.SAVING)).assertTrue()
      // 空闲/待命/等待确认/终态不算进行中
      expect(isMtaReceivingStage(ReceiverStage.IDLE)).assertFalse()
      expect(isMtaReceivingStage(ReceiverStage.SERVICE_RUNNING)).assertFalse()
      expect(isMtaReceivingStage(ReceiverStage.REQUEST_RECEIVED)).assertFalse()
      expect(isMtaReceivingStage(ReceiverStage.COMPLETED)).assertFalse()
      expect(isMtaReceivingStage(ReceiverStage.FAILED)).assertFalse()
    })
  })
}
