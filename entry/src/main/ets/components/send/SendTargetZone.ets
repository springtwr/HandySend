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
import { filterEnabledDeviceSources, listSources } from '../../service/transfer/DeviceSourceRegistry';
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
  // 点击网页图标：直接进入统一的「网页传输」面板
  @Event onOpenWeb: () => void = () => {
  }
  // 点击云图标：进入「远程传输」站点导航页
  @Event onOpenPortal: () => void = () => {
  }
  // 当前选中的来源下标（而非来源键）：官方分段标签按「下标」持有选中态。
  // -1 表示自动：从未手动选择时优先显示首个有设备的来源；用户点击标签后固定为该下标，
  // 之后即使该来源设备归零也保持（便于查看来源空态与排查引导）。
  @Local private selectedSourceIndexValue: number = -1
  // 官方分段标签选项集合：集合引用保持稳定，仅在协议开关变化时就地重建
  // （官方标注 items 为只读 @Param，整体替换在组件侧不被保证生效）
  @Local private sourceItemsValue: SegmentButtonV2Items = new SegmentButtonV2Items([])
  // 已构建选项对应的来源键签名（变化时才重建集合）
  private sourceKeySignature: string = ''
  // 当前可见来源集合（响应式镜像）：来源键集合变化时整体替换。
  // 副标题、空态文案与标签栏显隐都按可见来源派生；若每次渲染都读协议开关的实时值，
  // ArkUI 无法感知开关变化，开关重开后仍可能保留上一来源的文案。
  @Local private visibleSourcesValue: Array<DeviceSourceDescriptor> = []

  aboutToAppear(): void {
    this.syncSourceItems();
  }

  /** 协议开关变化时刷新可见来源镜像并重建分段标签选项（来源集合按开关常显，不随发现结果变化）。 */
  @Monitor('viewModel.localSendEnabled', 'viewModel.mtaEnabled')
  onSourceToggleChanged(): void {
    this.syncSourceItems();
  }

  private syncSourceItems(): void {
    let sources: Array<DeviceSourceDescriptor> = filterEnabledDeviceSources(listSources());
    let signature: string = '';
    for (let i = 0; i < sources.length; i++) {
      signature = signature + sources[i].key + '|';
    }
    // 手动下标越界时回退到首个来源；-1（自动模式）保持不变，由 selectedSourceIndex 决定展示哪个来源
    if (this.selectedSourceIndexValue >= sources.length) {
      this.selectedSourceIndexValue = 0;
    }
    if (signature === this.sourceKeySignature) {
      return;
    }
    this.sourceKeySignature = signature;
    // 先替换可见来源镜像，使副标题/空态文案在开关变化后随新集合重新求值
    this.visibleSourcesValue = sources;
    let options: Array<SegmentButtonV2ItemOptions> = [];
    for (let i = 0; i < sources.length; i++) {
      options.push({ text: sources[i].label });
    }
    this.sourceItemsValue = new SegmentButtonV2Items(options);
  }

  /** 可见来源：来源键集合变化时由 syncSourceItems 更新的响应式镜像（注册表顺序）。 */
  private visibleSources(): Array<DeviceSourceDescriptor> {
    return this.visibleSourcesValue;
  }

  /** 当前选中来源（按选中下标派生；集合为空时返回 undefined）。 */
  private currentSource(): DeviceSourceDescriptor | undefined {
    let sources = this.visibleSources();
    if (sources.length === 0) {
      return undefined;
    }
    return sources[this.selectedSourceIndex()];
  }

  /**
   * 当前选中来源下标：手动选择（>=0）优先；自动模式（-1）选首个有设备的来源，
   * 都无设备时回退首个。标签隐藏时仍按同一口径派生当前来源。
   */
  private selectedSourceIndex(): number {
    let sources: Array<DeviceSourceDescriptor> = this.visibleSources();
    if (sources.length === 0) {
      return 0;
    }
    if (this.selectedSourceIndexValue >= 0 && this.selectedSourceIndexValue < sources.length) {
      return this.selectedSourceIndexValue;
    }
    for (let i = 0; i < sources.length; i++) {
      if (this.devicesOf(sources[i]).length > 0) {
        return i;
      }
    }
    return 0;
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

  /** 任一可见来源是否存在设备：决定标签栏是否出现、是否回退总空态。 */
  private hasAnyDevice(): boolean {
    let sources: Array<DeviceSourceDescriptor> = this.visibleSources();
    for (let i = 0; i < sources.length; i++) {
      if (this.devicesOf(sources[i]).length > 0) {
        return true;
      }
    }
    return false;
  }

  /** 来源数 ≥2 且至少一个有设备时才显示标签栏；全部为空时回退总空态，不展示空标签。 */
  private shouldShowSourceTabs(): boolean {
    return this.visibleSources().length >= 2 && this.hasAnyDevice();
  }

  /**
   * 是否回退总空态：无任何已启用来源，或两个及以上来源全部无设备。
   * 仅一个来源时保留该来源自己的空态与引导（比总空态更具体）。
   */
  private showCombinedEmptyState(): boolean {
    let sources: Array<DeviceSourceDescriptor> = this.visibleSources();
    return sources.length === 0 || (sources.length >= 2 && !this.hasAnyDevice());
  }

  /** 副标题：有设备时随当前来源切换；回退总空态时用总空态文案。 */
  private currentSubtitle(): ResourceStr {
    if (this.showCombinedEmptyState()) {
      return $r('app.string.send_no_source_subtitle');
    }
    let descriptor = this.currentSource();
    return descriptor !== undefined ? descriptor.subtitle : $r('app.string.send_no_source_subtitle');
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
        // 用户点击后固定为具体下标、退出自动选择；集合变化时由 syncSourceItems 夹取
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
      // 身份取稳定键（MTA 为发送者 ID），但 MTA 的 BLE 地址/品牌/5GHz 是发送目标的一部分，
      // 必须纳入 key；Repeat 全量加载模式下 key 不变时即使数据更新也不会刷新。
      // LocalSend 与 MTA 的真实广播昵称由 keyAlias 参与；MTA 地址回退别名不重复参与。
      item.identityKey + '|' + item.keyAlias + '|' + item.keyMta + '|' + item.ip + ':' + item.item.port +
        '|' + item.deviceModel + '|' + item.deviceType + '|' + item.item.version + '|' + item.item.protocol)
    }
    .width('100%')
  }

  /**
   * 设备区空态卡片：沿用任务页、接收历史页的卡片模式（面板最小高度 120vp），
   * 为整区提供明确边界；同页条目也是卡片，卡片外观（背景/圆角/边框）与设备卡同款。
   */
  @Builder
  emptyCard() {
    if (this.showCombinedEmptyState()) {
      // 无任何已启用来源，或多来源全部无设备：总空态的主文案不绑定单一协议；
      // 网页传输不依赖设备发现，始终给出入口——总开关关闭时进入页面即可开启
      EmptyState({
        mainText: $r('app.string.send_no_source_title'),
        actionText: $r('app.string.discovery_source_web'),
        actionIcon: $r('sys.symbol.worldclock'),
        onAction: () => {
          this.onOpenWeb();
        },
        useCard: true
      })
        .id('send_no_source')
    } else {
      // 条件引导提示沿用警示语义色
      EmptyState({
        mainText: this.emptyText(),
        hintText: this.emptyHintVisible() ? this.emptyHint() : undefined,
        hintColor: $r('app.color.warning_orange'),
        useCard: true
      })
        .id('send_no_devices')
    }
  }

  @Builder
  deviceSection() {
    if (this.showCombinedEmptyState() || this.currentDeviceItems().length === 0) {
      this.emptyCard()
    } else {
      this.deviceGrid()
    }
  }

  build() {
    Column() {
      // ── 目标区标题行（自定义区标题 + 方式区图标菜单 + 刷新） ──
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

        // 方式区：网页图标直接进入网页传输面板；其它方式保留菜单
        SendMethodZone({
          isWebActive: this.viewModel.webServiceActive,
          onOpenWeb: () => {
            this.onOpenWeb();
          },
          onOpenPortal: () => {
            this.onOpenPortal();
          }
        })

        if (this.viewModel.isScanning || this.viewModel.isRefreshing) {
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

      // ── 来源标签（已启用来源 ≥2 且至少一个有设备时展示；全空时回退总空态） ──
      if (this.shouldShowSourceTabs()) {
        this.sourceTabs()
      }

      // ── 设备列表：条目自身为独立卡片，外层不再套大卡片；与上方标题/标签留出间距 ──
      Column() {
        this.deviceSection()
      }
      .width('100%')
      .margin({ top: DesignTokens.space.sm })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: DesignTokens.space.lg })
    .id('send_target_zone')
  }
}
