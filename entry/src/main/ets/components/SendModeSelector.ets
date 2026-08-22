import { SendMode } from '../model/Types';
import { TabSegmentButtonV2, SegmentButtonV2Items } from '@ohos.arkui.advanced.SegmentButtonV2';

// 发送模式枚举固定顺序：与 segmentedItems 下标一一对应
const SEND_MODE_VALUES: Array<string> = [SendMode.single, SendMode.multiple, SendMode.link];

@ComponentV2
export struct SendModeSelector {
  @Param currentMode: string = 'single'
  @Event onModeChange: (mode: SendMode) => void = (_mode: SendMode) => {
  }

  // 官方分段按钮（TabSegmentButtonV2）：发送模式三选一（单目标 / 多目标 / 链接分享）
  private segmentedItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: $r('app.string.send_mode_single') },
    { text: $r('app.string.send_mode_multiple') },
    { text: $r('app.string.send_mode_link') }
  ]);

  // 当前发送模式对应的分段下标
  private getModeIndex(): number {
    for (let i = 0; i < SEND_MODE_VALUES.length; i++) {
      if (SEND_MODE_VALUES[i] === this.currentMode) {
        return i;
      }
    }
    return 0; // 默认 single
  }

  build() {
    TabSegmentButtonV2({
      items: this.segmentedItems,
      selectedIndex: this.getModeIndex(),
      $selectedIndex: (index: number) => {
        this.onModeChange(SEND_MODE_VALUES[index] as SendMode);
      },
      enableStateAnimation: true
    })
      .width('100%')
  }
}
