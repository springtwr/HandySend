/**
 * LocalDeviceSection.ets — 「本机信息」精简展示
 *
 * 经发送页标题栏「本机信息」入口的 bindSheet 呈现，按本机对外宣告的两条路径分三段：
 * 设备身份（昵称 / 类型 / 型号）、LocalSend（设备指纹 / 监听端口 / 加密传输 / 网络接口入口）、
 * 互传（模拟品牌 / 广播名称 / 发送者 ID）。字段与「设备详情页」的对端口径互为镜像。
 * 服务启停状态归属设置页对应分组，此处不重复展示。
 * LocalSend / 网页两组的网络接口入口在同一半模态内平移切换为接口列表页：
 * 两页叠放在 Stack 中，由 translate 与 animateTo 完成转场（官方 bindSheet 页内切换方案）。
 */

import { DesignTokens } from '../../common/DesignTokens';
import {
  subscribe,
  unsubscribe,
  getDeviceAlias,
  getDeviceType,
  getDeviceModel,
  getServerFingerprint,
  getLocalInterfaces,
  updateLocalInterfaces,
  getPort,
  getHttpsEnabled,
  getNetworkWhitelist,
  getNetworkBlacklist,
  getWebSendAllowed,
  getWebReceiveAllowed,
  getWebHttpsEnabled,
  getWebPin,
  isWebUploadEnabled,
  getWebInterfaceNames,
  getWebInterfaceBlacklistNames,
  getWebPort,
  getWebActualPort,
  isWebPortFallback,
  getMtaSimulatedBrand,
  getLocalMtaDeviceIdHex,
  mtaBroadcastName
} from '../../service/AppService';
import { NetworkInterface, NetworkType } from '../../model/Types';
import { networkTypeLabel } from '../../utils/NetworkPresentation';
import { resolveMtaBrandDisplayName } from '../../model/mta/MtaBrandRegistry';
import { getStringSync } from '../../utils/ResourceUtil';
import { SingleLineValueRow } from '../../components/SingleLineValueRow';
import { EmptyState } from '../../components/EmptyState';
import { networkSettingsViewModel } from '../../viewmodel/NetworkSettingsViewModel';

/** 接口列表页来源：决定启用状态按哪一套白/黑名单判定。 */
enum InterfacePageSource {
  none = 'none',
  localSend = 'localsend',
  web = 'web'
}

@ComponentV2
export struct LocalDeviceSection {
  @Local private alias: string = ''
  @Local private deviceTypeText: string = ''
  @Local private deviceModel: string = ''
  @Local private fingerprint: string = ''
  @Local private listenPort: string = ''
  @Local private encryptedText: string = ''
  @Local private interfaces: Array<NetworkInterface> = []
  @Local private webSendText: string = ''
  @Local private webReceiveText: string = ''
  @Local private webHttpsText: string = ''
  @Local private webPinText: string = ''
  @Local private webPortText: string = ''
  @Local private mtaBrand: string = ''
  @Local private mtaBroadcast: string = ''
  @Local private mtaDeviceId: string = ''
  // ── 网络接口页（半模态内平移切换） ──
  // 当前页由半模态宿主持有：系统返回键经 onWillDismiss 先退回本页，再由宿主统一切换
  @Param showInterfacePage: boolean = false
  @Event onRequestInterfacePage: (show: boolean) => void = (_show: boolean): void => {
  }
  @Local private interfaceSource: InterfacePageSource = InterfacePageSource.none
  // 平移距离：取内容区实际宽度，避免不同窗口形态使用固定值
  @Local private pageWidth: number = 9999
  @Local private networkWhitelist: Array<string> = []
  @Local private networkBlacklist: Array<string> = []
  @Local private webWhitelist: Array<string> = []
  @Local private webBlacklist: Array<string> = []
  private refreshCallback: () => void = (): void => {
  }

  aboutToAppear(): void {
    this.refreshCallback = (): void => {
      this.refresh();
    };
    subscribe(this.refreshCallback);
    this.refresh();
  }

  aboutToDisappear(): void {
    unsubscribe(this.refreshCallback);
  }

  private refresh(): void {
    this.alias = getDeviceAlias();
    this.deviceTypeText = this.resolveDeviceTypeText(getDeviceType());
    this.deviceModel = getDeviceModel();
    this.fingerprint = getServerFingerprint();
    // 端口与加密传输分两行：前者是端点，后者决定对端是否以 HTTPS 连接
    this.listenPort = String(getPort());
    this.encryptedText = getStringSync(this.getUIContext(),
      getHttpsEnabled() ? $r('app.string.local_device_encrypted_on') : $r('app.string.local_device_encrypted_off'));

    // 接口列表页展示全部接口，排序与设置页网络接口弹窗一致
    this.interfaces = networkSettingsViewModel.sortInterfaces(getLocalInterfaces());
    this.networkWhitelist = networkSettingsViewModel.parseList(getNetworkWhitelist());
    this.networkBlacklist = networkSettingsViewModel.parseList(getNetworkBlacklist());
    this.webWhitelist = getWebInterfaceNames();
    this.webBlacklist = getWebInterfaceBlacklistNames();

    // 网页独立服务：按实际运行状态展示（开关开启但服务启动失败时显示未运行）
    let webRunning: boolean = getWebActualPort() > 0;
    this.webSendText = this.runStateText(getWebSendAllowed() && webRunning);
    this.webReceiveText = this.runStateText(getWebReceiveAllowed() && webRunning && isWebUploadEnabled());
    this.webHttpsText = this.onOffText(getWebHttpsEnabled());
    this.webPinText = getStringSync(this.getUIContext(),
      getWebPin().length > 0 ? $r('app.string.web_pin_status_set') : $r('app.string.web_pin_status_unset'));
    let actualPort: number = getWebActualPort();
    if (actualPort > 0 && isWebPortFallback()) {
      this.webPortText = getStringSync(this.getUIContext(), $r('app.string.web_port_fallback_value'))
        .replace('%d', String(actualPort))
        .replace('%d', String(getWebPort()));
    } else {
      this.webPortText = String(actualPort > 0 ? actualPort : getWebPort());
    }

    // 互传侧对外身份：模拟品牌决定对端把本机识别成哪个厂商设备，发送者 ID 是对端的去重依据
    this.mtaBrand = this.resolveResourceText(resolveMtaBrandDisplayName(getMtaSimulatedBrand()));
    this.mtaDeviceId = getLocalMtaDeviceIdHex();
    this.mtaBroadcast = mtaBroadcastName(this.alias);
  }

  /** 开关状态文案（复用 LocalSend 加密行的开/关文案）。 */
  private onOffText(on: boolean): string {
    return getStringSync(this.getUIContext(),
      on ? $r('app.string.local_device_encrypted_on') : $r('app.string.local_device_encrypted_off'));
  }

  /** 网页发送/接收状态：服务实际运行且该方向可用才算运行中。 */
  private runStateText(running: boolean): string {
    return getStringSync(this.getUIContext(),
      running ? $r('app.string.service_status_running') : $r('app.string.service_status_stopped'));
  }

  /** 品牌显示名可能是字符串资源或纯文本，统一取当前语言的文本。 */
  private resolveResourceText(value: ResourceStr): string {
    return typeof value === 'string' ? value : getStringSync(this.getUIContext(), value);
  }

  /** 设备类型取值（mobile / desktop / tablet）转展示文案。 */
  private resolveDeviceTypeText(deviceType: string): string {
    let res: Resource = $r('app.string.device_type_mobile');
    if (deviceType === 'desktop') {
      res = $r('app.string.device_type_desktop');
    } else if (deviceType === 'tablet') {
      res = $r('app.string.device_type_tablet');
    }
    return getStringSync(this.getUIContext(), res);
  }

  /** 接口页标题：标明当前列表属于哪条对外路径。 */
  private interfacePageTitle(): Resource {
    return this.interfaceSource === InterfacePageSource.web ?
      $r('app.string.local_device_interfaces_web') :
      $r('app.string.local_device_interfaces_localsend');
  }

  /** 接口在当前分组是否启用：两套白/黑名单分别对应 LocalSend 与网页服务。 */
  private isInterfaceEnabledForPage(item: NetworkInterface): boolean {
    if (this.interfaceSource === InterfacePageSource.web) {
      return networkSettingsViewModel.isInterfaceEnabled(item.name, item.type, this.webWhitelist, this.webBlacklist);
    }
    return networkSettingsViewModel.isInterfaceEnabled(item.name, item.type,
      this.networkWhitelist, this.networkBlacklist);
  }

  /** 进入接口页：打开前重新枚举，捕获 VPN/隧道等不触发系统网络事件的接口变化。 */
  private openInterfacePage(source: InterfacePageSource): void {
    updateLocalInterfaces();
    this.refresh();
    this.interfaceSource = source;
    this.onRequestInterfacePage(true);
  }

  private closeInterfacePage(): void {
    this.onRequestInterfacePage(false);
  }

  /** 分组标题：字号/字重/颜色同设置页分组标题；与卡片的间隔由卡片上外边距承担，此处只留段间上间距。 */
  @Builder
  groupTitle(label: ResourceStr, topSpace: number) {
    Text(label)
      .fontSize(DesignTokens.font.subtitleM)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
      .width('100%')
      .margin({ top: topSpace })
  }

  @Builder
  rowDivider() {
    Divider().color($r('app.color.border_light'))
  }

  /** 单行信息（标签 + 值，右对齐）：昵称等短字段使用。 */
  @Builder
  infoRow(label: ResourceStr, value: string) {
    Row({ space: DesignTokens.space.sm }) {
      Text(label)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
      Text(value.length > 0 ? value : $r('app.string.session_detail_placeholder'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .constraintSize({ maxWidth: '62%' })
    }
    .width('100%')
    .padding({
      left: DesignTokens.space.lg,
      right: DesignTokens.space.lg,
      top: DesignTokens.space.sm,
      bottom: DesignTokens.space.sm
    })
    .constraintSize({ minHeight: DesignTokens.size.thumbSm })
    .alignItems(VerticalAlign.Center)
  }

  /** 长值行：行距与最小高由外层容器承担，与其它信息行齐平；值经公共组件单行中间省略、点击看全文。 */
  @Builder
  longValueRow(label: ResourceStr, value: string) {
    Column() {
      SingleLineValueRow({
        label: label,
        value: value,
        rowFontSize: DesignTokens.font.bodyM
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({
      left: DesignTokens.space.lg,
      right: DesignTokens.space.lg,
      top: DesignTokens.space.sm,
      bottom: DesignTokens.space.sm
    })
    .constraintSize({ minHeight: DesignTokens.size.thumbSm })
  }

  /** 网络类型文字徽标（复用既有网络类型文案）。 */
  @Builder
  networkBadge(type: NetworkType) {
    Text(networkTypeLabel(type))
      .fontSize(DesignTokens.font.bodyS)
      .fontColor($r('app.color.ip_blue_text'))
      .backgroundColor($r('app.color.accent_blue_bg'))
      .padding({
        left: DesignTokens.space.tiny,
        right: DesignTokens.space.tiny,
        top: DesignTokens.space.mini,
        bottom: DesignTokens.space.mini
      })
      .borderRadius(DesignTokens.radius.sm)
      .maxLines(1)
  }

  /** 接口启用状态徽标：绿色已启用 / 灰色已禁用（接口对象按引用传递，状态变化可刷新）。 */
  @Builder
  statusBadge(item: NetworkInterface) {
    Text(this.isInterfaceEnabledForPage(item) ? $r('app.string.network_interface_status_enabled') :
      $r('app.string.network_interface_status_disabled'))
      .fontSize(DesignTokens.font.bodyS)
      .fontColor(this.isInterfaceEnabledForPage(item) ? $r('app.color.success_green') :
        $r('app.color.text_tertiary'))
      .backgroundColor(this.isInterfaceEnabledForPage(item) ? $r('app.color.success_bg') :
        $r('app.color.disabled_bg'))
      .padding({
        left: DesignTokens.space.tiny,
        right: DesignTokens.space.tiny,
        top: DesignTokens.space.mini,
        bottom: DesignTokens.space.mini
      })
      .borderRadius(DesignTokens.radius.sm)
      .maxLines(1)
  }

  /** 网络接口入口行：标签 + 右箭头，与设置页入口同款。 */
  @Builder
  interfaceEntryRow(source: InterfacePageSource) {
    Row() {
      Text($r('app.string.network_interface_label'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_forward'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width('100%')
    .padding({
      left: DesignTokens.space.lg,
      right: DesignTokens.space.lg,
      top: DesignTokens.space.sm,
      bottom: DesignTokens.space.sm
    })
    .constraintSize({ minHeight: DesignTokens.size.thumbSm })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openInterfacePage(source);
    })
    .id(source === InterfacePageSource.web ? 'local_device_web_interface_entry' : 'local_device_interface_entry')
  }

  /** 接口行：接口名 + 类型徽标 + 状态徽标 + 右对齐 IP（单行呈现）。 */
  @Builder
  interfaceRow(item: NetworkInterface) {
    Row({ space: DesignTokens.space.tiny }) {
      Text(item.name.length > 0 ? item.name : $r('app.string.session_detail_placeholder'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '38%' })
      this.networkBadge(item.type)
      this.statusBadge(item)
      Text(item.ip)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({
      left: DesignTokens.space.lg,
      right: DesignTokens.space.lg,
      top: DesignTokens.space.sm,
      bottom: DesignTokens.space.sm
    })
    .constraintSize({ minHeight: DesignTokens.size.thumbSm })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 轻量返回行：仿子页面 HdsNavDestination 标题栏的圆形返回按钮 + 标明分级的接口页标题。
   * 左右内边距由接口页容器承担，此处不再叠加，使按钮与子页面返回按钮的左缘对齐。
   */
  @Builder
  interfaceBackRow() {
    Row({ space: DesignTokens.space.sm }) {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_backward'))
          .fontSize(DesignTokens.size.iconSm)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(DesignTokens.size.iconLg)
      .height(DesignTokens.size.iconLg)
      .borderRadius(DesignTokens.radius.max)
      // 半模态背板与卡片背景同色，圆钮改用中性灰背板保证可辨识
      .backgroundColor($r('app.color.disabled_bg'))
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Text(this.interfacePageTitle())
        .fontSize(DesignTokens.font.subtitleM)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.xxs })
    .constraintSize({ minHeight: DesignTokens.size.thumbSm })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.closeInterfacePage();
    })
    .id('local_device_interface_back')
  }

  /** 本机信息页：三段分组。 */
  @Builder
  infoPage() {
    // 内容区用 Scroll 承载三段信息，保证窄屏（半模态初始档位）下末尾项仍可滚动到
    Scroll() {
      Column() {
        // ── 设备身份：两条路径共用的本机标识 ──
        this.groupTitle($r('app.string.local_device_group_identity'), DesignTokens.space.md)
        Column() {
          this.infoRow($r('app.string.local_device_alias'), this.alias)
          this.rowDivider()
          this.infoRow($r('app.string.local_device_type'), this.deviceTypeText)
          this.rowDivider()
          this.infoRow($r('app.string.local_device_model'), this.deviceModel)
        }
        .width('100%')
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })

        // ── LocalSend：对端靠组播扫描与 HTTPS 看到的本机 ──
        this.groupTitle($r('app.string.local_device_group_localsend'), DesignTokens.space.lg)
        Column() {
          // 指纹为长串十六进制：单行中间省略，点击弹出完整值（可复制）
          if (this.fingerprint.length > 0) {
            this.longValueRow($r('app.string.local_device_fingerprint'), this.fingerprint)
            this.rowDivider()
          }
          this.infoRow($r('app.string.local_device_port'), this.listenPort)
          this.rowDivider()
          this.infoRow($r('app.string.encrypted_transfer'), this.encryptedText)
          this.rowDivider()
          this.interfaceEntryRow(InterfacePageSource.localSend)
        }
        .width('100%')
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })

        // ── 网页：浏览器通过地址/二维码看到的本机服务 ──
        this.groupTitle($r('app.string.local_device_group_web'), DesignTokens.space.lg)
        Column() {
          this.infoRow($r('app.string.web_send_label'), this.webSendText)
          this.rowDivider()
          this.infoRow($r('app.string.web_receive_label'), this.webReceiveText)
          this.rowDivider()
          this.infoRow($r('app.string.web_port_label'), this.webPortText)
          this.rowDivider()
          this.infoRow($r('app.string.web_https_label'), this.webHttpsText)
          this.rowDivider()
          this.infoRow($r('app.string.web_pin_label'), this.webPinText)
          this.rowDivider()
          this.interfaceEntryRow(InterfacePageSource.web)
        }
        .width('100%')
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })

        // ── 互传：对端靠 BLE 广播与 GATT 看到的本机 ──
        this.groupTitle($r('app.string.local_device_group_mta'), DesignTokens.space.lg)
        Column() {
          this.infoRow($r('app.string.mta_simulated_brand_label'), this.mtaBrand)
          // 广播名称与昵称同源，仅在超出扫描响应名称区（16 字节）被截断时单独呈现差异
          if (this.mtaBroadcast.length > 0 && this.mtaBroadcast !== this.alias) {
            this.rowDivider()
            this.infoRow($r('app.string.local_device_broadcast_name'), this.mtaBroadcast)
          }
          // 发送者 ID 同为长串十六进制，交互与指纹行一致
          if (this.mtaDeviceId.length > 0) {
            this.rowDivider()
            this.longValueRow($r('app.string.local_device_mta_device_id'), this.mtaDeviceId)
          }
        }
        .width('100%')
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })
      }
      .width('100%')
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .translate({ x: this.showInterfacePage ? -this.pageWidth : 0 })
    .id('local_device_sheet')
  }

  /** 网络接口页：轻量返回行 + 全部接口列表。 */
  @Builder
  interfacePage() {
    Scroll() {
      Column() {
        this.interfaceBackRow()
        if (this.interfaces.length === 0) {
          EmptyState({
            mainText: $r('app.string.network_interface_empty'),
            useCard: true
          })
            .margin({ top: DesignTokens.space.md })
        } else {
          Column() {
            ForEach(this.interfaces, (item: NetworkInterface, index: number) => {
              Column() {
                this.interfaceRow(item)
                if (index < this.interfaces.length - 1) {
                  this.rowDivider()
                }
              }
              .width('100%')
            }, (item: NetworkInterface) => item.name + item.ip)
          }
          .width('100%')
          .borderRadius(DesignTokens.radius.lg)
          .backgroundColor($r('app.color.card_background'))
          .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
          .margin({ top: DesignTokens.space.md })
        }
      }
      .width('100%')
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .translate({ x: this.showInterfacePage ? 0 : this.pageWidth })
    .id('local_device_interface_page')
  }

  build() {
    // 两页叠放并左右平移切换：半模态内容区尺寸由宿主决定，平移距离取实际宽度
    Stack() {
      this.infoPage()
      this.interfacePage()
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      let width: number = typeof newValue.width === 'number' ? newValue.width : 0;
      if (width > 0) {
        this.pageWidth = width;
      }
    })
  }
}
