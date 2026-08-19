import { DesignTokens } from '../common/DesignTokens';
import { getDeviceIconResource } from '../utils/DeviceIconUtil';

// 传输页设备卡片（从 TransferPage.deviceCard @Builder 拆出）。
// 纯展示组件：@Param 收值，图标/短码逻辑内聚。
@ComponentV2
export struct TransferDeviceCard {
  @Param alias: string = ''
  @Param ip: string = ''
  @Param deviceType: string = 'mobile'
  @Param deviceModel: string = ''
  @Param isSource: boolean = false

  build() {
    Column() {
      Row({ space: DesignTokens.space.sm }) {
        Image(getDeviceIconResource(this.deviceType))
          .width(36)
          .height(36)
          .fillColor($r('app.color.text_primary'))

        Column() {
          Text(this.alias)
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))

          Row({ space: DesignTokens.space.xs }) {
            Text('#' + this.ip.split('.').pop())
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.ip_blue_text'))
              .backgroundColor($r('app.color.accent_blue_bg'))
              .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
              .borderRadius(DesignTokens.radius.sm)

            Text(this.deviceModel)
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.ip_blue_text'))
              .backgroundColor($r('app.color.accent_blue_bg'))
              .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
              .borderRadius(DesignTokens.radius.sm)
          }
          .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.isSource) {
          Text($r('app.string.transfer_from_label'))
            .fontSize(DesignTokens.font.captionM)
            .fontColor($r('app.color.text_on_color'))
            .backgroundColor($r('app.color.accent_blue'))
            .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
            .borderRadius(DesignTokens.radius.md)
        } else {
          Text($r('app.string.transfer_to_label'))
            .fontSize(DesignTokens.font.captionM)
            .fontColor($r('app.color.text_on_color'))
            .backgroundColor($r('app.color.success_green'))
            .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
            .borderRadius(DesignTokens.radius.md)
        }
      }
      .width('100%')
      .padding(DesignTokens.space.md)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: 1, color: $r('app.color.border_light') })
  }
}
