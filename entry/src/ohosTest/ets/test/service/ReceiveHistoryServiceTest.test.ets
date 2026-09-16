import { describe, it, expect } from '@ohos/hypium'
import {
  addEntry,
  removeEntry,
  clearAll,
  getHistory,
  updateGallerySavedStatus
} from '../../../../main/ets/service/repository/ReceiveHistoryService'
import { ReceiveHistoryEntry } from '../../../../main/ets/model/Types'
import { getMimeForFileName } from '../../../../main/ets/utils/MimeUtils'

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
      addEntry(makeEntry('h-add-1', 'a.png'))
      addEntry(makeEntry('h-add-2', 'b.png'))
      expect(getHistory().length).assertEqual(2)
      expect(getHistory()[0].id).assertEqual('h-add-1')
      expect(getHistory()[0].fileName).assertEqual('a.png')
    })

    it('addEntry_exceeds_max_removes_oldest', 0, () => {
      clearAll()
      for (let i = 0; i < 201; i++) {
        addEntry(makeEntry('h-max-' + i, 'file-' + i + '.png'))
      }
      expect(getHistory().length).assertEqual(200)
      let firstIdStillPresent: boolean = false
      let list: Array<ReceiveHistoryEntry> = getHistory()
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === 'h-max-0') {
          firstIdStillPresent = true
        }
      }
      expect(firstIdStillPresent).assertFalse()
      expect(getHistory()[199].id).assertEqual('h-max-200')
    })

    it('removeEntry_deletes_by_id', 0, () => {
      clearAll()
      addEntry(makeEntry('h-rm-1', 'a.png'))
      addEntry(makeEntry('h-rm-2', 'b.png'))
      removeEntry('h-rm-1')
      expect(getHistory().length).assertEqual(1)
      expect(getHistory()[0].id).assertEqual('h-rm-2')
    })

    it('clearAll_empties_history', 0, () => {
      clearAll()
      addEntry(makeEntry('h-clear-1', 'a.png'))
      addEntry(makeEntry('h-clear-2', 'b.png'))
      clearAll()
      expect(getHistory().length).assertEqual(0)
    })

    it('removeEntry_nonexistent_no_effect', 0, () => {
      clearAll()
      addEntry(makeEntry('h-rm-none-1', 'a.png'))
      removeEntry('h-ghost-id')
      expect(getHistory().length).assertEqual(1)
    })

    it('addEntry_exactly_max_keeps_all', 0, () => {
      clearAll()
      for (let i = 0; i < 200; i++) {
        addEntry(makeEntry('h-exact-' + i, 'file-' + i + '.png'))
      }
      expect(getHistory().length).assertEqual(200)
      expect(getHistory()[0].id).assertEqual('h-exact-0')
      expect(getHistory()[199].id).assertEqual('h-exact-199')
    })

    // ── MTA 接收历史真实类型：按扩展名解析的 MIME 被如实保存，非通用二进制类型 ──

    it('addEntry_preserves_real_file_type', 0, () => {
      clearAll()
      let jpg: ReceiveHistoryEntry = makeEntry('mta-1_0', 'photo.jpg')
      jpg.fileType = getMimeForFileName(jpg.fileName)
      let pdf: ReceiveHistoryEntry = makeEntry('mta-1_1', 'doc.pdf')
      pdf.fileType = getMimeForFileName(pdf.fileName)
      addEntry(jpg)
      addEntry(pdf)
      expect(getHistory()[0].fileType).assertEqual('image/jpeg')
      expect(getHistory()[1].fileType).assertEqual('application/pdf')
      expect(getHistory()[0].fileType === 'application/octet-stream').assertFalse()
    })

    it('addEntry_unknown_ext_falls_back_to_octet_stream', 0, () => {
      clearAll()
      let unknown: ReceiveHistoryEntry = makeEntry('mta-2_0', 'data.xyz')
      unknown.fileType = getMimeForFileName(unknown.fileName)
      addEntry(unknown)
      expect(getHistory()[0].fileType).assertEqual('application/octet-stream')
    })

    // ── 相册保存结果回写历史标记（按会话 id 前缀匹配） ──

    it('updateGallerySavedStatus_marks_matching_session_entries', 0, () => {
      clearAll()
      addEntry(makeEntry('gallery_1_0', 'a.jpg'))
      addEntry(makeEntry('gallery_1_1', 'b.mp4'))
      addEntry(makeEntry('gallery_2_0', 'c.jpg'))
      updateGallerySavedStatus('gallery_1', true)
      expect(getHistory()[0].savedToGallery).assertTrue()
      expect(getHistory()[1].savedToGallery).assertTrue()
      expect(getHistory()[2].savedToGallery).assertFalse()
    })
  })
}
