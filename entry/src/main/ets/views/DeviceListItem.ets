import { DesignTokens } from '../common/DesignTokens';
import { SendViewModel } from '../viewmodel/SendViewModel';
import { DeviceItemViewModel } from '../viewmodel/DeviceItemViewModel';
import { getDeviceIconResource } from '../utils/DeviceIconUtil';
import {
  sessionStatusFromString,
  sessionStatusLabel,
  sessionStatusColor,
  sessionStatusBgColor,
  sessionErrorMessage
} from '../utils/SessionStatusPresentation';
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
  private getDeviceSendStatus(ip: string): ResourceStr {
    let status = this.viewModel.sendSessionStatuses[ip];
    if (status === undefined || status === '') {
      return '';
    }
    let sessionStatus = sessionStatusFromString(status);
    if (sessionStatus === undefined) {
      return status;
    }
    // finishedWithErrors/pinRequired 优先显示具体错误消息
    let errMsg = this.viewModel.sendSessionErrorMessages[ip] ?? '';
    let err: ResourceStr | null = sessionErrorMessage(sessionStatus, errMsg);
    if (err !== null) {
      return err;
    }
    return sessionStatusLabel(sessionStatus);
  }

  private getDeviceStatusColor(ip: string): ResourceColor {
    let status = this.viewModel.sendSessionStatuses[ip];
    let sessionStatus = sessionStatusFromString(status);
    if (sessionStatus === undefined) {
      return $r('app.color.text_secondary');
    }
    return sessionStatusColor(sessionStatus);
  }

  private getDeviceStatusBgColor(ip: string): ResourceColor {
    let status = this.viewModel.sendSessionStatuses[ip];
    let sessionStatus = sessionStatusFromString(status);
    if (sessionStatus === undefined) {
      return $r('app.color.page_background');
    }
    return sessionStatusBgColor(sessionStatus);
  }

  // 读取某设备的发送百分比；不存在时返回 0（UI 据此决定是否展示百分比）。
  private getDeviceProgressPercent(ip: string): number {
    let p: number | undefined = this.viewModel.sendSessionProgress[ip];
    if (p === undefined) {
      return 0;
    }
    return p;
  }

  private isDeviceFavorite(fingerprint: string): boolean {
    for (let i = 0; i < this.viewModel.favoriteDevices.length; i++) {
      if (this.viewModel.favoriteDevices[i].fingerprint === fingerprint) {
        return true;
      }
    }
    return false;
  }

  build() {
    Column() {
      Row({ space: DesignTokens.space.sm }) {
        Image(getDeviceIconResource(this.device.deviceType))
          .width(DesignTokens.size.iconLg).height(DesignTokens.size.iconLg)
          .fillColor($r('app.color.text_primary'))

        Column() {
          Text(this.device.alias)
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Row({ space: DesignTokens.space.tiny }) {
            Text('#' + this.device.ip.split('.').pop())
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

            Text(this.device.deviceModel)
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
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 心形图标
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
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 多目标模式：进度条 + 状态/提示放在设备卡片最下方，占全宽（传输时卡片略高），不挤占左侧名称/标签
      if (this.viewModel.sendMode === 'multiple' && this.getDeviceSendStatus(this.device.ip) !== '') {
        Row({ space: DesignTokens.space.sm }) {
          Progress({ value: this.getDeviceProgressPercent(this.device.ip), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(4)
            .color($r('app.color.accent_blue'))
            .backgroundColor($r('app.color.border_light'))
            .layoutWeight(1)
          Text(Math.round(this.getDeviceProgressPercent(this.device.ip)) + '%')
            .fontSize(DesignTokens.font.captionM)
            .fontColor($r('app.color.text_secondary'))
            .width(DesignTokens.space.xl + 6)
            .textAlign(TextAlign.End)
          Text(this.getDeviceSendStatus(this.device.ip))
            .fontSize(DesignTokens.font.captionM)
            .fontColor(this.getDeviceStatusColor(this.device.ip))
            .backgroundColor(this.getDeviceStatusBgColor(this.device.ip))
            .padding({
              left: DesignTokens.space.tiny,
              right: DesignTokens.space.tiny,
              top: DesignTokens.space.mini,
              bottom: DesignTokens.space.mini
            })
            .borderRadius(DesignTokens.radius.sm)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 180 })
        }
        .width('100%')
        .margin({ top: DesignTokens.space.sm })
      }
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.page_background'))
    .borderRadius(DesignTokens.radius.md)
    .onClick(() => {
      this.onSend(this.device);
    })
  }

}
