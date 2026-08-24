import { common } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { curves } from '@kit.ArkUI';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { subscribe, unsubscribe } from '../service/AppService';
import { SendMode, StagedFile, DiscoveredDevice } from '../model/Types';
import { DialogService } from '../service/DialogService';
import { DesignTokens } from '../common/DesignTokens';
import { SendModeSelector } from './SendModeSelector';
import { SendViewModel } from '../viewmodel/SendViewModel';
import { DeviceListItem } from '../views/DeviceListItem';
import { FavoriteDeviceItem } from '../views/FavoriteDeviceItem';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendContent');

@ComponentV2
export struct SendContent {
  @Local viewModel: SendViewModel = new SendViewModel();
  @Local refreshAngle: number = 0
  @Local isRestarting: boolean = false
  @Event onScrollDelta: (deltaY: number, absY: number) => void = (_deltaY: number, _absY: number) => {
  }
  private refreshCallback: () => void = () => {
  }
  private scroller: Scroller = new Scroller()

  aboutToAppear(): void {
    this.viewModel.init(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.viewModel.subscribeFavorites();
    this.refreshCallback = () => {
      this.viewModel.refresh();
    };
    subscribe(this.refreshCallback);
    this.viewModel.refresh();
  }

  aboutToDisappear(): void {
    unsubscribe(this.refreshCallback);
    this.viewModel.unsubscribeFavorites();
  }

  handlePasteData(text: string): void {
    try {
      if (!this.viewModel.handlePasteData(text)) {
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.send_clipboard_empty'), duration: 2000 });
        return;
      }
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_clipboard_pasted'), duration: 2000 });
    } catch (e) {
      logger.error('handlePasteData error: ' + JSON.stringify(e));
    }
  }

  pickJustify(): void {
    DialogService.showTextSendDialog((text: string) => {
      if (text.trim().length === 0) {
        return;
      }
      this.viewModel.stageTextFile(text, 'text_');
    });
  }

  // 刷新旋转使用 springMotion
  refreshDevices(): void {
    // 扫描中不累加旋转角度（图标已被 LoadingProgress 转圈替代）
    if (!this.viewModel.isScanning) {
      this.getUIContext()
        .animateTo({
          duration: 800,
          curve: curves.springMotion(DesignTokens.animation.springStiffness, DesignTokens.animation.springDamping)
        }, () => {
          this.refreshAngle = this.refreshAngle + 360;
        });
    }
    // 点击始终触发刷新：扫描进行中会合并排队（最多补扫一次）
    if (this.viewModel.serverReady) {
      this.viewModel.rescanDevices();
    }
  }

  sendToSelectedDevice(device: DiscoveredDevice): void {
    // 未暂存文件时提示并中止发送（单目标/多目标两种模式统一拦截）
    if (this.viewModel.stagedFiles.length === 0) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_select_file_first'), duration: 2000, alignment: Alignment.Center });
      return;
    }
    // #15：多目标发送模式——内联发送，不跳转 TransferPage
    if (this.viewModel.sendMode === 'multiple') {
      this.viewModel.sendToMultipleDeviceInline(device);
      return;
    }
    // 单目标模式：先准备文件 + 计算校验和（进度条在主页面显示），再导航
    this.viewModel.prepareAndChecksumForSend().then((ok: boolean) => {
      if (!ok) {
        logger.warn('prepareAndChecksumForSend failed or no files');
        return;
      }
      let params: Record<string, Object | string | number | boolean | Array<string>> | undefined =
        this.viewModel.buildSendParams(device);
      if (params !== undefined) {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/TransferPage', params: params });
      }
    });
  }

  onSendModeChange(mode: string): void {
    let previousMode: string = this.viewModel.sendMode;
    this.viewModel.setSendModeValue(mode);
    if (mode === SendMode.link) {
      // shareByLink 处理：已暂存文件 → 创建链接；无文件 → 选择文件 → 创建链接；取消 → 回退
      this.viewModel.shareByLink(previousMode).then((shareUrl: string) => {
        if (shareUrl.length > 0) {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/ShareLinkPage', params: { shareUrl: shareUrl } });
        }
      });
    }
  }

  // 收藏设备 = 在线设备中已收藏的（从接收页迁移，放在附近设备下方）
  getFavoriteDevices(): Array<DiscoveredDevice> {
    let result: Array<DiscoveredDevice> = [];
    for (let i = 0; i < this.viewModel.discoveredDevices.length; i++) {
      let device = this.viewModel.discoveredDevices[i];
      for (let j = 0; j < this.viewModel.favoriteDevices.length; j++) {
        if (device.fingerprint === this.viewModel.favoriteDevices[j].fingerprint) {
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
                this.viewModel.startServer().then(() => {
                }).catch((_e: Error) => {
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

        // 网络警告横幅（服务器运行中时显示）
        // 没有网络连接优先级高于接口关闭
        if (this.viewModel.noWifiWarning && this.viewModel.serverReady) {
          Row({ space: DesignTokens.space.xs }) {
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
          .border({ width: 1, color: $r('app.color.warning_orange') })
          .margin({ top: DesignTokens.space.md })
        } else if (this.viewModel.allInterfacesDisabled && this.viewModel.serverReady) {
          Row({ space: DesignTokens.space.xs }) {
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
          .border({ width: 1, color: $r('app.color.warning_orange') })
          .margin({ top: DesignTokens.space.md })
        }

        // 卡片外标题（左上角左对齐）
        Column() {
          Text($r('app.string.send_select_title'))
            .fontSize(DesignTokens.font.titleS)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))

          if (this.viewModel.stagedFiles.length === 0) {
            Text($r('app.string.send_select_subtitle'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 6 })
          } else {
            Text($r('app.string.send_file_count_total', this.viewModel.stagedFiles.length,
              this.viewModel.getTotalSizeText()))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 6 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: DesignTokens.space.lg })

        // 卡片（标题在外）
        Column() {
          if (this.viewModel.stagedFiles.length === 0) {
            Scroll() {
              Row({ space: 10 }) {
                Column() {
                  SymbolGlyph($r('sys.symbol.doc_text_fill'))
                    .fontSize(20)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_file'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 20, bottom: 20 })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.viewModel.pickFiles();
                })

                Column() {
                  SymbolGlyph($r('sys.symbol.picture_fill'))
                    .fontSize(20)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_image'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 20, bottom: 20 })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.viewModel.pickImages();
                })

                Column() {
                  PasteButton(
                    { icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
                    .width(66)
                    .height(66)
                    .iconSize(20)
                    .fontSize(DesignTokens.font.bodyS)
                    .borderRadius(DesignTokens.radius.md)
                    .backgroundColor($r('app.color.page_background'))
                    .iconColor($r('app.color.clipboard_button_icon'))
                    .fontColor($r('app.color.clipboard_button_icon'))
                    .layoutDirection(SecurityComponentLayoutDirection.VERTICAL)
                    .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
                      if (PasteButtonOnClickResult.SUCCESS === result) {
                        let systemPasteboard = pasteboard.getSystemPasteboard();
                        systemPasteboard.getData().then((pasteData: pasteboard.PasteData) => {
                          this.handlePasteData(pasteData.getPrimaryText());
                        }).catch((err: BusinessError) => {
                          logger.error('Paste error: ' + err.message);
                          this.getUIContext()
                            .getPromptAction()
                            .showToast({ message: $r('app.string.clipboard_read_failed'), duration: 2000 });
                        });
                      }
                    })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 7, bottom: 7 })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))

                Column() {
                  SymbolGlyph($r('sys.symbol.text_aligncenter'))
                    .fontSize(20)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_justify'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 20, bottom: 20 })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.pickJustify();
                })

                Column() {
                  SymbolGlyph($r('sys.symbol.music_fill'))
                    .fontSize(20)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_audio'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 20, bottom: 20 })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.viewModel.pickAudio();
                })
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .edgeEffect(this.viewModel.enableAnimations ? EdgeEffect.Spring : EdgeEffect.None)
            .width('100%')
          } else {
            // 操作行（标题已在卡片外，这里只放添加/清空）
            Row({ space: DesignTokens.space.sm }) {
              Blank()

              Text($r('app.string.send_add_files'))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.accent_blue'))
                .onClick(() => {
                  this.viewModel.pickFiles();
                })

              // 清空图标响应区域→48vp
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(20)
                .fontColor([$r('app.color.text_tertiary')])
                .responseRegion({
                  x: -14,
                  y: -14,
                  width: 48,
                  height: 48
                })
                .onClick(() => {
                  this.viewModel.clearStagedFiles();
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .alignItems(VerticalAlign.Center)

            Scroll() {
              Row({ space: 10 }) {
                // 已暂存文件 Repeat —— 缩放过渡
                Repeat(this.viewModel.stagedFiles).each((ri: RepeatItem<StagedFile>) => {
                  Stack({ alignContent: Alignment.TopEnd }) {
                    Column() {
                      if (ri.item.isImage) {
                        Image(ri.item.uri)
                          .width(48)
                          .height(48)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(DesignTokens.radius.md)
                      } else if (ri.item.fileType.startsWith('audio/')) {
                        SymbolGlyph($r('sys.symbol.music_fill'))
                          .fontSize(48)
                          .fontColor([$r('app.color.text_primary')])
                      } else if (ri.item.previewPixelMap !== undefined) {
                        // 视频缩略图（异步懒加载生成）
                        Image(ri.item.previewPixelMap)
                          .width(48)
                          .height(48)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(DesignTokens.radius.md)
                      } else if (ri.item.fileType.startsWith('video/')) {
                        SymbolGlyph($r('sys.symbol.video_fill'))
                          .fontSize(48)
                          .fontColor([$r('app.color.text_primary')])
                      } else if (ri.item.fileType.startsWith('text/')) {
                        SymbolGlyph($r('sys.symbol.text_aligncenter'))
                          .fontSize(48)
                          .fontColor([$r('app.color.text_primary')])
                      } else if (this.isArchiveType(ri.item.fileType)) {
                        SymbolGlyph($r('sys.symbol.doc_zipper_fill'))
                          .fontSize(48)
                          .fontColor([$r('app.color.text_primary')])
                      } else {
                        SymbolGlyph($r('sys.symbol.doc_text_fill'))
                          .fontSize(48)
                          .fontColor([$r('app.color.text_primary')])
                      }
                      Text(ri.item.fileName)
                        .fontSize(DesignTokens.font.captionM)
                        .fontColor($r('app.color.text_tertiary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width(64)
                        .textAlign(TextAlign.Center)
                        .margin({ top: 4 })
                    }
                    .width(64)
                    .height(80)
                    .alignItems(HorizontalAlign.Center)
                    .padding(4)

                    // 红底关闭按钮
                    Row() {
                      SymbolGlyph($r('sys.symbol.xmark'))
                        .fontSize(DesignTokens.font.bodyM)
                        .fontColor([$r('app.color.text_on_color')])
                    }
                    .width(16)
                    .height(16)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(VerticalAlign.Center)
                    .backgroundColor($r('app.color.danger_red'))
                    .borderRadius(DesignTokens.radius.md)
                    .onClick(() => {
                      this.viewModel.removeStagedFile(ri.index);
                    })
                  }
                  .width(64)
                  .height(80)
                  .transition(
                    TransitionEffect.OPACITY
                      .combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
                      .animation({
                        duration: 300,
                        curve: Curve.FastOutSlowIn,
                        delay: ri.index * DesignTokens.animation.listAppearDelay
                      })
                  )
                  // 行出现时懒加载视频缩略图（fire-and-forget，内部已捕获异常）
                  .onAppear(() => {
                    this.viewModel.loadVideoPreview(ri.index);
                  })
                // key 含缩略图就绪标记：生成完成后 key 变化，Repeat 重建该项显示缩略图
                // （同 key 下仅替换对象引用不会被 Repeat 识别为数据更新）
                }).key((item: StagedFile) => item.uri + (item.previewPixelMap !== undefined ? '#thumb' : ''))
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .width('100%')
            .margin({ top: DesignTokens.space.md })
          }
        }
        .padding(20)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })

        // 卡片外标题行（左上角左对齐 + 右侧刷新）
        Row() {
          Column() {
            Text($r('app.string.nearby_devices_title'))
              .fontSize(DesignTokens.font.titleS)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            Text($r('app.string.nearby_devices_subtitle'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 6 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // 刷新图标响应区域→48vp；扫描中显示 LoadingProgress 转圈（点击仍有效，合并排队）
          if (this.viewModel.isScanning) {
            LoadingProgress()
              .width(24)
              .height(24)
              .color($r('app.color.accent_blue'))
              .responseRegion({
                x: -12,
                y: -12,
                width: 48,
                height: 48
              })
              .onClick(() => {
                this.refreshDevices();
              })
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(24)
              .fontColor([$r('app.color.text_primary')])
              .rotate({ angle: this.refreshAngle })
              .responseRegion({
                x: -12,
                y: -12,
                width: 48,
                height: 48
              })
              .onClick(() => {
                this.refreshDevices();
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: DesignTokens.space.lg })

        // 卡片（标题在外）
        Column() {
          if (this.viewModel.stagedFiles.length > 0) {
            Row() {
              SendModeSelector({
                currentMode: this.viewModel.sendMode,
                onModeChange: (mode: string) => {
                  this.onSendModeChange(mode);
                }
              })
            }
            .width('100%')
            .margin({ bottom: DesignTokens.space.md })
          }

          if (this.viewModel.checksumTotal > 0 && this.viewModel.checksumProgress < this.viewModel.checksumTotal) {
            Column() {
              Text($r('app.string.calculating_checksum'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))

              Progress({
                value: this.viewModel.checksumProgress,
                total: this.viewModel.checksumTotal,
                type: ProgressType.Linear
              })
                .width('100%')
                .color($r('app.color.accent_blue'))
                .margin({ top: DesignTokens.space.xs })

              Text(this.viewModel.checksumProgress + '/' + this.viewModel.checksumTotal)
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: DesignTokens.space.xs })
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.md)
            .margin({ top: DesignTokens.space.sm })
          }


          // 附近设备 Repeat —— 平移过渡
          Column({ space: 10 }) {
            if (this.viewModel.discoveredDevices.length === 0) {
              Text($r('app.string.no_devices_found'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_secondary'))
                .margin({
                  top: DesignTokens.space.md,
                  bottom: DesignTokens.space.md
                })
                .width('100%')
                .textAlign(TextAlign.Center)
            }
            Repeat(this.viewModel.discoveredDevices).each((ri: RepeatItem<DiscoveredDevice>) => {
              DeviceListItem({
                device: ri.item,
                viewModel: this.viewModel,
                onSend: (d: DiscoveredDevice) => {
                  this.sendToSelectedDevice(d);
                },
                onInfo: (d: DiscoveredDevice) => {
                  this.getUIContext().getRouter().pushUrl({
                    url: 'pages/DeviceDetailsPage',
                    params: {
                      alias: d.alias,
                      ip: d.ip,
                      port: d.port,
                      fingerprint: d.fingerprint,
                      version: d.version,
                      deviceModel: d.deviceModel,
                      deviceType: d.deviceType,
                      protocol: d.protocol
                    }
                  });
                }
              })
            }).key((item: DiscoveredDevice) => item.fingerprint)
          }
          .width('100%')
        }
        .padding(20)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })

        // 卡片外标题（左上角左对齐）
        Column() {
          Text($r('app.string.favorite_devices_title'))
            .fontSize(DesignTokens.font.titleS)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: DesignTokens.space.lg })

        // 卡片（标题在外）
        Column() {
          Column({ space: 10 }) {
            if (this.getFavoriteDevices().length === 0) {
              Text($r('app.string.no_favorite_devices'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_secondary'))
                .margin({
                  top: DesignTokens.space.md,
                  bottom: DesignTokens.space.md
                })
                .width('100%')
                .textAlign(TextAlign.Center)
            }
            // 收藏设备 Repeat —— 过渡动效
            Repeat(this.getFavoriteDevices()).each((ri: RepeatItem<DiscoveredDevice>) => {
              FavoriteDeviceItem({
                device: ri.item,
                onRemove: (fingerprint: string) => {
                  this.viewModel.removeFavorite(fingerprint);
                }
              })
            }).key((item: DiscoveredDevice) => item.fingerprint)
          }
          .width('100%')
        }
        .padding(20)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })

        Row() {
          Text($r('app.string.troubleshoot_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.accent_blue'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: DesignTokens.space.md, bottom: DesignTokens.space.md })
        .onClick(() => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/TroubleshootPage' });
        })
      }
      .width('100%')
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: 80 })
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

  // 判断压缩包类型（用于文件卡片图标分流）
  private isArchiveType(fileType: string): boolean {
    return fileType === 'application/zip' ||
      fileType === 'application/vnd.rar' ||
      fileType === 'application/x-rar-compressed' ||
      fileType === 'application/x-7z-compressed' ||
      fileType === 'application/x-tar' ||
      fileType === 'application/gzip' ||
      fileType === 'application/x-bzip2' ||
      fileType === 'application/x-xz';
  }
}
