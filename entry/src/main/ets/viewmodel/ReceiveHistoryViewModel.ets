import { getReceiveHistory } from '../service/AppService';
import { removeEntries, removeEntry, clearAll } from '../service/repository/ReceiveHistoryService';
import { ReceiveHistoryEntry } from '../model/Types';
import { ReceiveHistoryItemViewModel } from './ReceiveHistoryItemViewModel';

/** 统计已勾选条目数（纯函数）。 */
export function countSelected(items: Array<ReceiveHistoryItemViewModel>): number {
  let count: number = 0;
  for (let i = 0; i < items.length; i++) {
    if (items[i].selected) {
      count++;
    }
  }
  return count;
}

@ObservedV2
export class ReceiveHistoryViewModel {
  @Trace public historyItems: Array<ReceiveHistoryItemViewModel> = []
  // 多选模式：长按条目进入，退出时清空全部勾选
  @Trace public selectionMode: boolean = false

  /** 已勾选数量。 */
  get selectedCount(): number {
    return countSelected(this.historyItems);
  }

  /** 指定标识条目当前是否已勾选。 */
  isSelectedById(id: string): boolean {
    let item: ReceiveHistoryItemViewModel | undefined = this.findItem(id);
    return item !== undefined && item.selected;
  }

  /** 是否全选（空列表不为全选）。 */
  get allSelected(): boolean {
    return this.historyItems.length > 0 && this.selectedCount === this.historyItems.length;
  }

  loadHistory(): void {
    let entries = getReceiveHistory();
    // 按接收时间倒序排列（最新的在顶部）；服务层返回共享数组，须先取副本再排序
    let sorted = entries.slice();
    sorted.sort((a: ReceiveHistoryEntry, b: ReceiveHistoryEntry) => b.timestamp - a.timestamp);
    let items: Array<ReceiveHistoryItemViewModel> = [];
    for (let i = 0; i < sorted.length; i++) {
      items.push(new ReceiveHistoryItemViewModel(sorted[i]));
    }
    // 重建条目会丢弃勾选状态，按 id 从旧条目回填，避免多选过程中刷新导致已勾选项被清空
    for (let i = 0; i < items.length; i++) {
      items[i].selected = this.findItem(items[i].id)?.selected ?? false;
    }
    this.historyItems = items;
    // 记录被清空后退出多选模式，避免遗留空白选择态
    if (this.historyItems.length === 0) {
      this.selectionMode = false;
    }
  }

  private findItem(id: string): ReceiveHistoryItemViewModel | undefined {
    for (let i = 0; i < this.historyItems.length; i++) {
      if (this.historyItems[i].id === id) {
        return this.historyItems[i];
      }
    }
    return undefined;
  }

  // ── 多选命令 ──

  /** 进入多选模式并选中触发长按的条目。 */
  enterSelection(id: string): void {
    this.selectionMode = true;
    let item: ReceiveHistoryItemViewModel | undefined = this.findItem(id);
    if (item !== undefined) {
      item.selected = true;
    }
  }

  /** 退出多选模式并清空全部勾选。 */
  exitSelection(): void {
    this.selectionMode = false;
    for (let i = 0; i < this.historyItems.length; i++) {
      this.historyItems[i].selected = false;
    }
  }

  /** 切换单条勾选状态。 */
  toggleSelect(id: string): void {
    let item: ReceiveHistoryItemViewModel | undefined = this.findItem(id);
    if (item !== undefined) {
      item.selected = !item.selected;
    }
  }

  /** 全选 / 取消全选切换。 */
  toggleSelectAll(): void {
    let target: boolean = !this.allSelected;
    for (let i = 0; i < this.historyItems.length; i++) {
      this.historyItems[i].selected = target;
    }
  }

  // deleteFiles：是否同时删除勾选记录指向的磁盘文件（由确认弹窗勾选决定）
  deleteSelected(deleteFiles: boolean): void {
    let ids: Array<string> = [];
    for (let i = 0; i < this.historyItems.length; i++) {
      if (this.historyItems[i].selected) {
        ids.push(this.historyItems[i].id);
      }
    }
    if (ids.length === 0) {
      return;
    }
    removeEntries(ids, deleteFiles);
    this.loadHistory();
    this.exitSelection();
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
