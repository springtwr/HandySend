// ReceiveHistorySelectionTest：接收历史长按多选删除的用例
// 覆盖勾选状态编排（进入 / 退出 / 单条切换 / 全选）、批量删除的实际删除范围，
// 以及列表重建时勾选状态的保留与空列表时退出多选。
import { describe, it, expect, beforeAll, beforeEach } from '@ohos/hypium'
import { ReceiveHistoryEntry } from '../../../../main/ets/model/Types'
import { ReceiveHistoryItemViewModel } from '../../../../main/ets/viewmodel/ReceiveHistoryItemViewModel'
import {
  ReceiveHistoryViewModel,
  countSelected
} from '../../../../main/ets/viewmodel/ReceiveHistoryViewModel'
import {
  addEntry,
  clearAll,
  getHistory,
  initHistory,
  removeEntries
} from '../../../../main/ets/service/repository/ReceiveHistoryService'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import { getTestAppContext } from '../helper/TestContext'

/** 构造接收历史条目（路径留空：删除用例只关心记录本身，不触碰磁盘文件）。 */
function entryOf(id: string, timestamp: number): ReceiveHistoryEntry {
  return {
    id: id,
    fileName: id + '.txt',
    fileType: 'text/plain',
    path: '',
    savedToGallery: false,
    isMessage: false,
    fileSize: 1,
    senderAlias: 'peer',
    timestamp: timestamp
  }
}

/** 复位服务层存储，保证各用例互不干扰。 */
function resetHistory(): void {
  clearAll(false)
}

/** 取视图中指定标识条目的勾选状态（不存在时返回 false）。 */
function selectedOf(vm: ReceiveHistoryViewModel, id: string): boolean {
  for (let i = 0; i < vm.historyItems.length; i++) {
    if (vm.historyItems[i].id === id) {
      return vm.historyItems[i].selected
    }
  }
  return false
}

export default function ReceiveHistorySelectionTest() {
  describe('ReceiveHistorySelectionTest', () => {
    beforeAll(() => {
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        initAllPreferences(ctx)
        initHistory(ctx)
      }
    })

    beforeEach(() => {
      resetHistory()
    })

    it('countSelected_countsCheckedItemsOnly', 0, () => {
      let checked = new ReceiveHistoryItemViewModel(entryOf('a', 1))
      checked.selected = true
      let unchecked = new ReceiveHistoryItemViewModel(entryOf('b', 2))
      expect(countSelected([checked, unchecked])).assertEqual(1)
      expect(countSelected([])).assertEqual(0)
    })

    it('enterSelection_selectsPressedItem', 0, () => {
      addEntry(entryOf('a', 1))
      addEntry(entryOf('b', 2))
      let vm = new ReceiveHistoryViewModel()
      vm.loadHistory()
      vm.enterSelection('a')
      expect(vm.selectionMode).assertTrue()
      expect(vm.isSelectedById('a')).assertTrue()
      expect(vm.selectedCount).assertEqual(1)
      expect(selectedOf(vm, 'b')).assertFalse()
    })

    it('enterSelection_unknownId_entersModeWithoutSelection', 0, () => {
      addEntry(entryOf('a', 1))
      let vm = new ReceiveHistoryViewModel()
      vm.loadHistory()
      vm.enterSelection('missing')
      // 标识不存在时不产生勾选，但模式已切换（与收藏列表同一编排）
      expect(vm.selectionMode).assertTrue()
      expect(vm.selectedCount).assertEqual(0)
    })

    it('toggleSelect_switchesSingleItem', 0, () => {
      addEntry(entryOf('a', 1))
      addEntry(entryOf('b', 2))
      let vm = new ReceiveHistoryViewModel()
      vm.loadHistory()
      vm.enterSelection('a')
      // 再次点击取消勾选
      vm.toggleSelect('a')
      expect(vm.selectedCount).assertEqual(0)
      // 切换另一条为追加
      vm.toggleSelect('b')
      expect(vm.selectedCount).assertEqual(1)
      expect(selectedOf(vm, 'b')).assertTrue()
    })

    it('toggleSelectAll_selectsAllThenClears', 0, () => {
      addEntry(entryOf('a', 1))
      addEntry(entryOf('b', 2))
      let vm = new ReceiveHistoryViewModel()
      vm.loadHistory()
      vm.enterSelection('a')
      vm.toggleSelectAll()
      expect(vm.allSelected).assertTrue()
      expect(vm.selectedCount).assertEqual(2)
      vm.toggleSelectAll()
      expect(vm.selectedCount).assertEqual(0)
      expect(vm.allSelected).assertFalse()
    })

    it('toggleSelectAll_emptyList_neverAllSelected', 0, () => {
      let vm = new ReceiveHistoryViewModel()
      vm.loadHistory()
      vm.toggleSelectAll()
      // 空列表不算全选，勾选集合保持为空
      expect(vm.allSelected).assertFalse()
      expect(vm.selectedCount).assertEqual(0)
    })

    it('exitSelection_clearsChecks', 0, () => {
      addEntry(entryOf('a', 1))
      addEntry(entryOf('b', 2))
      let vm = new ReceiveHistoryViewModel()
      vm.loadHistory()
      vm.enterSelection('a')
      vm.toggleSelectAll()
      vm.exitSelection()
      expect(vm.selectionMode).assertFalse()
      expect(vm.selectedCount).assertEqual(0)
      expect(selectedOf(vm, 'a')).assertFalse()
    })

    it('deleteSelected_removesCheckedOnly', 0, () => {
      addEntry(entryOf('a', 1))
      addEntry(entryOf('b', 2))
      let vm = new ReceiveHistoryViewModel()
      vm.loadHistory()
      vm.enterSelection('a')
      vm.deleteSelected(false)
      // 仅所选记录被移除，未选记录保留
      expect(getHistory().length).assertEqual(1)
      expect(getHistory()[0].id).assertEqual('b')
      // 删除后退出多选且勾选清空
      expect(vm.selectionMode).assertFalse()
      expect(vm.selectedCount).assertEqual(0)
      expect(vm.historyItems.length).assertEqual(1)
    })

    it('deleteSelected_multiple_removesAllChecked', 0, () => {
      addEntry(entryOf('a', 1))
      addEntry(entryOf('b', 2))
      addEntry(entryOf('c', 3))
      let vm = new ReceiveHistoryViewModel()
      vm.loadHistory()
      vm.enterSelection('a')
      vm.toggleSelect('c')
      vm.deleteSelected(false)
      expect(getHistory().length).assertEqual(1)
      expect(getHistory()[0].id).assertEqual('b')
    })

    it('deleteSelected_emptySelection_noOp', 0, () => {
      addEntry(entryOf('a', 1))
      let vm = new ReceiveHistoryViewModel()
      vm.loadHistory()
      vm.deleteSelected(false)
      // 无勾选时不执行删除
      expect(getHistory().length).assertEqual(1)
    })

    it('loadHistory_preservesChecksById', 0, () => {
      addEntry(entryOf('a', 1))
      addEntry(entryOf('b', 2))
      let vm = new ReceiveHistoryViewModel()
      vm.loadHistory()
      vm.enterSelection('a')
      expect(vm.selectedCount).assertEqual(1)
      // 重建条目后勾选状态按标识回填，不被清空
      vm.loadHistory()
      expect(vm.selectedCount).assertEqual(1)
      expect(selectedOf(vm, 'a')).assertTrue()
    })

    it('loadHistory_emptied_exitsSelection', 0, () => {
      addEntry(entryOf('a', 1))
      let vm = new ReceiveHistoryViewModel()
      vm.loadHistory()
      vm.enterSelection('a')
      removeEntries(['a'], false)
      vm.loadHistory()
      // 记录清空后退出多选，避免遗留空白选择态
      expect(vm.selectionMode).assertFalse()
      expect(vm.historyItems.length).assertEqual(0)
    })
  })
}
