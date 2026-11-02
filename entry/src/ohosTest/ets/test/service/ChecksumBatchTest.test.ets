import { describe, it, expect, beforeAll } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import {
  SendFileItem
} from '../../../../main/ets/model/Types'
import {
  SessionCreateInput,
  SessionDataFlow,
  SessionInitiator,
  defaultCapabilities,
  emptyPeer
} from '../../../../main/ets/model/transfer/TransferSession'
import {
  createSession,
  getSession,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  calculateChecksumsForFiles
} from '../../../../main/ets/service/repository/ChecksumRepository'
import { ChecksumBatchParticipant, joinChecksumBatch } from '../../../../main/ets/service/repository/SendRepository'
import { isCreateChecksums, setCreateChecksums } from '../../../../main/ets/service/repository/SettingsRepository'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import { getTestAppContext } from '../helper/TestContext'
import { writeTestFileToSandbox } from '../helper/TestHelper'

// 校验和批次复用与失败容忍测试：
// 同一共享 items 只计算一次（批次复用），单文件不可读时置空并继续。

const BATCH_KEY: string = 'test-batch'

function batchSessionInput(): SessionCreateInput {
  return {
    protocolKey: BATCH_KEY,
    protocolSessionId: 'batch-1',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: emptyPeer(),
    files: [{
      fileId: 'f0',
      fileName: 'checksum_batch.txt',
      fileType: 'text/plain',
      totalBytes: 31
    }],
    capabilities: defaultCapabilities()
  }
}

/** 与共享 items 按索引对齐的会话文件副本。 */
function sessionFilesOf(shared: Array<SendFileItem>): Array<SendFileItem> {
  let result: Array<SendFileItem> = []
  for (let i = 0; i < shared.length; i++) {
    result.push({
      fileId: 'sess_' + i,
      filePath: shared[i].filePath,
      fileName: shared[i].fileName,
      fileType: shared[i].fileType,
      size: shared[i].size
    })
  }
  return result
}

export default function ChecksumBatchTest() {
  describe('ChecksumBatchTest', () => {
    beforeAll(() => {
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        initAllPreferences(ctx)
      }
    })

    it('batch_reuse_singleComputeAndLateJoinProgress', 0, async (done: Function) => {
      resetRegistry()
      let previous: boolean = isCreateChecksums()
      setCreateChecksums(true)
      try {
        let content: string = 'hello batch reuse'
        let path: string = writeTestFileToSandbox('checksum_batch.txt', content)
        let shared: Array<SendFileItem> = [{
          fileId: 'shared_0',
          filePath: path,
          fileName: 'checksum_batch.txt',
          fileType: 'text/plain',
          size: content.length
        }]
        let s1 = createSession(batchSessionInput())
        let s2 = createSession(batchSessionInput())
        let p1: ChecksumBatchParticipant = {
          unifiedSessionId: s1.id,
          sessionFiles: sessionFilesOf(shared)
        }
        let p2: ChecksumBatchParticipant = {
          unifiedSessionId: s2.id,
          sessionFiles: sessionFilesOf(shared)
        }
        // 第一次加入创建批次并启动计算；第二次加入复用同一批次
        let promise1: Promise<void> = joinChecksumBatch(shared, p1)
        let promise2: Promise<void> = joinChecksumBatch(shared, p2)
        // 同一 items 仅触发一次计算：两次 join 返回同一 promise
        expect(promise1 === promise2).assertTrue()
        // 后到参与会话即时获得当前进度（分母为本次待哈希字节总量）
        let late = getSession(s2.id)
        expect(late !== undefined).assertTrue()
        if (late !== undefined) {
          expect(late.prepTotalBytes).assertEqual(content.length)
        }
        await Promise.all([promise1, promise2])
        // 完成后共享 items 与会话文件副本均获得非空校验和（含后到参与者）
        expect(shared[0].hash !== undefined && shared[0].hash.length === 64).assertTrue()
        let done1 = getSession(s1.id)
        let done2 = getSession(s2.id)
        if (done1 !== undefined && done2 !== undefined) {
          expect(done1.files[0].checksum).assertEqual(shared[0].hash)
          expect(done2.files[0].checksum).assertEqual(shared[0].hash)
        }
      } finally {
        setCreateChecksums(previous)
        resetRegistry()
      }
      done()
    })

    it('failure_tolerance_badFileRemovedAndContinues', 0, async (done: Function) => {
      let previous: boolean = isCreateChecksums()
      setCreateChecksums(true)
      try {
        let goodPath: string = writeTestFileToSandbox('checksum_good.txt', 'good')
        let shared: Array<SendFileItem> = [
          {
            fileId: 'bad',
            filePath: '/nonexistent_dir_xyz/nonexistent.bin',
            fileName: 'nonexistent.bin',
            fileType: 'application/octet-stream',
            size: 10
          },
          {
            fileId: 'good',
            filePath: goodPath,
            fileName: 'checksum_good.txt',
            fileType: 'text/plain',
            size: 4
          }
        ]
        let aggregates: Array<number> = []
        let failedPaths: Array<string> = await calculateChecksumsForFiles(shared, {
          onAggregate: (aggregateBytes: number, totalBytes: number): void => {
            aggregates.push(aggregateBytes)
          },
          shouldContinue: (): boolean => true,
          onCancelIdChanged: (cancelId: string): void => {
          }
        })
        // 不可读文件从列表剔除并返回其路径，任务不中断
        expect(failedPaths.length).assertEqual(1)
        expect(failedPaths[0]).assertEqual('/nonexistent_dir_xyz/nonexistent.bin')
        expect(shared.length).assertEqual(1)
        expect(shared[0].hash !== undefined && shared[0].hash.length === 64).assertTrue()
        // 失败文件同样计入已完成字节，进度不因失败停滞（末次为 10 + 4）
        expect(aggregates[aggregates.length - 1]).assertEqual(14)
      } finally {
        setCreateChecksums(previous)
      }
      done()
    })
    it('failure_multiParticipant_prunesAndBackfills', 0, async (done: Function) => {
      // 多参与者失败：坏文件从共享项与各会话副本同步剔除，好文件哈希正常回填
      resetRegistry()
      let previous: boolean = isCreateChecksums()
      setCreateChecksums(true)
      try {
        let goodPath: string = writeTestFileToSandbox('checksum_multi_good.txt', 'good')
        let shared: Array<SendFileItem> = [
          {
            fileId: 'bad',
            filePath: '/nonexistent_dir_xyz/nonexistent.bin',
            fileName: 'nonexistent.bin',
            fileType: 'application/octet-stream',
            size: 10
          },
          {
            fileId: 'good',
            filePath: goodPath,
            fileName: 'checksum_multi_good.txt',
            fileType: 'text/plain',
            size: 4
          }
        ]
        let s1 = createSession(batchSessionInput())
        let s2 = createSession(batchSessionInput())
        let p1: ChecksumBatchParticipant = {
          unifiedSessionId: s1.id,
          sessionFiles: sessionFilesOf(shared)
        }
        let p2: ChecksumBatchParticipant = {
          unifiedSessionId: s2.id,
          sessionFiles: sessionFilesOf(shared)
        }
        await Promise.all([joinChecksumBatch(shared, p1), joinChecksumBatch(shared, p2)])
        // 坏文件剔除，好文件保留且有 64 位哈希
        expect(shared.length).assertEqual(1)
        expect(shared[0].hash !== undefined && shared[0].hash.length === 64).assertTrue()
        let done1 = getSession(s1.id)
        let done2 = getSession(s2.id)
        if (done1 !== undefined && done2 !== undefined) {
          expect(done1.files.length).assertEqual(1)
          expect(done2.files.length).assertEqual(1)
          expect(done1.files[0].checksum).assertEqual(shared[0].hash)
          expect(done2.files[0].checksum).assertEqual(shared[0].hash)
        }
      } finally {
        setCreateChecksums(previous)
        resetRegistry()
      }
      done()
    })

    it('reused_source_fd_rewinds_offset_before_hashing', 0, async (done: Function) => {
      // 回归：发送/上一次哈希读完会把暂存句柄的共享偏移推到末尾，
      // 复用它计算校验和时必须先归位，否则会从末尾读到空内容
      let previous: boolean = isCreateChecksums()
      setCreateChecksums(true)
      let handle: fs.File | undefined = undefined
      try {
        let content: string = 'rewind before hashing'
        let path: string = writeTestFileToSandbox('checksum_rewind.txt', content)
        handle = await fs.open(path, fs.OpenMode.READ_ONLY)
        // 模拟上一次发送读完后的状态：共享偏移停在文件末尾
        let buffer: ArrayBuffer = new ArrayBuffer(content.length)
        fs.readSync(handle.fd, buffer)
        // 基准：不复用句柄、按路径打开计算的哈希
        let baseline: Array<SendFileItem> = [{
          fileId: 'baseline',
          filePath: path,
          fileName: 'checksum_rewind.txt',
          fileType: 'text/plain',
          size: content.length
        }]
        await calculateChecksumsForFiles(baseline)
        // 复用已到末尾的暂存句柄：归位后应与基准一致
        let reused: Array<SendFileItem> = [{
          fileId: 'reused',
          filePath: path,
          fileName: 'checksum_rewind.txt',
          fileType: 'text/plain',
          size: content.length,
          sourceFd: handle.fd
        }]
        await calculateChecksumsForFiles(reused)
        expect(baseline[0].hash !== undefined && baseline[0].hash.length === 64).assertTrue()
        expect(reused[0].hash).assertEqual(baseline[0].hash)
      } finally {
        if (handle !== undefined) {
          fs.closeSync(handle)
        }
        setCreateChecksums(previous)
      }
      done()
    })
  })
}
