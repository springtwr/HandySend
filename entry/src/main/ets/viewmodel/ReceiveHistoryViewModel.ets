import { getReceiveHistory } from '../service/AppService';
import { removeEntry, clearAll } from '../service/ReceiveHistoryService';
import { ReceiveHistoryItemViewModel } from './ReceiveHistoryItemViewModel';

@Observed
export class ReceiveHistoryViewModel {
  public historyItems: Array<ReceiveHistoryItemViewModel> = []

  loadHistory(): void {
    let entries = getReceiveHistory();
    let items: Array<ReceiveHistoryItemViewModel> = [];
    for (let i = 0; i < entries.length; i++) {
      items.push(new ReceiveHistoryItemViewModel(entries[i]));
    }
    this.historyItems = items;
  }

  deleteEntry(id: string): void {
    removeEntry(id);
    this.loadHistory();
  }

  clearAllHistory(): void {
    clearAll();
    this.loadHistory();
  }
}
