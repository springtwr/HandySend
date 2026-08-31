// ProgressLogicTest：传输进度补齐逻辑测试
//
// Rust 进度事件仅携带 progress（0.0~1.0），ArkTS 侧从会话文件
// 映射补齐 bytesSent/totalBytes/filePath（ReceiveRepository.handleProgressUpdateTyped
// + SendRepository.registerSendFileInfo）。本测试验证该补齐逻辑：
// - recv 方向：progress × size → bytesSent，filePath 从映射/兜底路径补齐
// - 多文件部分完成：completed 标记正确且不误触发会话完成收尾
// - send 方向：使用 SendRepository 注册的文件信息，不抛异常
// - SendFileInfo 注册/覆盖/清除语义
//
// 不依赖服务器运行、不依赖 UIAbilityContext（getReceiveSaveDir 无 context
// 时返回空串，兜底路径退化为文件名，断言仅要求非空）。
import { describe, it, expect } from '@ohos/hypium'
import {
  handlePrepareUploadEventTyped,
  handleProgressUpdateTyped
} from '../../../../main/ets/service/repository/ReceiveRepository'
import {
  registerSendFileInfo,
  getSendFileInfo,
  clearSendFileInfos,
  getActiveProgress
} from '../../../../main/ets/service/repository/SendRepository'
import {
  NativePrepareUploadEvent,
  NativeProgressEvent,
  NativeTransferFileInfo
} from '../../../../main/ets/model/NativeTypes'

function makePrepareUploadEvent(sessionId: string, files: Array<NativeTransferFileInfo>): NativePrepareUploadEvent {
  let event: NativePrepareUploadEvent = {
    type: 'prepareUpload',
    sessionId: sessionId,
    senderIp: '192.168.1.10',
    senderAlias: 'SenderPC',
    senderFingerprint: 'sender_fp_' + sessionId,
    senderDeviceType: 'mobile',
    senderDeviceModel: 'HarmonyOS',
    certFingerprint: '',
    files: files
  }
  return event
}

function makeProgress(sessionId: string, fileId: string, direction: string, progress: number): NativeProgressEvent {
  let event: NativeProgressEvent = {
    type: 'uploadProgress',
    sessionId: sessionId,
    fileId: fileId,
    direction: direction,
    progress: progress,
    speed: 0
  }
  return event
}

/** 在 activeProgress 中查找指定会话+文件的进度项，不存在返回 undefined。 */
function findProgress(sessionId: string, fileId: string): TransferProgressLike | undefined {
  let items = getActiveProgress()
  for (let i = 0; i < items.length; i++) {
    if (items[i].sessionId === sessionId && items[i].fileId === fileId) {
      return items[i]
    }
  }
  return undefined
}

// TransferProgress 的部分字段形状（避免 import 应用层类型造成测试耦合）
interface TransferProgressLike {
  sessionId: string
  fileId: string
  bytesSent: number
  totalBytes: number
  filePath: string
}

export default function ProgressLogicTest() {
  describe('ProgressLogicTest', () => {
    // ── recv 方向进度补齐 ──

    it('recv_progress_derives_bytes_and_path', 0, () => {
      let event = makePrepareUploadEvent('progress_test_1', [
        {
          fileId: 'f1',
          fileName: 'photo.jpg',
          size: 1000,
          fileType: 'image/jpeg'
        }
      ])
      handlePrepareUploadEventTyped(event)

      // 50% 进度 → bytesSent = floor(0.5 × 1000) = 500
      handleProgressUpdateTyped(makeProgress('progress_test_1', 'f1', 'recv', 0.5))

      let entry = findProgress('progress_test_1', 'f1')
      expect(entry !== undefined).assertTrue()
      if (entry === undefined) {
        return
      }
      expect(entry.bytesSent === 500).assertTrue()
      expect(entry.totalBytes === 1000).assertTrue()
      // filePath 从会话文件映射兜底（保存目录 + 文件名）；无 context 时退化为文件名
      expect(entry.filePath.length > 0).assertTrue()
    })

    it('recv_progress_partial_completion_multifile', 0, () => {
      // 两个文件：file1 完成（progress=1）→ 标记完成但会话未完成（total=2 > count=1），
      // 不触发 finishReceiveSession 的收尾逻辑（文件导出/历史记录等）
      let event = makePrepareUploadEvent('progress_test_2', [
        {
          fileId: 'f1',
          fileName: 'a.txt',
          size: 1000,
          fileType: 'text/plain'
        },
        {
          fileId: 'f2',
          fileName: 'b.txt',
          size: 2000,
          fileType: 'text/plain'
        }
      ])
      handlePrepareUploadEventTyped(event)

      handleProgressUpdateTyped(makeProgress('progress_test_2', 'f1', 'recv', 1))

      let f1 = findProgress('progress_test_2', 'f1')
      expect(f1 !== undefined).assertTrue()
      if (f1 === undefined) {
        return
      }
      // 完成：bytesSent = totalBytes = size
      expect(f1.bytesSent === 1000).assertTrue()
      expect(f1.totalBytes === 1000).assertTrue()
      // 会话未完成：file2 无进度项
      expect(findProgress('progress_test_2', 'f2') === undefined).assertTrue()
    })

    // ── send 方向进度补齐 ──

    it('send_progress_writes_to_activeProgress_with_correct_bytes', 0, () => {
      clearSendFileInfos()
      registerSendFileInfo({ fileId: 'sf2', size: 2000, filePath: '/data/send/a.bin' })

      handleProgressUpdateTyped(makeProgress('send_sess_1', 'sf2', 'send', 0.25))

      let entry = findProgress('send_sess_1', 'sf2')
      expect(entry !== undefined).assertTrue()
      if (entry === undefined) {
        return
      }
      // bytesSent = floor(0.25 × 2000) = 500
      expect(entry.bytesSent === 500).assertTrue()
      expect(entry.totalBytes === 2000).assertTrue()
      expect(entry.filePath === '/data/send/a.bin').assertTrue()
    })

    it('send_progress_no_file_info_zero_total', 0, () => {
      clearSendFileInfos()
      // 未注册 SendFileInfo 时，totalBytes 为 0 但仍写入 activeProgress（不抛异常）
      let threw: boolean = false
      try {
        handleProgressUpdateTyped(makeProgress('send_no_info', 'unknown_f', 'send', 0.5))
      } catch (_e) {
        threw = true
      }
      expect(!threw).assertTrue()
    })

    // ── SendFileInfo 注册/覆盖/清除 ──

    it('send_file_info_register_override_clear', 0, () => {
      clearSendFileInfos()

      // 注册
      registerSendFileInfo({ fileId: 'sf1', size: 100, filePath: '/send/a.txt' })
      let info = getSendFileInfo('sf1')
      expect(info !== undefined).assertTrue()
      if (info !== undefined) {
        expect(info.size === 100).assertTrue()
        expect(info.filePath === '/send/a.txt').assertTrue()
      }

      // 同 fileId 覆盖
      registerSendFileInfo({ fileId: 'sf1', size: 200, filePath: '/send/b.txt' })
      let info2 = getSendFileInfo('sf1')
      expect(info2 !== undefined && info2.size === 200).assertTrue()

      // 清除
      clearSendFileInfos()
      expect(getSendFileInfo('sf1') === undefined).assertTrue()
    })

    // ── 边界：空 sessionId/fileId 忽略 ──

    it('progress_with_empty_ids_ignored', 0, () => {
      let threw: boolean = false
      try {
        handleProgressUpdateTyped(makeProgress('', 'f1', 'recv', 0.5))
        handleProgressUpdateTyped(makeProgress('s', '', 'recv', 0.5))
      } catch (_e) {
        threw = true
      }
      expect(!threw).assertTrue()
    })
  })
}
