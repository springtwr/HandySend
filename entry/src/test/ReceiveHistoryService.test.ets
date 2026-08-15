import { describe, it, expect } from '@ohos/hypium'
import { addEntry, removeEntry, clearAll, getHistory } from '../main/ets/service/ReceiveHistoryService'
import { ReceiveHistoryEntry } from '../main/ets/model/Types'

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
    it('addEntry_appends_increases_length', 0, () => {
      clearAll()
      addEntry(makeEntry('h-add-1', 'a.png'))
      addEntry(makeEntry('h-add-2', 'b.png'))
      expect(getHistory().length).assertEqual(2)
    })

    it('addEntry_exceeds_max_removes_oldest', 0, () => {
      clearAll()
      for (let i = 0; i < 31; i++) {
        addEntry(makeEntry('h-max-' + i, 'file-' + i + '.png'))
      }
      expect(getHistory().length).assertEqual(30)
      let firstIdStillPresent: boolean = false
      let list: Array<ReceiveHistoryEntry> = getHistory()
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === 'h-max-0') {
          firstIdStillPresent = true
        }
      }
      expect(firstIdStillPresent).assertFalse()
      expect(getHistory()[29].id).assertEqual('h-max-30')
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
      for (let i = 0; i < 30; i++) {
        addEntry(makeEntry('h-exact-' + i, 'file-' + i + '.png'))
      }
      expect(getHistory().length).assertEqual(30)
      expect(getHistory()[0].id).assertEqual('h-exact-0')
      expect(getHistory()[29].id).assertEqual('h-exact-29')
    })

    it('getHistory_returns_current_content', 0, () => {
      clearAll()
      addEntry(makeEntry('h-get-1', 'content-a.png'))
      let list: Array<ReceiveHistoryEntry> = getHistory()
      expect(list.length).assertEqual(1)
      expect(list[0].id).assertEqual('h-get-1')
      expect(list[0].fileName).assertEqual('content-a.png')
    })
  })
}
