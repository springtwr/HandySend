import { DesignTokens } from '../common/DesignTokens';
import { getDeviceIconResource } from '../utils/DeviceIconUtil';

// 传输页设备卡片（从 TransferPage.deviceCard @Builder 拆出）。
// 纯展示组件：@Param 收值，图标/短码逻辑内聚。
// 方向（来自/发送到）由传输页上方的方向文字体现，卡片本身不重复显示方向角标。
@ComponentV2
export struct TransferDeviceCard {
  @Param alias: string = ''
  @Param ip: string = ''
  @Param deviceType: string = 'mobile'
  @Param deviceModel: string = ''
  // 可选前导徽标：showLeadingBadge 为 true 时在品牌/IP 徽标之前展示（MTA 对端为本地化来源徽标）；
  // ResourceStr 不能取 length，故用独立布尔参数 showLeadingBadge 判定存在性；
  // 既有调用不传这两个参数时展示与行为完全不变。
  @Param leadingBadge: ResourceStr = ''
  @Param showLeadingBadge: boolean = false
  // 可选来源徽标：非空时以品牌名徽标替代 IP 短码（MTA 等无 IP 的对端使用）；
  // 既有调用不传此参数（空串）时展示与行为完全不变。
  @Param badgeText: string = ''

  // 徽标统一样式（前导 / 品牌 / IP 短码 / 型号共用，保证 DesignToken 一致）
  @Builder
  badge(text: ResourceStr) {
    Text(text)
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
  }

  build() {
    Column() {
      Row({ space: DesignTokens.space.sm }) {
        Image(getDeviceIconResource(this.deviceType))
          .width(DesignTokens.size.iconLg)
          .height(DesignTokens.size.iconLg)
          .fillColor($r('app.color.text_primary'))

        Column() {
          Text(this.alias)
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .id('transfer_peer_alias')

          Row({ space: DesignTokens.space.tiny }) {
            if (this.showLeadingBadge) {
              this.badge(this.leadingBadge)
            }

            // 品牌徽标优先；无品牌且无 IP（如 MTA 接收对端）时不渲染 IP 短码徽标，避免出现孤立的「#」
            if (this.badgeText.length > 0) {
              this.badge(this.badgeText)
            } else if (this.ip.length > 0) {
              this.badge('#' + (this.ip.split('.').pop() ?? ''))
            }

            if (this.deviceModel.length > 0 || (this.badgeText.length === 0 && !this.showLeadingBadge)) {
              this.badge(this.deviceModel)
            }
          }
          .margin({ top: DesignTokens.space.tiny })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({
        left: DesignTokens.space.sm,
        right: DesignTokens.space.sm,
        top: DesignTokens.space.sm,
        bottom: DesignTokens.space.sm
      })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    .id('transfer_device_card')
  }
}
