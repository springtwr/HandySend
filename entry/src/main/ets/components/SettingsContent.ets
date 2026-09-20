import { DesignTokens } from '../common/DesignTokens';
import { SettingGroupDescriptor } from '../model/transfer/Registries';
import { listSettingsGroups } from '../service/transfer/SettingsGroupRegistry';
import { SettingsViewModel } from '../viewmodel/SettingsViewModel';
import { DeviceIdentitySection } from '../views/settings/DeviceIdentitySection';
import { GeneralSettingsSection } from '../views/settings/GeneralSettingsSection';
import { MtaSettingsSection } from '../views/settings/MtaSettingsSection';
import { AppearanceSettingsSection } from '../views/settings/AppearanceSettingsSection';
import { NetworkSettingsSection } from '../views/settings/NetworkSettingsSection';
import { MoreSettingsSection } from '../views/settings/MoreSettingsSection';

/**
 * 设置页：分组顺序与组成由设置分组注册表驱动（`listSettingsGroups()`）。
 *
 * 分组标题统一在此渲染（分区组件只提供卡片内容），因此调整分组顺序或新增协议分组
 * 无需改动页面结构。协议差异仅通过「分组键 → 分区组件」的装配映射表达。
 */
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

  /** 分组标题（标题由注册表描述符提供）。 */
  @Builder
  groupTitle(title: ResourceStr) {
    Text(title)
      .fontSize(DesignTokens.font.subtitleM)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
      .width('100%')
      .margin({ top: DesignTokens.space.lg })
  }

  /** 按分组键装配对应分区组件（未注册分区组件的分组不渲染内容，支持桩协议扩展验证）。 */
  @Builder
  groupSections(descriptor: SettingGroupDescriptor) {
    if (descriptor.sectionKey === 'device') {
      DeviceIdentitySection({ viewModel: this.viewModel })
    } else if (descriptor.sectionKey === 'general') {
      GeneralSettingsSection({ viewModel: this.viewModel })
    } else if (descriptor.sectionKey === 'localsend') {
      // LocalSend 分组：单卡片（服务器状态 / 请求确认 / 下载请求 / 高级设置）
      NetworkSettingsSection({ viewModel: this.viewModel })
    } else if (descriptor.sectionKey === 'mta') {
      MtaSettingsSection({ viewModel: this.viewModel })
    } else if (descriptor.sectionKey === 'appearance') {
      AppearanceSettingsSection({ viewModel: this.viewModel })
    } else if (descriptor.sectionKey === 'more') {
      MoreSettingsSection({ viewModel: this.viewModel })
    }
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // 分组顺序与组成由设置分组注册表驱动；分组标题在装配处统一渲染
        Repeat(listSettingsGroups()).each((ri: RepeatItem<SettingGroupDescriptor>) => {
          this.groupTitle(ri.item.title)
          this.groupSections(ri.item)
        }).key((item: SettingGroupDescriptor) => item.key)
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
