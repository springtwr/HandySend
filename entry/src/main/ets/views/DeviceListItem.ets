import { DesignTokens } from '../common/DesignTokens';
import { SendViewModel } from '../viewmodel/SendViewModel';
import { DeviceItemViewModel } from '../viewmodel/DeviceItemViewModel';
import { getDeviceIconResource } from '../utils/DeviceIconUtil';

// 发送页设备列表项（从 SendContent 的 Repeat 拆出）。
// 设备卡片 + 发送状态 + 收藏交互（心形图标一键收藏/取消收藏）；
// 发送/详情导航经回调上抛（父组件持有 UIContext 路由）。
@ComponentV2
export struct DeviceListItem {
  @Param device: DeviceItemViewModel = new DeviceItemViewModel({
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
  })
  @Require @Param viewModel: SendViewModel
  @Event onSend: (device: DeviceItemViewModel) => void = (_device: DeviceItemViewModel) => {
  }
  @Event onInfo: (device: DeviceItemViewModel) => void = (_device: DeviceItemViewModel) => {
  }

  private isDeviceFavorite(fingerprint: string): boolean {
    for (let i = 0; i < this.viewModel.favoriteDevices.length; i++) {
      if (this.viewModel.favoriteDevices[i].fingerprint === fingerprint) {
        return true;
      }
    }
    return false;
  }

  // 徽标统一样式（IP 短码 / 型号 / MTA 来源 / 品牌四个徽标共用，保证样式与 DesignToken 完全一致）
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
        if (this.device.isMta) {
          // MTA 设备：对端手机品牌彩色图标，保持原图形色彩（不套 fillColor）
          Image(this.device.mtaPhoneBrandIcon)
            .width(DesignTokens.size.iconLg).height(DesignTokens.size.iconLg)
        } else {
          Image(getDeviceIconResource(this.device.deviceType))
            .width(DesignTokens.size.iconLg).height(DesignTokens.size.iconLg)
            .fillColor($r('app.color.text_primary'))
        }

        Column() {
          Text(this.device.alias)
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .id('send_device_alias')

          Row({ space: DesignTokens.space.tiny }) {
            if (this.device.isMta) {
              // MTA 设备：本地化来源徽标 + 品牌徽标（无 IP；品牌未知时回退 Android）
              this.badge($r('app.string.mta_source_badge'))
              this.badge(this.device.mtaBrandBadge)
            } else {
              this.badge('#' + (this.device.ip.split('.').pop() ?? ''))
              this.badge(this.device.deviceModel)
            }
          }
          .margin({ top: DesignTokens.space.tiny })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 心形图标（MTA 设备不参与 LocalSend 收藏体系，隐藏收藏交互）
        if (!this.device.isMta) {
          SymbolGlyph(
            this.isDeviceFavorite(this.device.fingerprint) ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(DesignTokens.size.iconSm)
            .fontColor([this.isDeviceFavorite(this.device.fingerprint) ? $r('app.color.danger_red') :
              $r('app.color.text_secondary')])
            .responseRegion({
              x: -13,
              y: -13,
              width: 48,
              height: 48
            })
            .onClick(() => {
              this.viewModel.toggleFavorite(this.device.fingerprint);
            })
            .id('send_device_favorite')

          // 信息按钮响应区域→48vp
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(DesignTokens.size.iconSm)
            .fontColor([$r('app.color.text_secondary')])
            .margin({ left: DesignTokens.space.xxs })
            .responseRegion({
              x: -8,
              y: -8,
              width: 48,
              height: 48
            })
            .onClick(() => {
              this.onInfo(this.device);
            })
            .id('send_device_info')
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.page_background'))
    .borderRadius(DesignTokens.radius.md)
    .onClick(() => {
      this.onSend(this.device);
    })
    .id('send_device_item')
  }
}
