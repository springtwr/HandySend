import { DesignTokens } from '../common/DesignTokens';
import { DebugViewModel } from '../viewmodel/DebugViewModel';
import { NetworkInterface, NetworkType } from '../model/Types';

@Entry
@ComponentV2
struct DebugPage {
  @Local viewModel: DebugViewModel = new DebugViewModel();

  aboutToAppear(): void {
    this.viewModel.loadInfo();
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_backward'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontColor([$r('app.color.text_primary')])
          .responseRegion({
            x: -12,
            y: -12,
            width: 48,
            height: 48
          })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.service_info_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: DesignTokens.space.sm }) {
          // 设备信息
          Column() {
            Text($r('app.string.debug_device_info'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ bottom: DesignTokens.space.xs })

            this.debugInfoRow($r('app.string.debug_app_version'), this.viewModel.appVersion)
            this.debugInfoRow($r('app.string.debug_device_info'), this.viewModel.deviceModelInfo)
            this.debugInfoRow($r('app.string.device_alias_label'), this.viewModel.localAlias)
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })

          // 网络接口（多网卡支持）
          Column() {
            Text($r('app.string.network_interfaces_title'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ bottom: DesignTokens.space.xs })

            Repeat(this.viewModel.localInterfaces).each((ri: RepeatItem<NetworkInterface>) => {
              Column() {
                Row() {
                  Text(this.networkTypeLabel(ri.item.type))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_secondary'))
                    .backgroundColor(ri.item.isDefault ? $r('app.color.accent_blue') : $r('app.color.border_light'))
                    .fontColor(ri.item.isDefault ? $r('app.color.text_on_color') : $r('app.color.text_secondary'))
                    .borderRadius(DesignTokens.radius.sm)
                    .padding({
                      left: 8,
                      right: 8,
                      top: 2,
                      bottom: 2
                    })

                  if (ri.item.isDefault) {
                    Text($r('app.string.default_network_badge'))
                      .fontSize(DesignTokens.font.bodyS)
                      .fontColor($r('app.color.success_green'))
                      .margin({ left: DesignTokens.space.xs })
                  }
                }
                .width('100%')
                .margin({ bottom: DesignTokens.space.xs })

                this.debugInfoRow($r('app.string.ip_address_label'), `${ri.item.ip}/${ri.item.prefixLength}`)
              }
              .width('100%')
              .padding(DesignTokens.space.sm)
              .backgroundColor($r('app.color.page_background'))
              .borderRadius(DesignTokens.radius.md)
              .margin({ top: ri.index > 0 ? DesignTokens.space.xs : 0 })
            }).key((item: NetworkInterface) => item.ip)
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })

          // 服务器信息
          Column() {
            Text($r('app.string.settings_network'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ bottom: DesignTokens.space.xs })

            this.debugInfoRow($r('app.string.server_status_label'),
              this.viewModel.serverRunning ? $r('app.string.server_status_running') :
                $r('app.string.server_status_offline'))
            this.debugInfoRow($r('app.string.port_label'), String(this.viewModel.serverPort))
            this.debugInfoRow($r('app.string.encrypted_transfer'), this.viewModel.httpsEnabled ? 'HTTPS' : 'HTTP')
            this.debugInfoRow($r('app.string.protocol_version_label'), this.viewModel.protocolVersion)
            this.debugInfoRow($r('app.string.device_fingerprint_label'), this.viewModel.serverFingerprint)
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })

          // 安全信息
          Column() {
            Text($r('app.string.service_info_title'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })

            Button($r('app.string.reset_certificate_button'))
              .width('90%')
              .height(DesignTokens.hotspot.minSize)
              .backgroundColor($r('app.color.danger_red'))
              .fontColor($r('app.color.text_on_color'))
              .borderRadius(DesignTokens.radius.md)
              .margin({ bottom: DesignTokens.space.sm })
              .onClick(() => {
                // 证书重置需要原生层重新生成 TLS —— 尚未实现
                try {
                  this.getUIContext().getPromptAction().showToast({ message: 'Not yet implemented' });
                } catch (_e) {
                  // 忽略
                }
              })
          }
          .width('100%')
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })
        }
        .padding(DesignTokens.space.md)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  debugInfoRow(label: ResourceStr, value: ResourceStr): void {
    Row() {
      Text(label)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .width('40%')

      Text(value)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  }

  networkTypeLabel(type: NetworkType): ResourceStr {
    if (type === NetworkType.wifi) {
      return $r('app.string.network_type_wifi');
    } else if (type === NetworkType.cellular) {
      return $r('app.string.network_type_cellular');
    } else if (type === NetworkType.ethernet) {
      return $r('app.string.network_type_ethernet');
    }
    return $r('app.string.network_type_unknown');
  }

  pageTransition() {
    PageTransitionEnter(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
    PageTransitionEnter(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }
}
