// ReceiveBehaviorTest：接收行为测试——文本消息与文本文件的区分
//
// LocalSend 协议中：手动输入的文本消息（text/plain + preview 携带内容）
// 与文件选择器选取的 txt 文件（text/plain 无 preview）通过 preview 有无区分。
// 验证 handlePrepareUploadEventTyped 的 hasMessage 判定在自动确认开关
// （AutoConfirmMode.on）下的行为差异：
//   - 文本消息（有 preview）→ 不自动接受（需用户确认文本内容）
//   - 文本文件（无 preview）→ 自动接受
//   - preview 字段在 pendingRequests 中保留（后续文本消息消费依赖它）
import { describe, it, expect, afterAll } from '@ohos/hypium'
import {
  handlePrepareUploadEventTyped,
  getPendingRequests
} from '../../../../main/ets/service/repository/ReceiveRepository'
import { setAutoConfirmMode } from '../../../../main/ets/service/repository/SettingsRepository'
import {
  NativePrepareUploadEvent, NativeTransferFileInfo
} from '../../../../main/ets/model/NativeTypes'
import { AutoConfirmMode } from '../../../../main/ets/model/Types'

function makePrepareUpload(sessionId: string, files: Array<NativeTransferFileInfo>): NativePrepareUploadEvent {
  let event: NativePrepareUploadEvent = {
    type: 'prepareUpload',
    sessionId: sessionId,
    senderIp: '192.168.1.10',
    senderAlias: 'SenderPC',
    senderFingerprint: 'behavior_fp_' + sessionId,
    senderDeviceType: 'mobile',
    senderDeviceModel: 'HarmonyOS',
    certFingerprint: '',
    files: files
  }
  return event
}

function findPending(sessionId: string): PendingRequestLike | undefined {
  let reqs = getPendingRequests()
  for (let i = 0; i < reqs.length; i++) {
    if (reqs[i].sessionId === sessionId) {
      return reqs[i]
    }
  }
  return undefined
}

// PendingRequest 的部分形状（避免引入应用层类型强耦合）
interface PendingRequestLike {
  sessionId: string
  autoConfirmed: boolean
  files: Array<PendingFileLike>
}

interface PendingFileLike {
  fileId: string
  preview?: string
}

export default function ReceiveBehaviorTest() {
  describe('ReceiveBehaviorTest', () => {
    afterAll(() => {
      // 恢复默认自动确认模式，避免影响其他套件
      setAutoConfirmMode(AutoConfirmMode.off)
    })

    it('text_message_with_preview_not_auto_accepted', 0, () => {
      setAutoConfirmMode(AutoConfirmMode.on)
      // 手动输入文本消息：text/plain + preview 携带文本内容
      let event = makePrepareUpload('behavior_msg_1', [{
        fileId: 'm1',
        fileName: 'message.txt',
        size: 5,
        fileType: 'text/plain',
        preview: 'hello',
        sha256: undefined
      }])
      handlePrepareUploadEventTyped(event)

      let pending = findPending('behavior_msg_1')
      expect(pending !== undefined).assertTrue()
      if (pending !== undefined) {
        // 文本消息（有 preview）不应自动接受——需用户确认内容
        expect(pending.autoConfirmed).assertFalse()
      }
    })

    it('text_file_without_preview_auto_accepted', 0, () => {
      setAutoConfirmMode(AutoConfirmMode.on)
      // 文件选择器选取的 txt 文件：text/plain 无 preview
      let event = makePrepareUpload('behavior_file_1', [{
        fileId: 'f1',
        fileName: 'note.txt',
        size: 100,
        fileType: 'text/plain',
        preview: undefined,
        sha256: undefined
      }])
      handlePrepareUploadEventTyped(event)

      let pending = findPending('behavior_file_1')
      expect(pending !== undefined).assertTrue()
      if (pending !== undefined) {
        // 普通文本文件（无 preview）在 on 模式下自动接受
        expect(pending.autoConfirmed).assertTrue()
      }
    })

    it('preview_preserved_in_pending_request', 0, () => {
      setAutoConfirmMode(AutoConfirmMode.off)
      // 关闭自动确认：请求入队，preview 字段应保留（文本消息消费依赖）
      let event = makePrepareUpload('behavior_msg_2', [{
        fileId: 'm2',
        fileName: 'msg.txt',
        size: 11,
        fileType: 'text/plain',
        preview: 'hello world',
        sha256: undefined
      }])
      handlePrepareUploadEventTyped(event)

      let pending = findPending('behavior_msg_2')
      expect(pending !== undefined).assertTrue()
      if (pending !== undefined) {
        expect(pending.files.length === 1).assertTrue()
        expect(pending.files[0].preview === 'hello world').assertTrue()
      }
    })

    it('waiting_session_held_in_pending_requests', 0, () => {
      // 等待用户确认（waiting）的会话保留在待确认列表
      // （后台无法确认，与 MTA request_received 的处理策略一致）
      setAutoConfirmMode(AutoConfirmMode.off)
      let event = makePrepareUpload('behavior_wait_1', [{
        fileId: 'w1',
        fileName: 'wait.bin',
        size: 50,
        fileType: 'application/octet-stream',
        preview: undefined,
        sha256: undefined
      }])
      handlePrepareUploadEventTyped(event)

      let pending = getPendingRequests()
      let found: boolean = false
      for (let i = 0; i < pending.length; i++) {
        if (pending[i].sessionId === 'behavior_wait_1') {
          found = true
        }
      }
      expect(found).assertTrue()
    })
  })
}
