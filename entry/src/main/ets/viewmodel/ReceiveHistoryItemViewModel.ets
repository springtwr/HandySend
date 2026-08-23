import { ReceiveHistoryEntry } from '../model/Types';
import { formatTime, formatSize } from '../utils/FormatUtil';

// 包装单个接收历史条目的条目级 ViewModel。
// 依据基于场景的列表策略（方案 B）选择：条目为
// 可修改（可删除），因此每个条目被包装而不是暴露
// 将原始 DTO 暴露给视图。
@ObservedV2
export class ReceiveHistoryItemViewModel {
  @Trace public id: string = ''
  @Trace public fileName: string = ''
  @Trace public fileType: string = ''
  @Trace public senderAlias: string = ''
  @Trace public fileSize: number = 0
  @Trace public savedToGallery: boolean = false
  @Trace public isMessage: boolean = false
  @Trace public timestamp: number = 0

  constructor(entry: ReceiveHistoryEntry) {
    this.id = entry.id;
    this.fileName = entry.fileName;
    this.fileType = entry.fileType;
    this.senderAlias = entry.senderAlias;
    this.fileSize = entry.fileSize;
    this.savedToGallery = entry.savedToGallery;
    this.isMessage = entry.isMessage;
    this.timestamp = entry.timestamp;
  }

  get formattedTime(): string {
    return formatTime(this.timestamp);
  }

  get formattedSize(): string {
    return formatSize(this.fileSize);
  }
}
