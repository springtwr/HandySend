import { DialogService } from '../service/DialogService';
import { DesignTokens } from '../common/DesignTokens';
import { DiscoveredDevice } from '../model/Types';
import { SendViewModel } from '../viewmodel/SendViewModel';
import { getDeviceIconResource } from '../utils/DeviceIconUtil';

// 发送页设备列表项（从 SendContent 的 Repeat 拆出）。
// 设备卡片 + 发送状态 + 收藏交互 + 长按收藏编辑/删除对话框内聚；
// 发送/详情导航经回调上抛（父组件持有 UIContext 路由）。
@ComponentV2
export struct DeviceListItem {
  @Param device: DiscoveredDevice = {
    alias: '', ip: '', port: 0, fingerprint: '', version: '', deviceModel: '',
    deviceType: 'mobile', protocol: 'http', lastSeen: 0, channels: []
  }
  @Require @Param viewModel: SendViewModel
  @Event onSend: (device: DiscoveredDevice) => void = (_device: DiscoveredDevice) => {}
  @Event onInfo: (device: DiscoveredDevice) => void = (_device: DiscoveredDevice) => {}

  private getDeviceSendStatus(ip: string): string {
    let status = this.viewModel.sendSessionStatuses[ip];
    if (status === undefined || status === '') {
      return '';
    }
    return this.getStatusLabel(status);
  }

  private getStatusLabel(status: string): string {
    if (status === 'waiting') {
      return this.getResourceString($r('app.string.session_status_waiting'));
    } else if (status === 'calculatingHash') {
      return this.getResourceString($r('app.string.session_status_checksum'));
    } else if (status === 'sending') {
      return this.getResourceString($r('app.string.session_status_sending'));
    } else if (status === 'finished') {
      return this.getResourceString($r('app.string.session_status_done'));
    } else if (status === 'finishedWithErrors') {
      return this.getResourceString($r('app.string.session_status_error'));
    } else if (status === 'declined') {
      return this.getResourceString($r('app.string.session_status_declined'));
    } else if (status === 'canceled' || status === 'canceledByReceiver') {
      return this.getResourceString($r('app.string.session_status_canceled'));
    } else if (status === 'tooManyAttempts') {
      return this.getResourceString($r('app.string.session_status_locked'));
    } else if (status === 'viewed') {
      return this.getResourceString($r('app.string.session_status_viewed'));
    } else if (status === 'recipientBusy') {
      return this.getResourceString($r('app.string.session_status_busy'));
    }
    return status;
  }

  private getResourceString(res: Resource): string {
    let ctx = getContext(this);
    try {
      return ctx.resourceManager.getStringSync(res.id);
    } catch (_e) {
      return '';
    }
  }

  private getDeviceStatusColor(ip: string): ResourceColor {
    let status = this.viewModel.sendSessionStatuses[ip];
    if (status === 'sending' || status === 'calculatingHash') {
      return $r('app.color.accent_blue');
    } else if (status === 'finished') {
      return $r('app.color.success_green');
    } else if (status === 'finishedWithErrors') {
      return $r('app.color.warning_orange');
    } else if (status === 'viewed') {
      return $r('app.color.success_green');
    } else if (status === 'recipientBusy') {
      return $r('app.color.danger_red');
    } else if (status === 'declined' || status === 'canceled' || status === 'canceledByReceiver' || status === 'tooManyAttempts') {
      return $r('app.color.danger_red');
    }
    return $r('app.color.text_secondary');
  }

  private getDeviceStatusBgColor(ip: string): ResourceColor {
    let status = this.viewModel.sendSessionStatuses[ip];
    if (status === 'sending' || status === 'calculatingHash') {
      return $r('app.color.accent_blue_bg');
    } else if (status === 'finished') {
      return $r('app.color.success_bg');
    } else if (status === 'finishedWithErrors') {
      return $r('app.color.warning_bg');
    } else if (status === 'viewed') {
      return $r('app.color.success_bg');
    } else if (status === 'recipientBusy') {
      return $r('app.color.danger_bg');
    } else if (status === 'declined' || status === 'canceled' || status === 'canceledByReceiver' || status === 'tooManyAttempts') {
      return $r('app.color.danger_bg');
    }
    return $r('app.color.page_background');
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
    Row({ space: DesignTokens.space.sm }) {
      Image(getDeviceIconResource(this.device.deviceType))
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
            .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
            .borderRadius(DesignTokens.radius.sm)

          Text(this.device.deviceModel)
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

      if (this.viewModel.sendMode === 'multiple' && this.getDeviceSendStatus(this.device.ip) !== '') {
        Text(this.getDeviceSendStatus(this.device.ip))
          .fontSize(DesignTokens.font.captionM)
          .fontColor(this.getDeviceStatusColor(this.device.ip))
          .backgroundColor(this.getDeviceStatusBgColor(this.device.ip))
          .padding({ left: 6, right: 6, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
          .borderRadius(DesignTokens.radius.sm)
      }

      // 心形图标
      SymbolGlyph(this.isDeviceFavorite(this.device.fingerprint) ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
        .fontSize(22)
        .fontColor([this.isDeviceFavorite(this.device.fingerprint) ? $r('app.color.danger_red') : $r('app.color.text_secondary')])
        .responseRegion({ x: -13, y: -13, width: 48, height: 48 })
        .onClick(() => {
          this.viewModel.toggleFavorite(this.device.fingerprint);
        })

      // 信息按钮响应区域→48vp
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(22)
        .fontColor([$r('app.color.text_secondary')])
        .margin({ left: 4 })
        .responseRegion({ x: -8, y: -8, width: 48, height: 48 })
        .onClick(() => {
          this.onInfo(this.device);
        })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.page_background'))
    .borderRadius(DesignTokens.radius.md)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onSend(this.device);
    })
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          if (this.isDeviceFavorite(this.device.fingerprint)) {
            DialogService.showFavoriteDeleteDialog(this.device, () => {
              this.viewModel.removeFavorite(this.device.fingerprint);
            });
          } else {
            DialogService.showFavoriteEditDialog(this.device, (newAlias: string) => {
              this.viewModel.addFavorite(this.device, newAlias);
            });
          }
        })
    )
  }
}
