import { curves } from '@kit.ArkUI';
import { getLocalDeviceInfo, getDiscoveredDevices, subscribe, unsubscribe,
  isServerRunning, startServer, restartServer, getDeviceModel, startWebUpload, getShareLink } from '../service/AppService';
import { DiscoveredDevice, LocalDeviceInfo, FavoriteDevice, NetworkInterface, NetworkType } from '../model/Types';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { removeFavorite, getFavorites } from '../service/FavoritesService';
import { DesignTokens } from '../common/DesignTokens';

@Component
export struct ReceiveContent {
  @State localDeviceInfo: LocalDeviceInfo = { alias: '', fingerprint: '', ip: '0.0.0.0', interfaces: [] }
  @State refreshTick: number = 0
  @StorageLink('autoSaveMode') autoSaveMode: string = 'paired'
  @StorageLink('favoriteDevices') favoriteDevicesJson: string = '[]'
  @StorageLink('encryptedTransfer') encryptedTransfer: boolean = true
  @StorageLink('enableAnimations') enableAnimations: boolean = true
  @StorageLink('port') serverPort: number = 53317
  @StorageLink('serverReady') serverReady: boolean = false
  @StorageLink('serverError') serverError: string = ''
  @StorageLink('noWifiWarning') noWifiWarning: boolean = false
  @StorageLink('serverNeedsRestart') serverNeedsRestart: boolean = false
  @State serverOnline: boolean = false
  @State showInfoPanel: boolean = false
  @State logoRotation: number = 0
  @State isRestarting: boolean = false
  onScrollDelta?: (deltaY: number, absY: number) => void
  private refreshCallback: () => void = () => {}
  private animationTimer: number = -1
  private scroller: Scroller = new Scroller()

  aboutToAppear(): void {
    this.refreshCallback = () => {
      this.refreshTick = this.refreshTick + 1;
      this.serverOnline = isServerRunning();
      this.localDeviceInfo = getLocalDeviceInfo();
    };
    subscribe(this.refreshCallback);

    this.localDeviceInfo = getLocalDeviceInfo();
    if (this.localDeviceInfo.alias === '') {
      this.localDeviceInfo.alias = '便捷快传';
    }
    this.serverOnline = isServerRunning();

    let savedMode: string = preferencesUtil.getString('autoSaveMode', 'paired');
    if (savedMode === 'off' || savedMode === 'paired' || savedMode === 'on') {
      this.autoSaveMode = savedMode;
    }

    // Start logo rotation animation
    this.startLogoAnimation();
  }

  aboutToDisappear(): void {
    unsubscribe(this.refreshCallback);
    if (this.animationTimer >= 0) {
      clearTimeout(this.animationTimer);
      this.animationTimer = -1;
    }
  }

  private startLogoAnimation(): void {
    this.runLogoRotation();
  }

  private runLogoRotation(): void {
    if (!this.enableAnimations || !this.serverOnline) {
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
    // Parse from @StorageLink so changes trigger re-render
    try {
      let parsed: Object = JSON.parse(this.favoriteDevicesJson);
      if (Array.isArray(parsed)) {
        return parsed as Array<FavoriteDevice>;
      }
    } catch (_e) {
      // fallback
    }
    return getFavorites();
  }

  getFavoriteDiscoveredDevices(): Array<DiscoveredDevice> {
    let devices: Array<DiscoveredDevice> = getDiscoveredDevices();
    let favs: Array<FavoriteDevice> = this.getFavoriteDevices();
    let result: Array<DiscoveredDevice> = [];
    for (let i = 0; i < devices.length; i++) {
      let device = devices[i];
      for (let j = 0; j < favs.length; j++) {
        if (device.fingerprint === favs[j].fingerprint) {
          result.push(device);
          break;
        }
      }
    }
    return result;
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // Server offline warning banner
        if (!this.serverReady) {
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
                startServer().catch((_e: Error) => {
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
        if (this.serverNeedsRestart) {
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
                restartServer().then(() => {
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
        if (this.serverError.length > 0) {
          Row() {
            Text(this.serverError)
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
              .rotate({ angle: this.enableAnimations && this.serverOnline ? this.logoRotation : 0 })
          }
          .margin({ bottom: DesignTokens.space.md })

          // Large device alias (primary display)
          Text(this.localDeviceInfo.alias)
            .fontSize(DesignTokens.font.titleL)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)

          // Device info row — horizontal: online status / IP short code / protocol
          Row({ space: DesignTokens.space.md }) {
            Text(this.serverOnline ? $r('app.string.online_status') : $r('app.string.offline_status'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor(this.serverOnline ? $r('app.color.success_green') : $r('app.color.text_secondary'))

            // 显示所有网卡IP（简短形式）
            ForEach(this.localDeviceInfo.interfaces, (iface: NetworkInterface, index: number) => {
              Text(this.getIpShortCode(iface.ip))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor(iface.isDefault ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                .backgroundColor(iface.isDefault ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
                .padding(iface.isDefault ? { left: 4, right: 4, top: 2, bottom: 2 } : 0)
                .borderRadius(DesignTokens.radius.sm)
            }, (iface: NetworkInterface) => iface.ip)

            Text(this.encryptedTransfer ? $r('app.string.protocol_https') : $r('app.string.protocol_http'))
              .fontSize(DesignTokens.font.captionM)
              .fontColor(this.encryptedTransfer ? $r('app.color.success_green') : $r('app.color.warning_orange'))
              .backgroundColor(this.encryptedTransfer ? $r('app.color.success_bg') : $r('app.color.warning_bg'))
              .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
              .borderRadius(DesignTokens.radius.sm)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: DesignTokens.space.xs })

          // WiFi warning banner
          if (this.noWifiWarning && this.serverOnline) {
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
              Text(getDeviceModel())
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })

            // IP rows — one per interface
            ForEach(this.localDeviceInfo.interfaces, (iface: NetworkInterface) => {
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
              Text(String(this.serverPort))
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
            ForEach(this.getFavoriteDiscoveredDevices(), (device: DiscoveredDevice, index: number) => {
              Row({ space: DesignTokens.space.sm }) {
                if (device.deviceType === 'mobile') {
                  Image($r('app.media.ic_public_devices_phone'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'desktop') {
                  Image($r('app.media.ic_device_matebook'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'web') {
                  Image($r('app.media.ic_browser'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'headless') {
                  Image($r('app.media.ic_terminal'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'server') {
                  Image($r('app.media.ic_server'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'tablet') {
                  Image($r('app.media.ic_device_pad'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else {
                  Image($r('app.media.ic_public_devices_phone'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                }

                Column() {
                  Text(device.alias)
                    .fontSize(DesignTokens.font.subtitleM)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))

                  Row({ space: DesignTokens.space.xs }) {
                    Text('#' + device.ip.split('.').pop())
                      .fontSize(DesignTokens.font.bodyS)
                      .fontColor($r('app.color.ip_blue_text'))
                      .backgroundColor($r('app.color.accent_blue_bg'))
                      .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
                      .borderRadius(DesignTokens.radius.sm)

                    Text(device.deviceModel)
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

                // T027: Heart icon responseRegion→48vp
                SymbolGlyph($r('sys.symbol.heart_fill'))
                  .fontSize(22)
                  .fontColor([$r('app.color.danger_red')])
                  .responseRegion({ x: -13, y: -13, width: 48, height: 48 })
                  .onClick(() => {
                    removeFavorite(device.fingerprint);
                    // @StorageLink auto-syncs via notifyChange()
                  })
              }
              .width('100%')
              .padding(DesignTokens.space.md)
              .backgroundColor($r('app.color.page_background'))
              .borderRadius(DesignTokens.radius.md)
              .alignItems(VerticalAlign.Center)
              .transition(
                TransitionEffect.OPACITY
                  .combine(TransitionEffect.translate({ x: 40 }))
                  .animation({ duration: 300, curve: Curve.FastOutSlowIn, delay: index * DesignTokens.animation.listAppearDelay })
              )
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
            startWebUpload().then(() => {
              if (getShareLink().length > 0) {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/ShareLinkPage' });
              }
            }).catch((_e: Error) => {
              // Web upload start failed
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
