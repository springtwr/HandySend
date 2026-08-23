import { getReceiveHistory } from '../service/AppService';
import { removeEntry, clearAll } from '../service/ReceiveHistoryService';
import { ReceiveHistoryItemViewModel } from './ReceiveHistoryItemViewModel';

@ObservedV2
export class ReceiveHistoryViewModel {
  @Trace public historyItems: Array<ReceiveHistoryItemViewModel> = []

  loadHistory(): void {
    let entries = getReceiveHistory();
    let items: Array<ReceiveHistoryItemViewModel> = [];
    for (let i = 0; i < entries.length; i++) {
      items.push(new ReceiveHistoryItemViewModel(entries[i]));
    }
    this.historyItems = items;
  }

  // deleteFiles：是否同时删除该记录指向的磁盘文件（由确认弹窗勾选决定）
  deleteEntry(id: string, deleteFiles: boolean): void {
    removeEntry(id, deleteFiles);
    this.loadHistory();
  }

  // deleteFiles：是否同时删除全部记录指向的磁盘文件（由确认弹窗勾选决定）
  clearAllHistory(deleteFiles: boolean): void {
    clearAll(deleteFiles);
    this.loadHistory();
  }
}
