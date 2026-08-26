import { DesignTokens } from '../common/DesignTokens';
import { SettingsViewModel } from '../viewmodel/SettingsViewModel';
import { ReceiveSettingsSection } from '../views/settings/ReceiveSettingsSection';
import { SendSettingsSection } from '../views/settings/SendSettingsSection';
import { AppearanceSettingsSection } from '../views/settings/AppearanceSettingsSection';
import { NetworkSettingsSection } from '../views/settings/NetworkSettingsSection';
import { MoreSettingsSection } from '../views/settings/MoreSettingsSection';

@ComponentV2
export struct SettingsContent {
  @Local viewModel: SettingsViewModel = new SettingsViewModel();
  @Event onScrollDelta: (deltaY: number, absY: number) => void = (_deltaY: number, _absY: number) => {
  }
  private scroller: Scroller = new Scroller()

  aboutToAppear(): void {
    this.viewModel.loadInitialData();
    this.viewModel.subscribe();
  }

  aboutToDisappear(): void {
    this.viewModel.unsubscribe();
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // ── 接收设置区域 ──
        ReceiveSettingsSection({ viewModel: this.viewModel })

        // ── 发送设置 ──
        SendSettingsSection({ viewModel: this.viewModel })

        // ── 外观设置 ──
        AppearanceSettingsSection({ viewModel: this.viewModel })

        // ── 网络与设备身份 ──
        NetworkSettingsSection({ viewModel: this.viewModel })

        // ── 更多（反馈/关于/调试日志/恢复默认） ──
        MoreSettingsSection({ viewModel: this.viewModel })
      }
      .width('100%')
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.size.tabBarClearance })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor($r('app.color.page_background'))
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onDidScroll((_xOffset: number, yOffset: number) => {
      let offset = this.scroller.currentOffset();
      this.onScrollDelta(yOffset, offset.yOffset);
    })
    .onScrollEdge((edge: Edge) => {
      if (edge === Edge.Top) {
        this.onScrollDelta(-999, 0);
      }
    })
  }
}
