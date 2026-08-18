import { curves } from '@kit.ArkUI';
import { subscribe, unsubscribe } from '../service/AppService';
import { DiscoveredDevice, FavoriteDevice, NetworkInterface, NetworkType } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';
import { ReceiveViewModel } from '../viewmodel/ReceiveViewModel';
import { FavoriteDeviceItem } from '../views/FavoriteDeviceItem';

@Component
export struct ReceiveContent {
  @State viewModel: ReceiveViewModel = new ReceiveViewModel();
  @State showInfoPanel: boolean = false
  @State logoRotation: number = 0
  @State isRestarting: boolean = false
  onScrollDelta?: (deltaY: number, absY: number) => void
  private refreshCallback: () => void = () => {}
  private animationTimer: number = -1
  private scroller: Scroller = new Scroller()

  aboutToAppear(): void {
    this.refreshCallback = () => {
      this.viewModel.refresh();
    };
    subscribe(this.refreshCallback);

    this.viewModel.subscribeFavorites();
    this.viewModel.load();

    // Start logo rotation animation
    this.startLogoAnimation();
  }

  aboutToDisappear(): void {
    unsubscribe(this.refreshCallback);
    this.viewModel.unsubscribeFavorites();
    if (this.animationTimer >= 0) {
      clearTimeout(this.animationTimer);
      this.animationTimer = -1;
    }
  }

  private startLogoAnimation(): void {
    this.runLogoRotation();
  }

  private runLogoRotation(): void {
    if (!this.viewModel.enableAnimations || !this.viewModel.serverOnline) {
      this.animationTimer = setTimeout(() => {
        this.runLogoRotation();
      }, 500) as number;
      return;
    }
    this.getUIContext().animateTo({
      duration: 3000,
      iterations: 1,
      curve: curves.springMotion(DesignTokens.animation.springStiffness, DesignTokens.animation.springDamping),
      onFinish: () => {
        this.logoRotation = this.logoRotation - 360;
        this.runLogoRotation();
      }
    }, () => {
      this.logoRotation = this.logoRotation + 360;
    });
  }

  getFavoriteDevices(): Array<FavoriteDevice> {
    // Read the VM's favorites snapshot so changes trigger re-render
    return this.viewModel.favoriteDevices;
  }

  getFavoriteDiscoveredDevices(): Array<DiscoveredDevice> {
    let devices: Array<DiscoveredDevice> = this.viewModel.getDiscoveredDevicesValue();
    let favs: Array<FavoriteDevice> = this.getFavoriteDevices();
    return this.viewModel.filterFavorites(devices, favs);
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // Server offline warning banner
        if (!this.viewModel.serverReady) {
          Row() {
            Text($r('app.string.server_offline_warning'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.warning_orange'))
              .layoutWeight(1)

            Button($r('app.string.start_server'))
              .fontSize(DesignTokens.font.bodyS)
              .height(28)
              .fontColor($r('app.color.text_on_color'))
              .backgroundColor($r('app.color.accent_blue'))
              .borderRadius(DesignTokens.radius.max)
              .onClick(() => {
                this.viewModel.startServer().catch((_e: Error) => {
                  // Start failed, stay offline
                });
              })
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.warning_bg'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.warning_orange') })
          .margin({ top: DesignTokens.space.md })
        }

        // Server restart warning banner
        if (this.viewModel.serverNeedsRestart) {
          Row() {
            Text($r('app.string.server_needs_restart'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.warning_orange'))
              .layoutWeight(1)

            if (this.isRestarting) {
              LoadingProgress()
                .width(20)
                .height(20)
                .color($r('app.color.accent_blue'))
            }
            Button($r('app.string.restart_server'))
              .fontSize(DesignTokens.font.bodyS)
              .height(28)
              .fontColor($r('app.color.text_on_color'))
              .backgroundColor($r('app.color.accent_blue'))
              .borderRadius(DesignTokens.radius.max)
              .enabled(!this.isRestarting)
              .onClick(() => {
                this.isRestarting = true;
                this.viewModel.restartServer().then(() => {
                  this.isRestarting = false;
                }).catch(() => {
                  this.isRestarting = false;
                });
              })
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .borderRadius(DesignTokens.radius.lg)
          .backgroundColor($r('app.color.warning_bg'))
          .border({ width: 1, color: $r('app.color.warning_orange') })
          .margin({ top: DesignTokens.space.md })
        }

        // Server error message (e.g. port in use)
        if (this.viewModel.serverError.length > 0) {
          Row() {
            Text(this.viewModel.serverError)
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.danger_red'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.danger_bg'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.danger_red') })
          .margin({ top: DesignTokens.space.xs })
        }

        // ── Main device display with large name and status ──
        Column() {
          // Logo with rotation animation
          Column() {
            Image($r('app.media.startIcon'))
              .width(80)
              .height(80)
              .rotate({ angle: this.viewModel.enableAnimations && this.viewModel.serverOnline ? this.logoRotation : 0 })
          }
          .margin({ bottom: DesignTokens.space.md })

          // Large device alias (primary display)
          Text(this.viewModel.localDeviceInfo.alias)
            .fontSize(DesignTokens.font.titleL)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)

          // Device info row — horizontal: online status / IP short code / protocol
          Row({ space: DesignTokens.space.md }) {
            Text(this.viewModel.serverOnline ? $r('app.string.online_status') : $r('app.string.offline_status'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor(this.viewModel.serverOnline ? $r('app.color.success_green') : $r('app.color.text_secondary'))

            // 显示所有网卡IP（简短形式）
            ForEach(this.viewModel.localDeviceInfo.interfaces, (iface: NetworkInterface, index: number) => {
              Text(this.getIpShortCode(iface.ip))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor(iface.isDefault ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                .backgroundColor(iface.isDefault ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
                .padding(iface.isDefault ? { left: 4, right: 4, top: 2, bottom: 2 } : 0)
                .borderRadius(DesignTokens.radius.sm)
            }, (iface: NetworkInterface) => iface.ip)

            Text(this.viewModel.encryptedTransfer ? $r('app.string.protocol_https') : $r('app.string.protocol_http'))
              .fontSize(DesignTokens.font.captionM)
              .fontColor(this.viewModel.encryptedTransfer ? $r('app.color.success_green') : $r('app.color.warning_orange'))
              .backgroundColor(this.viewModel.encryptedTransfer ? $r('app.color.success_bg') : $r('app.color.warning_bg'))
              .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
              .borderRadius(DesignTokens.radius.sm)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: DesignTokens.space.xs })

          // WiFi warning banner
          if (this.viewModel.noWifiWarning && this.viewModel.serverOnline) {
            Row({ space: DesignTokens.space.xs }) {
              Text('\u26A0')
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.warning_orange'))
              Text($r('app.string.no_wifi_warning'))
                .fontSize(DesignTokens.font.captionM)
                .fontColor($r('app.color.warning_orange'))
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
            .backgroundColor($r('app.color.warning_bg'))
            .borderRadius(DesignTokens.radius.sm)
            .margin({ top: DesignTokens.space.sm })
          }

          // Info panel toggle button
          Row() {
            Text($r('app.string.info_label'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor(this.showInfoPanel ? $r('app.color.text_on_color') : $r('app.color.accent_blue'))
              .padding({ left: DesignTokens.space.sm, right: DesignTokens.space.sm, top: 6, bottom: 6 })
              .backgroundColor(this.showInfoPanel ? $r('app.color.accent_blue') : $r('app.color.accent_blue_bg'))
              .borderRadius(DesignTokens.radius.lg)
              .accessibilityText($r('app.string.info_label'))
              .accessibilityDescription($r('app.string.info_label'))
              .responseRegion({ x: -8, y: -8, width: 48, height: 48 })
              .onClick(() => {
                this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
                  this.showInfoPanel = !this.showInfoPanel;
                });
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: DesignTokens.space.sm })
        }
        .padding(20)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.lg })

        // ── Info panel (expandable with animation) ──
        if (this.showInfoPanel) {
          Column() {
            // Model row
            Row() {
              Text($r('app.string.input_model_title'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_secondary'))
                .width('40%')
              Text(this.viewModel.getDeviceModelValue())
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })

            // IP rows — one per interface
            ForEach(this.viewModel.localDeviceInfo.interfaces, (iface: NetworkInterface) => {
              Row() {
                Row({ space: DesignTokens.space.xs }) {
                  Text($r('app.string.device_ip_label'))
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor($r('app.color.text_secondary'))
                  Text(this.networkTypeLabel(iface.type))
                    .fontSize(DesignTokens.font.captionM)
                    .fontColor(iface.isDefault ? $r('app.color.text_on_color') : $r('app.color.text_secondary'))
                    .backgroundColor(iface.isDefault ? $r('app.color.accent_blue') : $r('app.color.border_light'))
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(DesignTokens.radius.sm)
                  if (iface.isDefault) {
                    Text($r('app.string.default_network_badge'))
                      .fontSize(DesignTokens.font.captionM)
                      .fontColor($r('app.color.success_green'))
                  }
                }

                Text(iface.ip)
                  .fontSize(DesignTokens.font.bodyM)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
              .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            }, (iface: NetworkInterface) => iface.ip)

            // Port row
            Row() {
              Text($r('app.string.device_port_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_secondary'))
                .width('40%')
              Text(String(this.viewModel.serverPort))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          }
          .padding(DesignTokens.space.md)
          .borderRadius(DesignTokens.radius.lg)
          .backgroundColor($r('app.color.card_background'))
          .border({ width: 1, color: $r('app.color.border_light') })
          .margin({ top: DesignTokens.space.sm })
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.BOTTOM)).animation({ duration: 300, curve: Curve.FastOutSlowIn }))
        }

        // ── Favorite devices section ──
        Column() {
          Text($r('app.string.favorite_devices_title'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))

          Column({ space: 10 }) {
            if (this.getFavoriteDiscoveredDevices().length === 0) {
              Text($r('app.string.no_favorite_devices'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: DesignTokens.space.md })
                .width('100%')
                .textAlign(TextAlign.Center)
            }
            // T061: Favorite devices ForEach — transition动效
            ForEach(this.getFavoriteDiscoveredDevices(), (device: DiscoveredDevice) => {
                FavoriteDeviceItem({
                  device: device,
                  onRemove: (fingerprint: string) => {
                    this.viewModel.removeFavorite(fingerprint);
                  }
                })
              }, (device: DiscoveredDevice) => device.fingerprint)
          }
          .width('100%')
          .margin({ top: DesignTokens.space.sm })
        }
        .padding(20)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.md })

        // ── Bottom action buttons in unified card ──
        Column() {
          // 通过链接接收
          Row({ space: DesignTokens.space.sm }) {
            SymbolGlyph($r('sys.symbol.link'))
              .fontSize(20)
              .fontColor([$r('app.color.accent_blue')])

            Text($r('app.string.link_share_button'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Text('›')
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.viewModel.startWebUploadFlow().then((linkReady: boolean) => {
              if (linkReady) {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/ShareLinkPage' });
              }
            });
          })

          Divider().color($r('app.color.border_light'))

          // 历史
          Row({ space: DesignTokens.space.sm }) {
            SymbolGlyph($r('sys.symbol.arrow_counterclockwise_clock'))
              .fontSize(20)
              .fontColor([$r('app.color.accent_blue')])

            Text($r('app.string.receive_history_button'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Text('›')
              .fontSize(DesignTokens.font.subtitleL)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/ReceiveHistoryPage' });
          })
        }
        .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.md, bottom: 80 })
      }
      .width('100%')
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onDidScroll((_xOffset: number, yOffset: number) => {
      if (this.onScrollDelta !== undefined) {
        let offset = this.scroller.currentOffset();
        this.onScrollDelta(yOffset, offset.yOffset);
      }
    })
    .onScrollEdge((edge: Edge) => {
      if (edge === Edge.Top && this.onScrollDelta !== undefined) {
        this.onScrollDelta(-999, 0);
      }
    })
  }

  getIpShortCode(ip: string): string {
    let parts: Array<string> = ip.split('.');
    let last: string = parts.length > 0 ? parts[parts.length - 1] : '0';
    return '#' + last;
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
}
