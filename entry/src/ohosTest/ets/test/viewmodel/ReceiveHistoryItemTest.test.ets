// ReceiveHistoryItemTest：接收历史条目的展示判定用例
// 覆盖文本类条目的缩略预览读取与不可用降级、文本类条目的「打开所在目录」判定。
import { describe, it, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import { ReceiveHistoryEntry } from '../../../../main/ets/model/Types'
import { ReceiveHistoryItemViewModel } from '../../../../main/ets/viewmodel/ReceiveHistoryItemViewModel'
import { getTestCacheDir, writeTestFileToSandbox } from '../helper/TestHelper'

const TEXT_CONTENT: string = '缩略预览第一行\n缩略预览第二行'

/** 构造接收历史条目（字段按用例需要覆盖）。 */
function entryOf(fileName: string, fileType: string, path: string,
  isMessage: boolean): ReceiveHistoryEntry {
  return {
    id: 'hist-' + fileName,
    fileName: fileName,
    fileType: fileType,
    path: path,
    savedToGallery: false,
    isMessage: isMessage,
    fileSize: TEXT_CONTENT.length,
    senderAlias: 'peer',
    timestamp: 1
  }
}

/** 删除测试临时文件（不存在时静默忽略）。 */
function deleteTestFileIfExists(path: string): void {
  try {
    fs.unlinkSync(path);
  } catch (_e) {
  }
}

export default function ReceiveHistoryItemTest() {
  describe('ReceiveHistoryItemTest', () => {
    it('textPreview_readsContentFromRealTextFile', 0, async (done: Function) => {
      let path = writeTestFileToSandbox('recv_hist_preview.txt', TEXT_CONTENT)
      let item = new ReceiveHistoryItemViewModel(
        entryOf('recv_hist_preview.txt', 'text/plain', path, false))
      // 构造期不读盘：预览内容初始为空，读取由列表按需触发
      expect(item.previewText).assertEqual('')
      await item.loadTextPreview()
      expect(item.previewText).assertEqual(TEXT_CONTENT)
      done()
    })

    it('textPreview_textMessageEntry_readableLikeOrdinaryTextFile', 0, async (done: Function) => {
      // 文本消息条目已落盘为真实文件：缩略预览与普通文本文件同口径，不受「消息」语义拦截
      let path = writeTestFileToSandbox('recv_hist_message.txt', TEXT_CONTENT)
      let item = new ReceiveHistoryItemViewModel(
        entryOf('recv_hist_message.txt', 'text/plain', path, true))
      await item.loadTextPreview()
      expect(item.previewText).assertEqual(TEXT_CONTENT)
      done()
    })

    it('textPreview_degradesQuietlyWhenUnavailable', 0, async (done: Function) => {
      let dir = getTestCacheDir()

      // 路径为空（旧数据）：不读取、保持空内容
      let emptyPathItem = new ReceiveHistoryItemViewModel(entryOf('legacy.txt', 'text/plain', '', true))
      await emptyPathItem.loadTextPreview()
      expect(emptyPathItem.previewText).assertEqual('')

      // 文件缺失（已移动/删除）：静默降级为空内容，不抛异常
      let missingPath = dir + '/recv_hist_missing.txt'
      deleteTestFileIfExists(missingPath)
      let missingItem = new ReceiveHistoryItemViewModel(
        entryOf('recv_hist_missing.txt', 'text/plain', missingPath, false))
      await missingItem.loadTextPreview()
      expect(missingItem.previewText).assertEqual('')

      // 非文本类条目：不产生预览内容
      let binaryPath = writeTestFileToSandbox('recv_hist_binary.bin', 'binary payload')
      let binaryItem = new ReceiveHistoryItemViewModel(
        entryOf('recv_hist_binary.bin', 'application/octet-stream', binaryPath, false))
      await binaryItem.loadTextPreview()
      expect(binaryItem.previewText).assertEqual('')
      done()
    })

    it('canOpenContainingFolder_followsPathOnly', 0, () => {
      // 文本消息条目已落盘为真实文件：路径非空即可打开所在目录（不再因「消息」语义被禁用）
      let messageItem = new ReceiveHistoryItemViewModel(
        entryOf('sharedText.txt', 'text/plain', '/data/recv/sharedText.txt', true))
      expect(messageItem.canOpenContainingFolder).assertTrue()

      // 普通文本文件条目：路径非空即为真
      let textItem = new ReceiveHistoryItemViewModel(
        entryOf('note.txt', 'text/plain', '/data/recv/note.txt', false))
      expect(textItem.canOpenContainingFolder).assertTrue()

      // 路径为空（旧数据）：不可打开所在目录
      let legacyItem = new ReceiveHistoryItemViewModel(entryOf('legacy.txt', 'text/plain', '', true))
      expect(legacyItem.canOpenContainingFolder).assertFalse()

      // 非文本文件条目：按路径判定同样为真（既有能力不回归）
      let binaryItem = new ReceiveHistoryItemViewModel(
        entryOf('archive.bin', 'application/octet-stream', '/data/recv/archive.bin', false))
      expect(binaryItem.canOpenContainingFolder).assertTrue()
    })
  })
}
