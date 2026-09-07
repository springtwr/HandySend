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
            Text('#' + this.ip.split('.').pop())
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

            Text(this.deviceModel)
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
