import { SymbolGlyphModifier } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';
import { WebAddress } from '../model/WebAddress';
import { NetworkType } from '../model/Types';
import { networkTypeSymbol } from '../utils/NetworkPresentation';

/**
 * WebAccessEntryCard — 网页服务入口区。
 *
 * 二维码在上（扫码免密进入），访问码与手动访问地址在下：
 * 无法扫码时手动输入地址并输入访问码。访问码与地址均可点击复制。
 * 多网卡时在手动地址旁提供下拉箭头，菜单项为 IP + 网络类型图标 + 选中勾。
 * token 只存在于二维码链接中，普通用户无需感知。
 */
@ComponentV2
export struct WebAccessEntryCard {
  @Param url: string = ''
  // 本次分享的访问码：仅用于裸地址手动输入，点击可复制
  @Param accessCode: string = ''
  // 二维码边长：随窗口断点放大，避免大屏上过小
  @Param qrSize: number = DesignTokens.size.qrCodeSize
  // 可展示的网页地址；多于一个时出现地址选择器
  @Param addresses: Array<WebAddress> = []
  // 上次选择/当前展示的地址 IP；为空时取排序后的第一个
  @Param selectedAddressIp: string = ''
  @Event onCopy: (url: string) => void = (_url: string) => {
  }
  @Event onCopyAccessCode: (code: string) => void = (_code: string) => {
  }
  @Event onSelectAddress: (ip: string) => void = (_ip: string) => {
  }

  /** 手动访问用的裸地址：去掉二维码链接里的能力令牌参数。 */
  private manualUrl(): string {
    let index: number = this.url.indexOf('?t=');
    return index >= 0 ? this.url.substring(0, index) : this.url;
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

  private typeModifier(address: WebAddress): SymbolGlyphModifier {
    return new SymbolGlyphModifier(networkTypeSymbol(address.type));
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
          content: address.ip,
          symbolStartIcon: this.typeModifier(address),
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
      // 二维码区：扫码免密进入
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

      // 访问码与手动访问地址：无法扫码时使用
      if (this.accessCode.length > 0) {
        Column({ space: DesignTokens.space.xxs }) {
          Text($r('app.string.web_access_code_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_tertiary'))

          Text(this.accessCode)
            .fontSize(DesignTokens.font.subtitleL)
            .fontColor($r('app.color.purple_text'))
            .fontWeight(FontWeight.Medium)
            .padding({
              left: DesignTokens.space.md,
              right: DesignTokens.space.md,
              top: DesignTokens.space.mini,
              bottom: DesignTokens.space.mini
            })
            .backgroundColor($r('app.color.purple_bg'))
            .borderRadius(DesignTokens.radius.md)
            .onClick(() => {
              this.onCopyAccessCode(this.accessCode);
            })
            .id('web_access_code')

          Text($r('app.string.web_access_code_hint'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)

          // 手动访问地址：点击复制；多网卡时右侧下拉切换
          Row({ space: DesignTokens.space.mini }) {
            Text(this.manualUrl())
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.purple_text'))
              .onClick(() => {
                this.onCopy(this.manualUrl());
              })
              .id('web_access_manual_url')

            if (this.addresses.length > 1) {
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(DesignTokens.font.iconXs)
                .fontColor([$r('app.color.text_tertiary')])
                .padding(DesignTokens.space.mini)
                .borderRadius(DesignTokens.radius.sm)
                .bindMenu(this.addressMenu)
                .accessibilityText($r('app.string.web_address_switch'))
                .id('web_access_address_selector')
            }
          }
          .alignItems(VerticalAlign.Center)
        }
        .margin({ top: DesignTokens.space.lg })
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
