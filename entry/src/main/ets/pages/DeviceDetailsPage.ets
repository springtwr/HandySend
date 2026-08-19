import { DesignTokens } from '../common/DesignTokens';
import { DeviceDetailsViewModel } from '../viewmodel/DeviceDetailsViewModel';

@Entry
@ComponentV2
struct DeviceDetailsPage {
  @Local viewModel: DeviceDetailsViewModel = new DeviceDetailsViewModel();

  aboutToAppear(): void {
    let params = this.getUIContext().getRouter().getParams() as Record<string, string | number | boolean>;
    if (params !== undefined) {
      const alias: string = params['alias'] as string;
      const ip: string = params['ip'] as string;
      const port: number = params['port'] as number;
      const fingerprint: string = params['fingerprint'] as string;
      const version: string = params['version'] as string;
      const deviceModel: string = params['deviceModel'] as string;
      const deviceType: string = params['deviceType'] as string;
      const protocol: string = params['protocol'] as string;
      this.viewModel.loadDevice(alias, ip, port, fingerprint, version, deviceModel, deviceType, protocol);
    }
  }

  build() {
    Column() {
      // Header
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
          .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.device_details_title'))
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
        Column() {
          // Device info card
          Column() {
            Text(this.viewModel.deviceAlias)
              .fontSize(DesignTokens.font.titleM)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            Row({ space: DesignTokens.space.xs }) {
              Text('#' + this.viewModel.deviceIp.split('.').pop())
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.ip_blue_text'))
                .backgroundColor($r('app.color.accent_blue_bg'))
                .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
                .borderRadius(DesignTokens.radius.sm)

              Text(this.viewModel.deviceModel)
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.ip_blue_text'))
                .backgroundColor($r('app.color.accent_blue_bg'))
                .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
                .borderRadius(DesignTokens.radius.sm)
            }
            .margin({ top: DesignTokens.space.xs })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding(DesignTokens.space.xl)

          // Info details
          Column() {
            this.infoRow($r('app.string.device_alias_label'), this.viewModel.deviceAlias)
            this.infoRow($r('app.string.device_ip_label'), this.viewModel.deviceIp)
            this.infoRow($r('app.string.device_port_label'), this.viewModel.devicePort.toString())
            this.infoRow($r('app.string.device_version_label'), this.viewModel.deviceVersion)
            this.infoRow($r('app.string.device_protocol_label'), this.viewModel.deviceProtocol)
            this.infoRow($r('app.string.device_fingerprint_label'), this.viewModel.deviceFingerprint.substring(0, 20) + '...')
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })
          .margin({ top: DesignTokens.space.md })

          // Action buttons
          Column({ space: DesignTokens.space.sm }) {
            // Verify button
            Button($r('app.string.verify_device_button'))
              .width('100%')
              .height(DesignTokens.hotspot.minSize)
              .backgroundColor($r('app.color.accent_blue'))
              .fontColor($r('app.color.text_on_color'))
              .borderRadius(DesignTokens.radius.lg)
              .onClick(() => {
                this.getUIContext().getRouter().pushUrl({
                  url: 'pages/VerifyPage',
                  params: {
                    localFingerprint: this.viewModel.localFingerprint,
                    remoteFingerprint: this.viewModel.deviceFingerprint
                  }
                });
              })

            // Favorite toggle button
            Button(this.viewModel.isFavoriteDevice ? $r('app.string.remove_favorite_button') : $r('app.string.add_favorite_button'))
              .width('100%')
              .height(DesignTokens.hotspot.minSize)
              .backgroundColor(this.viewModel.isFavoriteDevice ? $r('app.color.danger_red') : $r('app.color.page_background'))
              .fontColor(this.viewModel.isFavoriteDevice ? $r('app.color.text_on_color') : $r('app.color.text_primary'))
              .borderRadius(DesignTokens.radius.lg)
              .border({ width: 1, color: this.viewModel.isFavoriteDevice ? $r('app.color.danger_red') : $r('app.color.border_light') })
              .onClick(() => {
                this.viewModel.toggleFavorite();
              })
          }
          .width('100%')
          .margin({ top: DesignTokens.space.lg })
        }
        .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.xl })
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  infoRow(label: ResourceStr, value: string): void {
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

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
    PageTransitionEnter({ type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }
}
