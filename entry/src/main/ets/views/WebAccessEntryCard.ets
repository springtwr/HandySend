import { SymbolGlyphModifier } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';
import { WebAddress } from '../model/WebAddress';
import { NetworkType } from '../model/Types';
import { networkTypeLabel } from '../utils/NetworkPresentation';
import { getStringSync } from '../utils/ResourceUtil';

/**
 * WebAccessEntryCard — 网页服务入口区。
 *
 * 访问码组在上（访问码与手动访问地址），二维码组在下。
 * 手动地址：多网卡时单击打开接口下拉菜单，长按/双击复制；
 * 单网卡时单击复制。token 只存在于二维码链接中，普通用户无需感知。
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

  private interfaceLabel(type: NetworkType): string {
    let label: ResourceStr = networkTypeLabel(type);
    return typeof label === 'string' ? label : getStringSync(this.getUIContext(), label);
  }

  private checkModifier(address: WebAddress): SymbolGlyphModifier | undefined {
    return this.isAddressSelected(address) ?
      new SymbolGlyphModifier($r('sys.symbol.checkmark')) : undefined;
  }

  private addressMenuLabel(address: WebAddress): string {
    return this.interfaceLabel(address.type) + ' · ' + address.ip;
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

  @Builder
  accessCodeGroup() {
    Column({ space: DesignTokens.space.xxs }) {
      Row({ space: DesignTokens.space.xxs }) {
        Text($r('app.string.web_access_code_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_tertiary'))

        Text(this.accessCode)
          .fontSize(DesignTokens.font.subtitleL)
          .fontColor($r('app.color.purple_text'))
          .fontWeight(FontWeight.Medium)
      }
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

      // 手动访问地址：多网卡时单击打开接口菜单，长按/双击复制；单网卡时单击复制
      if (this.addresses.length > 1) {
        Row({ space: DesignTokens.space.mini }) {
          Text(this.manualUrl())
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.purple_text'))
            .id('web_access_manual_url')

          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(DesignTokens.font.iconXs)
            .fontColor([$r('app.color.text_tertiary')])
        }
        .padding(DesignTokens.space.mini)
        .borderRadius(DesignTokens.radius.sm)
        .bindMenu(this.addressMenu)
        .gesture(LongPressGesture().onAction(() => {
          this.onCopy(this.manualUrl());
        }))
        .accessibilityText($r('app.string.web_address_switch'))
        .id('web_access_address_selector')
      } else {
        Text(this.manualUrl())
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.purple_text'))
          .onClick(() => {
            this.onCopy(this.manualUrl());
          })
          .id('web_access_manual_url')
      }
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  qrGroup() {
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
  }

  build() {
    Column() {
      if (this.accessCode.length > 0) {
        this.accessCodeGroup()
      }

      Column() {
        this.qrGroup()
      }
      .width('100%')
      .margin({ top: this.accessCode.length > 0 ? DesignTokens.space.lg : 0 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
