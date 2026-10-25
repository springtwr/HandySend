import { SymbolGlyphModifier } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';
import { WebAddress } from '../model/WebAddress';
import { NetworkType } from '../model/Types';
import { networkTypeLabel } from '../utils/NetworkPresentation';
import { getStringSync } from '../utils/ResourceUtil';

/**
 * WebAccessEntryCard — 网页服务地址区。
 *
 * 沿用分享页最初的排版：地址标签与地址胶囊整体居中，二维码单独成块、
 * 与地址保持一段间距，提示文案居中收尾。两侧不套卡片容器，
 * 页面只用左右页边距约束，避免二维码贴住标题栏。
 * 多地址时在地址胶囊下方追加一个轻量的“网卡类型 + 下箭头”选择器，
 * 菜单列出类型与 IP；单地址时不显示，保持原页面风格。
 */
@ComponentV2
export struct WebAccessEntryCard {
  @Param url: string = ''
  // 二维码边长：随窗口断点放大，避免大屏上过小
  @Param qrSize: number = DesignTokens.size.qrCodeSize
  // 可展示的网页地址；多于一个时出现地址选择器
  @Param addresses: Array<WebAddress> = []
  // 上次选择/当前展示的地址 IP；为空时取排序后的第一个
  @Param selectedAddressIp: string = ''
  @Event onCopy: (url: string) => void = (_url: string) => {
  }
  @Event onSelectAddress: (ip: string) => void = (_ip: string) => {
  }

  private selectedAddress(): WebAddress | undefined {
    for (let i = 0; i < this.addresses.length; i++) {
      if (this.addresses[i].ip === this.selectedAddressIp) {
        return this.addresses[i];
      }
    }
    return this.addresses.length > 0 ? this.addresses[0] : undefined;
  }

  private isAddressSelected(address: WebAddress): boolean {
    let selected = this.selectedAddress();
    return selected !== undefined && selected.ip === address.ip;
  }

  private interfaceLabel(type: NetworkType): string {
    let label: ResourceStr = networkTypeLabel(type);
    return typeof label === 'string' ? label : getStringSync(this.getUIContext(), label);
  }

  private selectedTypeLabel(): string {
    let address = this.selectedAddress();
    return address !== undefined ? this.interfaceLabel(address.type) : '';
  }

  private addressMenuLabel(address: WebAddress): string {
    return this.interfaceLabel(address.type) + ' · ' + address.ip;
  }

  private checkModifier(address: WebAddress): SymbolGlyphModifier | undefined {
    return this.isAddressSelected(address) ?
      new SymbolGlyphModifier($r('sys.symbol.checkmark')) : undefined;
  }

  @Builder
  addressMenu() {
    Menu() {
      ForEach(this.addresses, (address: WebAddress) => {
        MenuItem({
          content: this.addressMenuLabel(address),
          symbolEndIcon: this.checkModifier(address)
        })
          .onClick(() => {
            this.onSelectAddress(address.ip);
          })
      }, (address: WebAddress) => address.name + address.ip)
    }
  }

  build() {
    Column() {
      // 地址区：标签 + 可点击地址 + 多地址选择器，整体居中
      Column() {
        Text($r('app.string.share_link_address_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ bottom: DesignTokens.space.tiny })

        Text(this.url)
          .fontSize(DesignTokens.font.subtitleM)
          .fontColor($r('app.color.purple_text'))
          .fontWeight(FontWeight.Medium)
          .padding({
            left: DesignTokens.space.md,
            right: DesignTokens.space.md,
            top: DesignTokens.space.sm,
            bottom: DesignTokens.space.sm
          })
          .backgroundColor($r('app.color.purple_bg'))
          .borderRadius(DesignTokens.radius.md)
          .onClick(() => {
            this.onCopy(this.url);
          })
          .id('web_access_address')

        // 多地址时：轻量文本选择器，不新增卡片/胶囊
        if (this.addresses.length > 1) {
          Row({ space: DesignTokens.space.mini }) {
            Text(this.selectedTypeLabel())
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_tertiary'))
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(DesignTokens.font.iconXs)
              .fontColor([$r('app.color.text_tertiary')])
          }
          .padding({
            left: DesignTokens.space.tiny,
            right: DesignTokens.space.tiny,
            top: DesignTokens.space.mini,
            bottom: DesignTokens.space.mini
          })
          .margin({ top: DesignTokens.space.xxs })
          .borderRadius(DesignTokens.radius.sm)
          .bindMenu(this.addressMenu)
          .accessibilityText($r('app.string.web_address_switch'))
          .id('web_access_address_selector')
        }
      }
      .alignItems(HorizontalAlign.Center)

      // 二维码区：与地址拉开一段间距，整体居中
      Column() {
        Column() {
          QRCode(this.url)
            .width(this.qrSize)
            .height(this.qrSize)
            .backgroundColor($r('app.color.qr_code_background'))
        }
        .width(this.qrSize + DesignTokens.space.md * 2)
        .height(this.qrSize + DesignTokens.space.md * 2)
        .backgroundColor($r('app.color.qr_code_background'))
        .borderRadius(DesignTokens.radius.md)
        .justifyContent(FlexAlign.Center)

        Text($r('app.string.share_link_qr_hint'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: DesignTokens.space.sm })
      }
      .alignItems(HorizontalAlign.Center)
      .width('100%')
      .margin({ top: DesignTokens.space.lg })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
