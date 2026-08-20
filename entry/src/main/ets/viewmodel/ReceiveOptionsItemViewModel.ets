import { PendingRequestFile } from '../model/Types';
import { formatSizeDetailed } from '../utils/FormatUtil';

// 包装待接收文件的条目级 ViewModel。
// 依据基于场景的列表策略（方案 B）选择：条目为
// 可修改（逐项选择 + 重命名），因此每个条目被包装
// 而不是向视图暴露原始 DTO。
@ObservedV2
export class ReceiveOptionsItemViewModel {
  @Trace public file: PendingRequestFile
  @Trace public isSelected: boolean = true

  constructor(file: PendingRequestFile) {
    this.file = file;
    this.isSelected = true;
  }

  get formattedSize(): string {
    return formatSizeDetailed(this.file.size);
  }
}
