import { DesignTokens } from '../common/DesignTokens';
import { DiscoveredDevice } from '../model/Types';
import { getDeviceIconResource } from '../utils/DeviceIconUtil';

// 接收页收藏设备项（从 ReceiveContent 的 Repeat 拆出）。
// 纯展示 + 移除收藏回调上抛；图标映射内聚。
@ComponentV2
export struct FavoriteDeviceItem {
  @Param device: DiscoveredDevice = {
    alias: '',
    ip: '',
    port: 0,
    fingerprint: '',
    version: '',
    deviceModel: '',
    deviceType: 'mobile',
    protocol: 'http',
    lastSeen: 0,
    channels: []
  }
  @Event onRemove: (fingerprint: string) => void = (_fingerprint: string) => {
  }

  private getDeviceIcon(deviceType: string): Resource {
    return getDeviceIconResource(deviceType);
  }

  build() {
    Row({ space: DesignTokens.space.sm }) {
      Image(this.getDeviceIcon(this.device.deviceType))
        .width(40).height(40)
        .fillColor($r('app.color.text_primary'))

      Column() {
        Text(this.device.alias)
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))

        Row({ space: DesignTokens.space.xs }) {
          Text('#' + this.device.ip.split('.').pop())
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.ip_blue_text'))
            .backgroundColor($r('app.color.accent_blue_bg'))
            .padding({
              left: DesignTokens.space.xs,
              right: DesignTokens.space.xs,
              top: DesignTokens.space.mini,
              bottom: DesignTokens.space.mini
            })
            .borderRadius(DesignTokens.radius.sm)

          Text(this.device.deviceModel)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.ip_blue_text'))
            .backgroundColor($r('app.color.accent_blue_bg'))
            .padding({
              left: DesignTokens.space.xs,
              right: DesignTokens.space.xs,
              top: DesignTokens.space.mini,
              bottom: DesignTokens.space.mini
            })
            .borderRadius(DesignTokens.radius.sm)
        }
        .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 心形图标响应区域→48vp
      SymbolGlyph($r('sys.symbol.heart_fill'))
        .fontSize(22)
        .fontColor([$r('app.color.danger_red')])
        .responseRegion({
          x: -13,
          y: -13,
          width: 48,
          height: 48
        })
        .onClick(() => {
          this.onRemove(this.device.fingerprint);
        })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.page_background'))
    .borderRadius(DesignTokens.radius.md)
    .alignItems(VerticalAlign.Center)
  }
}
