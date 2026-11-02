import { describe, it, expect } from '@ohos/hypium'
import { SessionFile, TransferSession } from '../../../../main/ets/model/transfer/TransferSession'
import { hasPreviewableTextPath } from '../../../../main/ets/model/transfer/SessionArchiveRules'

/** 构造一条仅用于归档规则判定的会话。 */
function sessionOf(textMessage: boolean, files: Array<SessionFile>): TransferSession {
  let session = new TransferSession()
  session.textMessage = textMessage
  session.files = files
  return session
}

/** 构造一个带类型/名称/路径的会话文件条目。 */
function fileOf(fileType: string, fileName: string, path: string): SessionFile {
  let file = new SessionFile()
  file.fileType = fileType
  file.fileName = fileName
  file.path = path
  return file
}

// 文本消息成功归档的路径前置条件（与 TransferSessionRegistry.finish 的诊断同源）。
export default function SessionArchiveRulesTest() {
  describe('SessionArchiveRulesTest', () => {
    it('textMessage_requiresTextFilePath', 0, () => {
      // 文本消息：无路径或空文件列表均不可归档
      expect(hasPreviewableTextPath(sessionOf(true, [fileOf('text/plain', 'message.txt', '')])))
        .assertFalse()
      expect(hasPreviewableTextPath(sessionOf(true, []))).assertFalse()
      // 文本消息：至少一个文本类文件带路径即可
      expect(hasPreviewableTextPath(sessionOf(true,
        [fileOf('text/plain', 'message.txt', '/data/text_recv/message.txt')]))).assertTrue()
    })

    it('nonTextMessage_notConstrained', 0, () => {
      // 普通文件/空文件列表不参与文本路径约束
      expect(hasPreviewableTextPath(sessionOf(false,
        [fileOf('application/octet-stream', 'a.bin', '')]))).assertTrue()
      expect(hasPreviewableTextPath(sessionOf(false, []))).assertTrue()
    })

    it('textMessage_textFileByExtensionCounts', 0, () => {
      // MIME 缺失时按扩展名识别文本类文件（与详情页预览判定同源）
      expect(hasPreviewableTextPath(sessionOf(true,
        [fileOf('', 'note.txt', '/data/text_recv/note.txt')]))).assertTrue()
    })

    it('textMessage_nonTextEntryDoesNotSatisfy', 0, () => {
      // 有路径但不是文本类文件，不能满足文本消息的可预览条件
      expect(hasPreviewableTextPath(sessionOf(true,
        [fileOf('application/octet-stream', 'a.bin', '/data/Download/a.bin')]))).assertFalse()
    })
  })
}
