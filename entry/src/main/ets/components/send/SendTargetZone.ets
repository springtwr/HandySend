/**
 * SendTargetZone.ets — 发送页目标区
 *
 * 设备来源由注册表驱动通用渲染（来源数为 1 不显示标签、≥2 以官方分段标签展示）；
 * 点击设备即发送（无单/多目标模式差异）；设备条目只承担发现与选择，
 * 不内联展示传输进度与状态；空态与条件化引导由来源描述符提供。
 */

import { TabSegmentButtonV2, SegmentButtonV2Items, SegmentButtonV2ItemOptions } from '@kit.ArkUI';
import { DesignTokens } from '../../common/DesignTokens';
import { EmptyState } from '../EmptyState';
import { DeviceSourceDescriptor } from '../../model/transfer/Registries';
import { DiscoveredDevice } from '../../model/Types';
import { filterSeenSources, listSources } from '../../service/transfer/DeviceSourceRegistry';
import { SendViewModel } from '../../viewmodel/SendViewModel';
import { DeviceItemViewModel } from '../../viewmodel/DeviceItemViewModel';
import { DeviceListItem } from '../../views/DeviceListItem';
import { SendMethodZone } from './SendMethodZone';

@ComponentV2
export struct SendTargetZone {
  @Require @Param viewModel: SendViewModel
  @Event onSend: (device: DiscoveredDevice) => void = (_device: DiscoveredDevice) => {
  }
  @Event onInfo: (device: DiscoveredDevice) => void = (_device: DiscoveredDevice) => {
  }
  @Event onRefresh: () => void = () => {
  }
  // 当前选中的来源下标（而非来源键）：官方分段标签按「下标」持有选中态，
  // 父级若按「键」存选中，则在可见来源集合增长/重排后同一下标指向不同来源
  //（冷启动常见：先发现互传设备→集合只有[互传]，之后局域网设备出现→集合变为
  // [LocalSend,互传]），会出现「页签停在一个来源、列表却按另一个来源取数」的不一致。
  // 故统一按下标持有选中态、由下标派生来源，两侧由构造保证一致。
  @Local private selectedSourceIndexValue: number = 0
  // 官方分段标签选项集合：集合引用保持稳定，仅在可见来源集合变化时就地重建
  // （官方标注 items 为只读 @Param，整体替换在组件侧不被保证生效）
  @Local private sourceItemsValue: SegmentButtonV2Items = new SegmentButtonV2Items([])
  // 已构建选项对应的来源键签名（变化时才重建集合）
  private sourceKeySignature: string = ''

  aboutToAppear(): void {
    this.syncSourceItems();
  }

  /** 可见来源集合变化时重建分段标签选项（会话内仅随「曾发现过设备的来源」增长）。 */
  @Monitor('viewModel.seenSourceKeys')
  onSeenSourcesChanged(): void {
    this.syncSourceItems();
  }

  private syncSourceItems(): void {
    let sources: Array<DeviceSourceDescriptor> = this.visibleSources();
    let signature: string = '';
    for (let i = 0; i < sources.length; i++) {
      signature = signature + sources[i].key + '|';
    }
    // 集合变化后按下标夹取选中态：集合缩小时下标越界即回到首个来源，
    // 保证下标始终有效（列表与页签由同一下标派生）
    this.selectedSourceIndexValue = this.clampSourceIndex(this.selectedSourceIndexValue, sources.length);
    if (signature === this.sourceKeySignature) {
      return;
    }
    this.sourceKeySignature = signature;
    let options: Array<SegmentButtonV2ItemOptions> = [];
    for (let i = 0; i < sources.length; i++) {
      options.push({ text: sources[i].label });
    }
    this.sourceItemsValue = new SegmentButtonV2Items(options);
  }

  /** 下标夹取到 [0, count)（count 为 0 时归 0；越界归 0，即回退到首个来源） */
  private clampSourceIndex(index: number, count: number): number {
    if (count <= 0 || index < 0 || index >= count) {
      return 0;
    }
    return index;
  }

  /** 可见来源：仅「本次发送页会话曾发现过设备」的来源（注册表顺序）。 */
  private visibleSources(): Array<DeviceSourceDescriptor> {
    return filterSeenSources(listSources(), this.viewModel.seenSourceKeys);
  }

  /** 当前选中来源（按选中下标派生；集合为空时返回 undefined）。 */
  private currentSource(): DeviceSourceDescriptor | undefined {
    let sources = this.visibleSources();
    if (sources.length === 0) {
      return undefined;
    }
    return sources[this.selectedSourceIndex()];
  }

  /** 当前选中来源在分段标签中的下标（夹取到有效范围，恒与页签选中下标一致）。 */
  private selectedSourceIndex(): number {
    return this.clampSourceIndex(this.selectedSourceIndexValue, this.visibleSources().length);
  }

  /**
   * 某来源的待渲染设备项。
   * 数据源接线：优先复用 ViewModel 的响应式设备项数组（其键与来源注册表描述符一致），
   * 未接入映射的来源回退到注册表发现数据源。
   */
  private devicesOf(descriptor: DeviceSourceDescriptor): Array<DeviceItemViewModel> {
    let mapped: Array<DeviceItemViewModel> = this.viewModel.deviceItemsForSource(descriptor.key);
    if (mapped.length > 0) {
      return mapped;
    }
    let devices: Array<DiscoveredDevice> = descriptor.discoveryProvider();
    let result: Array<DeviceItemViewModel> = [];
    for (let i = 0; i < devices.length; i++) {
      result.push(new DeviceItemViewModel(devices[i]));
    }
    return result;
  }

  /** 当前选中来源的待渲染设备项（每次渲染按响应式状态求值）。 */
  private currentDeviceItems(): Array<DeviceItemViewModel> {
    let descriptor = this.currentSource();
    if (descriptor === undefined) {
      return [];
    }
    return this.devicesOf(descriptor);
  }

  /** 副标题引导文案：随当前选中来源切换，来源缺失时回退局域网文案。 */
  private currentSubtitle(): ResourceStr {
    let descriptor = this.currentSource();
    return descriptor !== undefined ? descriptor.subtitle : $r('app.string.nearby_devices_subtitle');
  }

  /** 空态文案：来源描述符提供，缺失时回退默认空态。 */
  private emptyText(): ResourceStr {
    let descriptor = this.currentSource();
    if (descriptor === undefined) {
      return $r('app.string.no_devices_found');
    }
    return descriptor.emptyState.dynamicText !== undefined ? descriptor.emptyState.dynamicText() :
      descriptor.emptyState.text;
  }

  /** 空态条件化引导是否展示。 */
  private emptyHintVisible(): boolean {
    let descriptor = this.currentSource();
    return descriptor !== undefined && descriptor.emptyState.hintVisible();
  }

  private emptyHint(): ResourceStr {
    let descriptor = this.currentSource();
    return descriptor !== undefined ? descriptor.emptyState.hint : '';
  }

  private openDeviceDetails(device: DiscoveredDevice): void {
    this.onInfo(device);
  }

  @Builder
  sourceTabs() {
    TabSegmentButtonV2({
      items: this.sourceItemsValue,
      selectedIndex: this.selectedSourceIndex(),
      $selectedIndex: (index: number) => {
        // 直接持有下标：与官方组件同口径，避免「键 ↔ 下标」两套表示在集合变化后失配
        this.selectedSourceIndexValue = index;
      },
      enableStateAnimation: true
    })
      .width('100%')
      .margin({ top: DesignTokens.space.sm })
      .id('send_source_tabs')
  }

  @Builder
  deviceGrid() {
    GridRow({
      columns: {
        xs: 1,
        sm: 1,
        md: 1,
        lg: 2,
        xl: 3
      },
      gutter: { x: DesignTokens.space.inner, y: DesignTokens.space.inner },
      // 列数按窗口宽度（默认参照）决定：单栏内容区宽度随窗口变化，按容器尺寸判定会低估列数
      breakpoints: {
        value: ['320vp', '600vp', '840vp', '1440vp']
      }
    }) {
      Repeat(this.currentDeviceItems()).each((ri: RepeatItem<DeviceItemViewModel>) => {
        GridCol() {
          DeviceListItem({
            device: ri.item,
            viewModel: this.viewModel,
            onSend: (vm: DeviceItemViewModel) => {
              this.onSend(vm.item);
            },
            onInfo: (vm: DeviceItemViewModel) => {
              this.openDeviceDetails(vm.item);
            }
          })
        }
      }).key((item: DeviceItemViewModel) =>
      // 身份取稳定键（MTA 为发送者 ID）：广播地址轮换不再触发条目重建；
      // 不含 alias——设备名缺失时 alias 回退为地址，同样会随轮换变化
      item.identityKey + '|' + item.ip + ':' + item.item.port + '|' + item.deviceModel +
        '|' + item.deviceType + '|' + item.item.version + '|' + item.item.protocol)
    }
    .width('100%')
  }

  @Builder
  emptyState() {
    // 空态位于「设备卡片」内，不再套第二层卡片；条件引导提示沿用警示语义色。
    // 内容区下限按「空态面板统一高度」减去设备卡片自身内边距反推，使面板与卡片型空态同高
    EmptyState({
      mainText: this.emptyText(),
      hintText: this.emptyHintVisible() ? this.emptyHint() : undefined,
      hintColor: $r('app.color.warning_orange'),
      minHeight: DesignTokens.size.emptyStateMinHeight - DesignTokens.space.card * 2
    })
      .id('send_no_devices')
  }

  @Builder
  deviceSection() {
    if (this.currentSource() === undefined) {
      // 未发现任何来源设备：默认空态（文案与局域网空态一致），位于「设备卡片」内不带卡片；
      // 与设备列表空态取同一内容区下限，避免两处空态在同一个卡片里高度跳变
      EmptyState({
        mainText: $r('app.string.no_devices_found'),
        minHeight: DesignTokens.size.emptyStateMinHeight - DesignTokens.space.card * 2
      })
        .id('send_no_source')
    } else if (this.currentDeviceItems().length === 0) {
      this.emptyState()
    } else {
      this.deviceGrid()
    }
  }

  build() {
    Column() {
      // ── 目标区标题行（自定义卡片外标题 + 方式区图标菜单 + 刷新） ──
      Row({ space: DesignTokens.space.md }) {
        Column() {
          Text($r('app.string.send_zone_target_title'))
            .fontSize(DesignTokens.font.titleS)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(this.currentSubtitle())
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: DesignTokens.space.tiny })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 方式区（注册表驱动；网页 / 其它方式两个入口）
        SendMethodZone()

        if (this.viewModel.isScanning) {
          LoadingProgress()
            .width(24)
            .height(24)
            .color($r('app.color.accent_blue'))
            .responseRegion({
              x: -12,
              y: -12,
              width: 48,
              height: 48
            })
            .accessibilityGroup(true)
            .onClick(() => {
              this.onRefresh();
            })
            .id('send_refresh_loading')
        } else {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(DesignTokens.font.titleM)
            .fontColor([$r('app.color.text_primary')])
            .rotate({ angle: this.viewModel.refreshAngle })
            .responseRegion({
              x: -12,
              y: -12,
              width: 48,
              height: 48
            })
            .accessibilityGroup(true)
            .onClick(() => {
              this.onRefresh();
            })
            .id('send_refresh_btn')
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.End)

      // ── 来源标签（仅在可见来源数 ≥2 时展示） ──
      if (this.visibleSources().length >= 2) {
        this.sourceTabs()
      }

      // ── 设备卡片 ──
      Column() {
        this.deviceSection()
      }
      .width('100%')
      .padding(DesignTokens.space.card)
      .borderRadius(DesignTokens.radius.lg)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      .margin({ top: DesignTokens.space.sm })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: DesignTokens.space.lg })
    .id('send_target_zone')
  }
}
