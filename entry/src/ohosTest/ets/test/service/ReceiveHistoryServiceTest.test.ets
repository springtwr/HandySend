import { describe, it, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import {
  addEntries,
  removeEntry,
  clearAll,
  getHistory,
  initHistory,
  updateGallerySavedStatus
} from '../../../../main/ets/service/repository/ReceiveHistoryService'
import { ReceiveHistoryEntry } from '../../../../main/ets/model/Types'
import { RECEIVE_HISTORY_CAPACITY } from '../../../../main/ets/model/HistoryCapacity'
import { segmentKey } from '../../../../main/ets/model/HistorySegments'
import { receiveHistoryPreferencesUtil } from '../../../../main/ets/utils/PreferencesUtil'
import { getMimeForFileName } from '../../../../main/ets/utils/MimeUtils'
import { ReceiveHistoryItemViewModel } from '../../../../main/ets/viewmodel/ReceiveHistoryItemViewModel'
import { getTestAppContext } from '../helper/TestContext'

function makeEntry(id: string, fileName: string): ReceiveHistoryEntry {
  let entry: ReceiveHistoryEntry = {
    id: id,
    fileName: fileName,
    fileType: 'image/png',
    path: '/storage/emulated/0/' + fileName,
    savedToGallery: false,
    isMessage: false,
    fileSize: 1024,
    senderAlias: 'sender-test',
    timestamp: 1000
  }
  return entry
}

export default function ReceiveHistoryServiceTest() {
  describe('ReceiveHistoryServiceTest', () => {
    it('addEntry_appends_and_preserves_fields', 0, () => {
      clearAll()
      addEntries([makeEntry('h-add-1', 'a.png')])
      addEntries([makeEntry('h-add-2', 'b.png')])
      expect(getHistory().length).assertEqual(2)
      expect(getHistory()[0].id).assertEqual('h-add-1')
      expect(getHistory()[0].fileName).assertEqual('a.png')
    })

    it('addEntries_exceeds_max_removes_oldest', 0, () => {
      clearAll()
      // 超出上限一条：保留最新的 RECEIVE_HISTORY_CAPACITY 条，最旧一条被 FIFO 丢弃
      for (let i = 0; i < RECEIVE_HISTORY_CAPACITY + 1; i++) {
        addEntries([makeEntry('h-max-' + i, 'file-' + i + '.png')])
      }
      expect(getHistory().length).assertEqual(RECEIVE_HISTORY_CAPACITY)
      let firstIdStillPresent: boolean = false
      let list: Array<ReceiveHistoryEntry> = getHistory()
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === 'h-max-0') {
          firstIdStillPresent = true
        }
      }
      expect(firstIdStillPresent).assertFalse()
      expect(getHistory()[RECEIVE_HISTORY_CAPACITY - 1].id)
        .assertEqual('h-max-' + RECEIVE_HISTORY_CAPACITY)
    })

    it('removeEntry_deletes_by_id', 0, () => {
      clearAll()
      addEntries([makeEntry('h-rm-1', 'a.png')])
      addEntries([makeEntry('h-rm-2', 'b.png')])
      removeEntry('h-rm-1')
      expect(getHistory().length).assertEqual(1)
      expect(getHistory()[0].id).assertEqual('h-rm-2')
    })

    it('clearAll_empties_history', 0, () => {
      clearAll()
      addEntries([makeEntry('h-clear-1', 'a.png')])
      addEntries([makeEntry('h-clear-2', 'b.png')])
      clearAll()
      expect(getHistory().length).assertEqual(0)
    })

    it('removeEntry_nonexistent_no_effect', 0, () => {
      clearAll()
      addEntries([makeEntry('h-rm-none-1', 'a.png')])
      removeEntry('h-ghost-id')
      expect(getHistory().length).assertEqual(1)
    })

    it('addEntries_exactly_max_keeps_all', 0, () => {
      clearAll()
      for (let i = 0; i < RECEIVE_HISTORY_CAPACITY; i++) {
        addEntries([makeEntry('h-exact-' + i, 'file-' + i + '.png')])
      }
      expect(getHistory().length).assertEqual(RECEIVE_HISTORY_CAPACITY)
      expect(getHistory()[0].id).assertEqual('h-exact-0')
      expect(getHistory()[RECEIVE_HISTORY_CAPACITY - 1].id)
        .assertEqual('h-exact-' + (RECEIVE_HISTORY_CAPACITY - 1))
    })

    // ── 批量追加：一次传输的多个文件只落盘一次，结果与逐条追加一致 ──

    it('addEntries_batch_appends_all_in_order', 0, () => {
      clearAll()
      addEntries([makeEntry('h-batch-1', 'a.png'), makeEntry('h-batch-2', 'b.png'),
        makeEntry('h-batch-3', 'c.png')])
      expect(getHistory().length).assertEqual(3)
      expect(getHistory()[0].id).assertEqual('h-batch-1')
      expect(getHistory()[1].id).assertEqual('h-batch-2')
      expect(getHistory()[2].id).assertEqual('h-batch-3')
    })

    it('addEntries_batch_result_equals_single_appends', 0, () => {
      clearAll()
      addEntries([makeEntry('h-eq-1', 'a.png')])
      addEntries([makeEntry('h-eq-2', 'b.png')])
      addEntries([makeEntry('h-eq-3', 'c.png')])
      let sequential: Array<string> = []
      for (let i = 0; i < getHistory().length; i++) {
        sequential.push(getHistory()[i].id)
      }
      clearAll()
      addEntries([makeEntry('h-eq-1', 'a.png'), makeEntry('h-eq-2', 'b.png'),
        makeEntry('h-eq-3', 'c.png')])
      let batched: Array<string> = []
      for (let i = 0; i < getHistory().length; i++) {
        batched.push(getHistory()[i].id)
      }
      expect(batched.length).assertEqual(sequential.length)
      for (let i = 0; i < sequential.length; i++) {
        expect(batched[i]).assertEqual(sequential[i])
      }
    })

    it('addEntries_empty_is_noop', 0, () => {
      clearAll()
      addEntries([])
      expect(getHistory().length).assertEqual(0)
    })

    it('addEntries_single_batch_over_max_trims_to_capacity', 0, () => {
      clearAll()
      // 单批条目数即超上限：整批写入后裁剪到上限，且不发生中间态残留
      let batch: Array<ReceiveHistoryEntry> = []
      for (let i = 0; i < RECEIVE_HISTORY_CAPACITY + 50; i++) {
        batch.push(makeEntry('h-bulk-' + i, 'file-' + i + '.png'))
      }
      addEntries(batch)
      expect(getHistory().length).assertEqual(RECEIVE_HISTORY_CAPACITY)
      // 保留的是本批最后 CAPACITY 条
      expect(getHistory()[0].id).assertEqual('h-bulk-50')
      expect(getHistory()[RECEIVE_HISTORY_CAPACITY - 1].id)
        .assertEqual('h-bulk-' + (RECEIVE_HISTORY_CAPACITY + 49))
    })

    // ── MTA 接收历史真实类型：按扩展名解析的 MIME 被如实保存，非通用二进制类型 ──

    it('addEntry_preserves_real_file_type', 0, () => {
      clearAll()
      let jpg: ReceiveHistoryEntry = makeEntry('mta-1_0', 'photo.jpg')
      jpg.fileType = getMimeForFileName(jpg.fileName)
      let pdf: ReceiveHistoryEntry = makeEntry('mta-1_1', 'doc.pdf')
      pdf.fileType = getMimeForFileName(pdf.fileName)
      addEntries([jpg])
      addEntries([pdf])
      expect(getHistory()[0].fileType).assertEqual('image/jpeg')
      expect(getHistory()[1].fileType).assertEqual('application/pdf')
      expect(getHistory()[0].fileType === 'application/octet-stream').assertFalse()
    })

    it('addEntry_unknown_ext_falls_back_to_octet_stream', 0, () => {
      clearAll()
      let unknown: ReceiveHistoryEntry = makeEntry('mta-2_0', 'data.xyz')
      unknown.fileType = getMimeForFileName(unknown.fileName)
      addEntries([unknown])
      expect(getHistory()[0].fileType).assertEqual('application/octet-stream')
    })

    // ── 相册保存结果回写历史标记（按会话 id 前缀匹配） ──

    it('updateGallerySavedStatus_marks_matching_session_entries', 0, () => {
      clearAll()
      addEntries([makeEntry('gallery_1_0', 'a.jpg')])
      addEntries([makeEntry('gallery_1_1', 'b.mp4')])
      addEntries([makeEntry('gallery_2_0', 'c.jpg')])
      updateGallerySavedStatus('gallery_1', true)
      expect(getHistory()[0].savedToGallery).assertTrue()
      expect(getHistory()[1].savedToGallery).assertTrue()
      expect(getHistory()[2].savedToGallery).assertFalse()
    })

    it('updateGallerySavedStatus_persistsAcrossReload', 0, () => {
      let ctx = getTestAppContext()
      if (ctx === undefined) {
        expect(true).assertTrue()
        return
      }
      // 标记更新须落盘：重载后仍可见，否则脏区间引用比对会漏掉原地修改
      initHistory(ctx)
      clearAll()
      addEntries([makeEntry('reload_1_0', 'a.jpg')])
      updateGallerySavedStatus('reload_1', true)
      initHistory(ctx)
      expect(getHistory().length).assertEqual(1)
      expect(getHistory()[0].savedToGallery).assertTrue()
      expect(getHistory()[0].fileName).assertEqual('a.jpg')
      clearAll()
    })

    it('staleLegacyKey_removedWhenSegmentsExist', 0, () => {
      let ctx = getTestAppContext()
      if (ctx === undefined) {
        expect(true).assertTrue()
        return
      }
      initHistory(ctx)
      clearAll()
      addEntries([makeEntry('seg_1', 'a.jpg')])
      // 模拟崩溃窗口残留：分段已存在时老键仍在
      receiveHistoryPreferencesUtil.setString('receiveHistory', '[]')
      expect(receiveHistoryPreferencesUtil.has('receiveHistory')).assertTrue()
      // 下次加载以段为准并顺手删除老键，避免清空后老键复活历史
      initHistory(ctx)
      expect(getHistory().length).assertEqual(1)
      expect(receiveHistoryPreferencesUtil.has('receiveHistory')).assertFalse()
      expect(receiveHistoryPreferencesUtil.has(segmentKey('receiveHistory', 0))).assertTrue()
      clearAll()
    })

    it('clearAll_removesStaleLegacyKey', 0, () => {
      let ctx = getTestAppContext()
      if (ctx === undefined) {
        expect(true).assertTrue()
        return
      }
      initHistory(ctx)
      clearAll()
      addEntries([makeEntry('seg_2', 'b.jpg')])
      receiveHistoryPreferencesUtil.setString('receiveHistory', '[]')
      // 清空删段的同时删除老键：否则段键清空后的下次加载会误命中老键
      clearAll()
      expect(receiveHistoryPreferencesUtil.has('receiveHistory')).assertFalse()
      expect(receiveHistoryPreferencesUtil.has(segmentKey('receiveHistory', 0))).assertFalse()
      initHistory(ctx)
      expect(getHistory().length).assertEqual(0)
    })

    it('deleteTextFileLinkage_andLegacyTextIgnored', 0, () => {
      clearAll()
      // 文本文件与普通文件一致删除（不再有"文本跳过删除"造成的孤儿文件）
      let ctx = getTestAppContext()
      if (ctx === undefined) {
        expect(true).assertTrue()
        return
      }
      let dir = ctx.cacheDir + '/recv_hist_test'
      try {
        fs.mkdirSync(dir, true)
      } catch (_e) {
      }
      let textPath = dir + '/sharedText.txt'
      let file = fs.openSync(textPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY)
      fs.closeSync(file)
      let textEntry: ReceiveHistoryEntry = {
        id: 'hist-text_0',
        fileName: 'sharedText.txt',
        fileType: 'text/plain',
        path: textPath,
        savedToGallery: false,
        isMessage: true,
        fileSize: 3,
        senderAlias: 'p',
        timestamp: 1
      }
      addEntries([textEntry])
      expect(fs.accessSync(textPath)).assertTrue()
      removeEntry('hist-text_0', true)
      expect(fs.accessSync(textPath)).assertFalse()

      // 旧数据：仅含遗留正文字段、无路径的条目被忽略且不异常（可得性按路径判定）
      let legacy: ReceiveHistoryEntry = {
        id: 'legacy_0',
        fileName: 'sharedText.txt',
        fileType: 'text/plain',
        path: '',
        savedToGallery: false,
        isMessage: true,
        fileSize: 3,
        senderAlias: 'p',
        timestamp: 1,
        textContent: 'legacy content'
      }
      let itemVm = new ReceiveHistoryItemViewModel(legacy)
      expect(itemVm.canViewFullText).assertFalse()
      // 清空历史同样删除文本文件
      addEntries([textEntry])
      let file2 = fs.openSync(textPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY)
      fs.closeSync(file2)
      clearAll(true)
      expect(fs.accessSync(textPath)).assertFalse()
    })
  })
}
