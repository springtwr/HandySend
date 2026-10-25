/**
 * LocalDeviceSection.ets — 「本机信息」精简展示
 *
 * 经发送页标题栏「本机信息」入口的 bindSheet 呈现，按本机对外宣告的两条路径分三段：
 * 设备身份（昵称 / 类型 / 型号）、LocalSend（设备指纹 / 监听端口 / 加密传输 / 各网卡 IP）、
 * 互传（模拟品牌 / 广播名称 / 发送者 ID）。字段与「设备详情页」的对端口径互为镜像。
 * 服务状态归属设置页的 LocalSend 分组，此处不重复展示。
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
  getPort,
  getHttpsEnabled,
  getWebSendAllowed,
  getWebReceiveAllowed,
  getWebHttpsEnabled,
  getWebPin,
  getWebPort,
  getWebActualPort,
  isWebPortFallback,
  getShareLink,
  getSelectedWebAddress,
  getMtaSimulatedBrand,
  getLocalMtaDeviceIdHex,
  mtaBroadcastName
} from '../../service/AppService';
import { NetworkInterface, NetworkType } from '../../model/Types';
import { WebAddress } from '../../model/WebAddress';
import { networkTypeLabel } from '../../utils/NetworkPresentation';
import { resolveMtaBrandDisplayName } from '../../model/mta/MtaBrandRegistry';
import { getStringSync } from '../../utils/ResourceUtil';
import { SingleLineValueRow } from '../../components/SingleLineValueRow';

@ComponentV2
export struct LocalDeviceSection {
  @Local private alias: string = ''
  @Local private deviceTypeText: string = ''
  @Local private deviceModel: string = ''
  @Local private fingerprint: string = ''
  @Local private listenPort: string = ''
  @Local private encryptedText: string = ''
  @Local private interfaces: Array<NetworkInterface> = []
  @Local private webStatus: string = ''
  @Local private webAddress: string = ''
  @Local private webSendText: string = ''
  @Local private webReceiveText: string = ''
  @Local private webHttpsText: string = ''
  @Local private webPinText: string = ''
  @Local private webInterfaceText: string = ''
  @Local private webPortText: string = ''
  @Local private mtaBrand: string = ''
  @Local private mtaBroadcast: string = ''
  @Local private mtaDeviceId: string = ''
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

    let list: Array<NetworkInterface> = getLocalInterfaces();
    let result: Array<NetworkInterface> = [];
    for (let i = 0; i < list.length; i++) {
      // 仅保留有实际 IP 的网卡，并按 IP 去重（同一网卡多地址场景）
      if (list[i].ip.length === 0) {
        continue;
      }
      let duplicated: boolean = false;
      for (let k = 0; k < result.length; k++) {
        if (result[k].ip === list[i].ip) {
          duplicated = true;
          break;
        }
      }
      if (!duplicated) {
        result.push(list[i]);
      }
    }
    this.interfaces = result;

    // 网页独立服务：状态/地址/开关/加密/PIN/当前展示网卡/端口
    let webRunning: boolean = getWebActualPort() > 0;
    this.webStatus = getStringSync(this.getUIContext(),
      webRunning ? $r('app.string.service_status_running') : $r('app.string.service_status_stopped'));
    this.webAddress = getShareLink();
    this.webSendText = this.onOffText(getWebSendAllowed());
    this.webReceiveText = this.onOffText(getWebReceiveAllowed());
    this.webHttpsText = this.onOffText(getWebHttpsEnabled());
    this.webPinText = getStringSync(this.getUIContext(),
      getWebPin().length > 0 ? $r('app.string.web_pin_status_set') : $r('app.string.web_pin_status_unset'));
    let selectedAddress: WebAddress | undefined = getSelectedWebAddress();
    this.webInterfaceText = selectedAddress !== undefined ?
      this.resolveResourceText(networkTypeLabel(selectedAddress.type)) + ' · ' + selectedAddress.ip : '';
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

  /** 网卡行：接口名 + 网络类型文字徽标 + IP（单行呈现）。 */
  @Builder
  interfaceRow(item: NetworkInterface) {
    Row({ space: DesignTokens.space.tiny }) {
      Text(item.name.length > 0 ? item.name : $r('app.string.session_detail_placeholder'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      this.networkBadge(item.type)
      Text(item.ip)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
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

  build() {
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
          Repeat(this.interfaces)
            .each((ri: RepeatItem<NetworkInterface>) => {
              this.rowDivider()
              this.interfaceRow(ri.item)
            })
            .key((item: NetworkInterface) => item.ip + item.name)
        }
        .width('100%')
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })

        // ── 网页：浏览器通过地址/二维码看到的本机服务 ──
        this.groupTitle($r('app.string.local_device_group_web'), DesignTokens.space.lg)
        Column() {
          this.infoRow($r('app.string.web_info_status'), this.webStatus)
          if (this.webAddress.length > 0) {
            this.rowDivider()
            this.longValueRow($r('app.string.web_info_address'), this.webAddress)
          }
          this.rowDivider()
          this.infoRow($r('app.string.web_send_label'), this.webSendText)
          this.rowDivider()
          this.infoRow($r('app.string.web_receive_label'), this.webReceiveText)
          this.rowDivider()
          this.infoRow($r('app.string.web_https_label'), this.webHttpsText)
          this.rowDivider()
          this.infoRow($r('app.string.web_pin_label'), this.webPinText)
          if (this.webInterfaceText.length > 0) {
            this.rowDivider()
            this.infoRow($r('app.string.web_interface_label'), this.webInterfaceText)
          }
          this.rowDivider()
          this.infoRow($r('app.string.web_port_label'), this.webPortText)
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
    .id('local_device_sheet')
  }
}
