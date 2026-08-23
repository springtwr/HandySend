import { curves } from '@kit.ArkUI';
import { subscribe, unsubscribe } from '../service/AppService';
import { NetworkInterface, NetworkType } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';
import { ReceiveViewModel } from '../viewmodel/ReceiveViewModel';

@ComponentV2
export struct ReceiveContent {
  @Local viewModel: ReceiveViewModel = new ReceiveViewModel();
  @Local showInfoPanel: boolean = false
  @Local logoRotation: number = 0
  @Local isRestarting: boolean = false
  @Event onScrollDelta: (deltaY: number, absY: number) => void = (_deltaY: number, _absY: number) => {
  }
  private refreshCallback: () => void = () => {
  }
  private animationTimer: number = -1
  private scroller: Scroller = new Scroller()

  aboutToAppear(): void {
    this.refreshCallback = () => {
      this.viewModel.refresh();
    };
    subscribe(this.refreshCallback);

    this.viewModel.subscribeFavorites();
    this.viewModel.load();

    // 启动 Logo 旋转动画
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
        // V2 刷新机制下，归零操作不会立即同步到渲染层，
        // 需要用 animateToImmediately 强制刷新，否则下一轮 animateTo
        // 检测不到属性变化，动画不会执行。
        this.logoRotation = this.logoRotation - 360;
        this.getUIContext().animateToImmediately({ duration: 0 }, () => {
        });
        this.runLogoRotation();
      }
    }, () => {
      this.logoRotation = this.logoRotation + 360;
    });
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // 服务器离线警告横幅
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
                  // 启动失败，保持离线
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

        // 服务器重启警告横幅
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

        // 服务器错误消息（例如端口被占用）
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

        // ── 主设备展示：大号名称与状态 ──
        Column() {
          // 带旋转动画的 Logo
          Column() {
            Image($r('app.media.startIcon'))
              .width(80)
              .height(80)
              .rotate({ angle: this.viewModel.enableAnimations && this.viewModel.serverOnline ? this.logoRotation : 0 })
          }
          .margin({ bottom: DesignTokens.space.md })

          // 设备大别名（主展示）
          Text(this.viewModel.localDeviceInfo.alias)
            .fontSize(DesignTokens.font.titleL)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)

          // 设备信息行——横向排列：在线状态 / IP 短码 / 协议
          Row({ space: DesignTokens.space.md }) {
            Text(this.viewModel.serverOnline ? $r('app.string.online_status') : $r('app.string.offline_status'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor(this.viewModel.serverOnline ? $r('app.color.success_green') : $r('app.color.text_secondary'))

            // 显示所有网卡IP（简短形式）
            Repeat(this.viewModel.localDeviceInfo.interfaces).each((ri: RepeatItem<NetworkInterface>) => {
              Text(this.getIpShortCode(ri.item.ip))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor(ri.item.isDefault ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                .backgroundColor(ri.item.isDefault ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
                .padding(ri.item.isDefault ? {
                  left: 4,
                  right: 4,
                  top: 2,
                  bottom: 2
                } : 0)
                .borderRadius(DesignTokens.radius.sm)
            }).key((item: NetworkInterface) => item.ip)

            Text(this.viewModel.encryptedTransfer ? $r('app.string.protocol_https') : $r('app.string.protocol_http'))
              .fontSize(DesignTokens.font.captionM)
              .fontColor(
                this.viewModel.encryptedTransfer ? $r('app.color.success_green') : $r('app.color.warning_orange'))
              .backgroundColor(
                this.viewModel.encryptedTransfer ? $r('app.color.success_bg') : $r('app.color.warning_bg'))
              .padding({
                left: DesignTokens.space.xs,
                right: DesignTokens.space.xs,
                top: DesignTokens.space.mini,
                bottom: DesignTokens.space.mini
              })
              .borderRadius(DesignTokens.radius.sm)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: DesignTokens.space.xs })

          // WiFi 警告横幅 / 所有接口已关闭横幅
          // 没有网络连接优先级高于接口关闭
          if (this.viewModel.noWifiWarning && this.viewModel.serverOnline) {
            Row({ space: DesignTokens.space.xs }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor([$r('app.color.warning_orange')])
              Text($r('app.string.no_wifi_warning'))
                .fontSize(DesignTokens.font.captionM)
                .fontColor($r('app.color.warning_orange'))
                .layoutWeight(1)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({
              left: DesignTokens.space.md,
              right: DesignTokens.space.md,
              top: DesignTokens.space.xs,
              bottom: DesignTokens.space.xs
            })
            .backgroundColor($r('app.color.warning_bg'))
            .borderRadius(DesignTokens.radius.sm)
            .margin({ top: DesignTokens.space.sm })
          } else if (this.viewModel.allInterfacesDisabled && this.viewModel.serverOnline) {
            Row({ space: DesignTokens.space.xs }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor([$r('app.color.warning_orange')])
              Text($r('app.string.all_interfaces_disabled_warning'))
                .fontSize(DesignTokens.font.captionM)
                .fontColor($r('app.color.warning_orange'))
                .layoutWeight(1)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({
              left: DesignTokens.space.md,
              right: DesignTokens.space.md,
              top: DesignTokens.space.xs,
              bottom: DesignTokens.space.xs
            })
            .backgroundColor($r('app.color.warning_bg'))
            .borderRadius(DesignTokens.radius.sm)
            .margin({ top: DesignTokens.space.sm })
          }

          // 信息面板切换按钮
          Row() {
            Text($r('app.string.info_label'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor(this.showInfoPanel ? $r('app.color.text_on_color') : $r('app.color.accent_blue'))
              .padding({
                left: DesignTokens.space.sm,
                right: DesignTokens.space.sm,
                top: 6,
                bottom: 6
              })
              .backgroundColor(this.showInfoPanel ? $r('app.color.accent_blue') : $r('app.color.accent_blue_bg'))
              .borderRadius(DesignTokens.radius.lg)
              .accessibilityText($r('app.string.info_label'))
              .accessibilityDescription($r('app.string.info_label'))
              .responseRegion({
                x: -8,
                y: -8,
                width: 48,
                height: 48
              })
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

        // ── 信息面板（可动画展开） ──
        if (this.showInfoPanel) {
          Column() {
            // 型号行
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

            // IP 行——每个网卡一行
            Repeat(this.viewModel.localDeviceInfo.interfaces).each((ri: RepeatItem<NetworkInterface>) => {
              Row() {
                Row({ space: DesignTokens.space.xs }) {
                  Text($r('app.string.device_ip_label'))
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor($r('app.color.text_secondary'))
                  Text(this.networkTypeLabel(ri.item.type))
                    .fontSize(DesignTokens.font.captionM)
                    .fontColor(ri.item.isDefault ? $r('app.color.text_on_color') : $r('app.color.text_secondary'))
                    .backgroundColor(ri.item.isDefault ? $r('app.color.accent_blue') : $r('app.color.border_light'))
                    .padding({
                      left: 6,
                      right: 6,
                      top: 2,
                      bottom: 2
                    })
                    .borderRadius(DesignTokens.radius.sm)
                  if (ri.item.isDefault) {
                    Text($r('app.string.default_network_badge'))
                      .fontSize(DesignTokens.font.captionM)
                      .fontColor($r('app.color.success_green'))
                  }
                }

                Text(ri.item.ip)
                  .fontSize(DesignTokens.font.bodyM)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .padding({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
              .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            }).key((item: NetworkInterface) => item.ip)

            // 端口行
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
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.BOTTOM))
            .animation({ duration: 300, curve: Curve.FastOutSlowIn }))
        }

        // ── 统一卡片内的底部操作按钮 ──
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
                this.getUIContext().getRouter().pushUrl({ url: 'pages/ShareLinkPage', params: { mode: 'receive' } });
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
      .justifyContent(FlexAlign.Start)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onDidScroll((_xOffset: number, yOffset: number) => {
      let offset = this.scroller.currentOffset();
      this.onScrollDelta(yOffset, offset.yOffset);
    })
    .onScrollEdge((edge: Edge) => {
      if (edge === Edge.Top) {
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
