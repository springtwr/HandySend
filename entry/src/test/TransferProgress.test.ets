import { describe, it, expect } from '@ohos/hypium'
import {
  computeTransferFileProgress, computeSessionProgress
} from '../main/ets/utils/TransferProgressUtil'
import {
  TransferFileDescriptor,
  SendSessionState,
  TransferProgress,
  SendSessionStatus
} from '../main/ets/model/Types'

// 传输页逐文件进度与会话进度聚合的纯逻辑单测（无 UIContext/native 依赖）。
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
}
