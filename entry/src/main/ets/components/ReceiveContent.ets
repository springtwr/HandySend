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
              .height(DesignTokens.size.inlineButton)
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
          .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.warning_orange') })
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
               .width(DesignTokens.font.iconInline)
               .height(DesignTokens.font.iconInline)
               .color($r('app.color.accent_blue'))
             }
             Button($r('app.string.restart_server'))
               .fontSize(DesignTokens.font.bodyS)
               .height(DesignTokens.size.inlineButton)
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
          .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.warning_orange') })
          .margin({ top: DesignTokens.space.md })
        }

        // 网络警告横幅（服务器运行中时显示）
        // 没有网络连接优先级高于接口关闭
        if (this.viewModel.noWifiWarning && this.viewModel.serverReady) {
          Row({ space: DesignTokens.space.tiny }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor([$r('app.color.warning_orange')])
            Text($r('app.string.no_wifi_warning'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.warning_orange'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .borderRadius(DesignTokens.radius.lg)
          .backgroundColor($r('app.color.warning_bg'))
          .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.warning_orange') })
          .margin({ top: DesignTokens.space.md })
        } else if (this.viewModel.allInterfacesDisabled && this.viewModel.serverReady) {
          Row({ space: DesignTokens.space.tiny }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor([$r('app.color.warning_orange')])
            Text($r('app.string.all_interfaces_disabled_warning'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.warning_orange'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .borderRadius(DesignTokens.radius.lg)
          .backgroundColor($r('app.color.warning_bg'))
          .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.warning_orange') })
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
          .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.danger_red') })
          .margin({ top: DesignTokens.space.sm })
        }

        // ── 主设备展示：大号名称与状态 ──
        // 卡片外标题（左上角左对齐）
        Column() {
          Text($r('app.string.receive_device_title'))
            .fontSize(DesignTokens.font.titleS)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: DesignTokens.space.lg })

        // 卡片（标题在外）
        Column() {
          // 带旋转动画的 Logo
          Column() {
            Image($r('app.media.startIcon'))
              .width(DesignTokens.size.thumbMd)
              .height(DesignTokens.size.thumbMd)
              .rotate({ angle: this.viewModel.enableAnimations && this.viewModel.serverOnline ? this.logoRotation : 0 })
          }
          .margin({ bottom: DesignTokens.space.md })

          // 设备大别名（主展示）
          Text(this.viewModel.localDeviceInfo.alias)
            .fontSize(DesignTokens.font.titleM)
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
                  left: DesignTokens.space.xxs,
                  right: DesignTokens.space.xxs,
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
                left: DesignTokens.space.tiny,
                right: DesignTokens.space.tiny,
                top: DesignTokens.space.mini,
                bottom: DesignTokens.space.mini
              })
              .borderRadius(DesignTokens.radius.sm)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: DesignTokens.space.tiny })

          // 信息面板切换按钮
          Row() {
            Text($r('app.string.info_label'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor(this.showInfoPanel ? $r('app.color.text_on_color') : $r('app.color.accent_blue'))
              .padding({
                left: DesignTokens.space.sm,
                right: DesignTokens.space.sm,
                 top: DesignTokens.space.tiny,
                 bottom: DesignTokens.space.tiny
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
        .padding(DesignTokens.space.card)
        .constraintSize({ minHeight: DesignTokens.size.cardMinHeight })
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })

        // ── 信息面板（可动画展开） ──
        if (this.showInfoPanel) {
          // 卡片外标题（左上角左对齐）
          Column() {
            Text($r('app.string.receive_details_title'))
              .fontSize(DesignTokens.font.titleS)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .margin({ top: DesignTokens.space.lg })

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
            .padding({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })
            .constraintSize({ minHeight: DesignTokens.size.thumbSm })

            // IP 行——每个网卡一行
            Repeat(this.viewModel.localDeviceInfo.interfaces).each((ri: RepeatItem<NetworkInterface>) => {
              Row() {
                Row({ space: DesignTokens.space.tiny }) {
                  Text($r('app.string.device_ip_label'))
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor($r('app.color.text_secondary'))
                  Text(this.networkTypeLabel(ri.item.type))
                    .fontSize(DesignTokens.font.captionM)
                    .fontColor(ri.item.isDefault ? $r('app.color.text_on_color') : $r('app.color.text_secondary'))
                    .backgroundColor(ri.item.isDefault ? $r('app.color.accent_blue') : $r('app.color.border_light'))
                     .padding({
                       left: DesignTokens.space.tiny,
                       right: DesignTokens.space.tiny,
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
              .padding({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })
              .constraintSize({ minHeight: DesignTokens.size.thumbSm })
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
            .padding({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })
            .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          }
          .padding(DesignTokens.space.md)
          .borderRadius(DesignTokens.radius.lg)
          .backgroundColor($r('app.color.card_background'))
          .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
          .margin({ top: DesignTokens.space.sm })
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.BOTTOM))
            .animation({ duration: 300, curve: Curve.FastOutSlowIn }))
        }

        // ── 统一卡片内的底部操作按钮 ──
        // 卡片外标题（左上角左对齐）
        Column() {
          Text($r('app.string.receive_more_title'))
            .fontSize(DesignTokens.font.titleS)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: DesignTokens.space.lg })

        // 卡片（标题在外）
        Column() {
          // 通过链接接收
          Row({ space: DesignTokens.space.sm }) {
            SymbolGlyph($r('sys.symbol.link'))
              .fontSize(DesignTokens.font.iconInline)
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
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
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
              .fontSize(DesignTokens.font.iconInline)
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
          .constraintSize({ minHeight: DesignTokens.size.thumbSm })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/ReceiveHistoryPage' });
          })
        }
        .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.size.tabBarClearance })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
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
