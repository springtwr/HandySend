// ReceiveHistoryItemTest：接收历史条目的展示判定用例
// 覆盖文本类条目的缩略预览读取与不可用降级、文本类条目的「打开所在目录」判定，
// 以及预览阈值（超阈值不读取内容、不提供预览）与阈值边界行为。
import { describe, it, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import { ReceiveHistoryEntry } from '../../../../main/ets/model/Types'
import { ReceiveHistoryItemViewModel } from '../../../../main/ets/viewmodel/ReceiveHistoryItemViewModel'
import { TEXT_PREVIEW_MAX_BYTES } from '../../../../main/ets/utils/FilePreviewPolicy'
import { getTestCacheDir, writeTestFileToSandbox } from '../helper/TestHelper'

const TEXT_CONTENT: string = '缩略预览第一行\n缩略预览第二行'

/** 构造接收历史条目（字段按用例需要覆盖）。 */
function entryOf(fileName: string, fileType: string, path: string,
  isMessage: boolean, fileSize: number = TEXT_CONTENT.length): ReceiveHistoryEntry {
  return {
    id: 'hist-' + fileName,
    fileName: fileName,
    fileType: fileType,
    path: path,
    savedToGallery: false,
    isMessage: isMessage,
    fileSize: fileSize,
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

    it('textPreview_overLimit_doesNotReadNorProducePreview', 0, async (done: Function) => {
      // 超过预览阈值的文本类条目：文件本身可读，但预览不读取内容、不产缩略预览
      let path = writeTestFileToSandbox('recv_hist_over_limit.txt', TEXT_CONTENT)
      let item = new ReceiveHistoryItemViewModel(
        entryOf('recv_hist_over_limit.txt', 'text/plain', path, false, TEXT_PREVIEW_MAX_BYTES + 1))
      expect(item.isPreviewOverLimit).assertTrue()
      // 超阈值不提供可用的全文预览（与「内容不可用」区分）
      expect(item.canViewFullText).assertFalse()
      await item.loadTextPreview()
      expect(item.previewText).assertEqual('')
      // 复制为用户显式动作，不因超阈值被禁用（保留接收历史页专有项）
      expect(item.canCopyText).assertTrue()
      done()
    })

    it('textPreview_atThreshold_previewableAsBefore', 0, async (done: Function) => {
      // 阈值边界：大小恰好等于阈值按可预览处理，读取行为与阈值内一致
      let path = writeTestFileToSandbox('recv_hist_at_limit.txt', TEXT_CONTENT)
      let item = new ReceiveHistoryItemViewModel(
        entryOf('recv_hist_at_limit.txt', 'text/plain', path, false, TEXT_PREVIEW_MAX_BYTES))
      expect(item.isPreviewOverLimit).assertFalse()
      expect(item.canViewFullText).assertTrue()
      await item.loadTextPreview()
      expect(item.previewText).assertEqual(TEXT_CONTENT)
      expect(item.readFullText()).assertEqual(TEXT_CONTENT)
      done()
    })

    it('textPreview_unknownSize_previewableAsBefore', 0, async (done: Function) => {
      // 大小不可得（为 0）：按可预览处理，不因缺信息误禁
      let path = writeTestFileToSandbox('recv_hist_unknown_size.txt', TEXT_CONTENT)
      let item = new ReceiveHistoryItemViewModel(
        entryOf('recv_hist_unknown_size.txt', 'text/plain', path, false, 0))
      expect(item.isPreviewOverLimit).assertFalse()
      expect(item.canViewFullText).assertTrue()
      await item.loadTextPreview()
      expect(item.previewText).assertEqual(TEXT_CONTENT)
      done()
    })
  })
}
