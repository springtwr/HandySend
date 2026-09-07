import { common } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { curves, SymbolGlyphModifier, CustomContentDialogV2, AdvancedDialogV2Button, promptAction } from '@kit.ArkUI';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { subscribe, unsubscribe, connectByIp, getPort } from '../service/AppService';
import { SendMode, StagedFile, DiscoveredDevice, TransferFileDescriptor } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';
import { SendViewModel } from '../viewmodel/SendViewModel';
import { DeviceItemViewModel } from '../viewmodel/DeviceItemViewModel';
import { DeviceListItem } from '../views/DeviceListItem';
import { isValidIpAddress } from '../utils/IPValidator';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendContent');

@ComponentV2
export struct SendContent {
  @Local viewModel: SendViewModel = new SendViewModel();
  @Local refreshAngle: number = 0
  @Local isRestarting: boolean = false
  @Event onScrollDelta: (deltaY: number, absY: number) => void = (_deltaY: number, _absY: number) => {
  }
  // 页面导航回调（NavBar 首页组件经 UIContext 上抛，由 MainTabFloating 持有 pathStack 执行）
  @Event onNavigateTo: (name: string, param: Object | undefined) => void =
    (_name: string, _param: Object | undefined) => {
    }
  private refreshCallback: () => void = () => {
  }
  private scroller: Scroller = new Scroller()
  // 文本发送弹窗（B 类 CustomContentDialogV2）输入值
  @Local textSendValue: string = ''
  // IP 输入弹窗（B 类 CustomContentDialogV2）输入值与校验状态
  @Local ipInputValue: string = ''
  @Local ipInputValid: boolean = false
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1

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
    this.openTextSendDialog();
  }

  // 刷新旋转使用 springMotion
  refreshDevices(): void {
    // 扫描中不累加旋转角度（刷新旋转由 LoadingProgress 呈现）
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
    // 未暂存文件时提示并中断发送（单目标/多目标两种模式统一拦截）
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
      let params:
      Record<string, Object | string | number | boolean | Array<string> | Array<TransferFileDescriptor>> | undefined =
        this.viewModel.buildSendParams(device);
      if (params !== undefined) {
        this.onNavigateTo('TransferPage', params);
      }
    });
  }

  // 切换发送模式（single ↔ multiple）
  onSendModeChange(mode: string): void {
    this.viewModel.setSendModeValue(mode);
  }

  // 点击"用网页分享"菜单项：未暂存文件时居中提示，否则创建分享链接
  onShareByLink(): void {
    if (this.viewModel.stagedFiles.length === 0) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_select_file_first'), duration: 2000, alignment: Alignment.Center });
      return;
    }
    this.viewModel.shareByLink().then((shareUrl: string) => {
      if (shareUrl.length > 0) {
        let navParam: Record<string, Object> = { 'shareUrl': shareUrl };
        this.onNavigateTo('ShareLinkPage', navParam);
      }
    });
  }

  // 点击"指定IP分享"菜单项：未暂存文件时居中提示，否则弹出IP输入框
  onSendByIp(): void {
    if (this.viewModel.stagedFiles.length === 0) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_select_file_first'), duration: 2000, alignment: Alignment.Center });
      return;
    }
    this.ipInputValue = '';
    this.ipInputValid = false;
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.ipInputDialog();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
      });
  }

  // ── DialogV2 弹窗：文本发送（B 类 CustomContentDialogV2） ──

  private openTextSendDialog(): void {
    this.textSendValue = '';
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.textSendDialog();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
      });
  }

  private closeActiveDialog(): void {
    if (this.activeDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.activeDialogId);
      this.activeDialogId = -1;
    }
  }

  @Builder
  textSendDialog() {
    CustomContentDialogV2({
      primaryTitle: $r('app.string.send_text_input_title'),
      contentBuilder: () => {
        this.textSendContent();
      },
      buttons: [
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_cancel'),
          action: () => {
            this.closeActiveDialog();
          }
        }),
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_confirm'),
          action: () => {
            if (this.textSendValue.trim().length > 0) {
              this.viewModel.stageTextFile(this.textSendValue, 'text_');
            }
            this.closeActiveDialog();
          }
        })
      ]
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  textSendContent() {
    Column({ space: DesignTokens.space.sm }) {
      TextArea({ text: this.textSendValue })
        .height(120)
        .borderRadius(DesignTokens.radius.md)
        .defaultFocus(true)
        .id('send_text_input')
        .onChange((value: string) => {
          this.textSendValue = value;
        })
    }
    .width('100%')
  }

  // ── DialogV2 弹窗：IP 输入（B 类 CustomContentDialogV2，确认按钮随有效性联动） ──

  @Builder
  ipInputDialog() {
    CustomContentDialogV2({
      primaryTitle: $r('app.string.send_mode_ip'),
      contentBuilder: () => {
        this.ipInputContent();
      },
      buttons: [
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_cancel'),
          action: () => {
            this.closeActiveDialog();
          }
        }),
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_confirm'),
          enabled: this.ipInputValid,
          action: () => {
            this.sendToSpecifiedIp(this.ipInputValue);
            this.closeActiveDialog();
          }
        })
      ]
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  ipInputContent() {
    Column({ space: DesignTokens.space.sm }) {
      TextInput({ placeholder: $r('app.string.send_mode_ip_placeholder'), text: this.ipInputValue })
        .borderRadius(DesignTokens.radius.max)
        .defaultFocus(true)
        .id('send_ip_input')
        .onChange((value: string) => {
          this.ipInputValue = value;
          this.ipInputValid = isValidIpAddress(value);
        })
    }
    .width('100%')
  }

  // 指定 IP 分享：connectByIp → 成功走单目标发送流程，失败 Toast 提示
  async sendToSpecifiedIp(ip: string): Promise<void> {
    let result: DiscoveredDevice | undefined = await connectByIp(ip, getPort());
    if (result === undefined) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.send_error_connection'), duration: 2000 });
      return;
    }
    let device: DiscoveredDevice = result;
    // 复用单目标发送流程（与 sendToSelectedDevice 一致）
    this.viewModel.prepareAndChecksumForSend().then((ok: boolean) => {
      if (!ok) {
        logger.warn('prepareAndChecksumForSend failed or no files');
        return;
      }
      let params: Record<string, Object | string | number | boolean | Array<string>> | undefined =
        this.viewModel.buildSendParams(device);
      if (params !== undefined) {
        this.onNavigateTo('TransferPage', params);
      }
    });
  }

  // 发送模式弹出菜单构建器（竖向，选中项尾部显示勾选标记）
  @Builder
  sendModeMenuBuilder() {
    Menu() {
      MenuItem({
        content: $r('app.string.send_mode_single'),
        symbolEndIcon: this.viewModel.sendMode === SendMode.single ?
          new SymbolGlyphModifier($r('sys.symbol.checkmark')) : undefined
      })
        .onClick(() => {
          this.onSendModeChange(SendMode.single);
        })
        .id('send_mode_single_item')

      MenuItem({
        content: $r('app.string.send_mode_multiple'),
        symbolEndIcon: this.viewModel.sendMode === SendMode.multiple ?
          new SymbolGlyphModifier($r('sys.symbol.checkmark')) : undefined
      })
        .onClick(() => {
          this.onSendModeChange(SendMode.multiple);
        })
        .id('send_mode_multiple_item')

      MenuItem({
        content: $r('app.string.send_mode_link')
      })
        .onClick(() => {
          this.onShareByLink();
        })
        .id('send_mode_link_item')

      MenuItem({
        content: $r('app.string.send_mode_ip')
      })
        .onClick(() => {
          this.onSendByIp();
        })
        .id('send_mode_ip_item')
    }
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
              .height(DesignTokens.size.inlineButton)
              .fontColor($r('app.color.text_on_color'))
              .backgroundColor($r('app.color.accent_blue'))
              .borderRadius(DesignTokens.radius.max)
              .onClick(() => {
                this.viewModel.startServer().then(() => {
                }).catch((_e: Error) => {
                  // 启动失败，保持离线
                });
              })
              .id('send_server_start_btn')
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
              .id('send_server_restart_btn')
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

        // 卡片外标题行（左上角左对齐 + 右侧故障排查入口）
        Row() {
          Column() {
            Text($r('app.string.send_select_title'))
              .fontSize(DesignTokens.font.titleS)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // 问号图标响应区域→48vp，点击进入故障排查页
          SymbolGlyph($r('sys.symbol.questionmark_circle'))
            .fontSize(DesignTokens.font.titleM)
            .fontColor([$r('app.color.text_primary')])
            .responseRegion({
              x: -12,
              y: -12,
              width: 48,
              height: 48
            })
            .onClick(() => {
              this.onNavigateTo('TroubleshootPage', undefined);
            })
            .id('send_troubleshoot_entry')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: DesignTokens.space.md })

        // 卡片（标题在外）
        Column() {
          if (this.viewModel.stagedFiles.length === 0) {
            Grid() {
              // 第一行：文件→文档→粘贴→文本
              GridItem() {
                Column() {
                  SymbolGlyph($r('sys.symbol.doc_text_fill'))
                    .fontSize(DesignTokens.font.iconInline)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_file'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: DesignTokens.space.tiny })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .padding({ top: DesignTokens.space.card, bottom: DesignTokens.space.card })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.viewModel.pickFiles();
                })
                .id('send_pick_file')
              }

              GridItem() {
                Column() {
                  SymbolGlyph($r('sys.symbol.doc_plaintext_fill'))
                    .fontSize(DesignTokens.font.iconInline)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_document'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: DesignTokens.space.tiny })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .padding({ top: DesignTokens.space.card, bottom: DesignTokens.space.card })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.viewModel.pickDocuments();
                })
                .id('send_pick_document')
              }

              GridItem() {
                Column() {
                  PasteButton(
                    { icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
                    .width('100%')
                    .height(66)
                    .iconSize(DesignTokens.font.iconInline)
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
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 7, bottom: 7 })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .id('send_paste')
              }

              GridItem() {
                Column() {
                  SymbolGlyph($r('sys.symbol.text_aligncenter'))
                    .fontSize(DesignTokens.font.iconInline)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_justify'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: DesignTokens.space.tiny })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .padding({ top: DesignTokens.space.card, bottom: DesignTokens.space.card })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.pickJustify();
                })
                .id('send_pick_justify')
              }

              // 第二行：图片→视频→音频→压缩包
              GridItem() {
                Column() {
                  SymbolGlyph($r('sys.symbol.picture_fill'))
                    .fontSize(DesignTokens.font.iconInline)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_image'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: DesignTokens.space.tiny })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .padding({ top: DesignTokens.space.card, bottom: DesignTokens.space.card })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.viewModel.pickImages();
                })
                .id('send_pick_image')
              }

              GridItem() {
                Column() {
                  SymbolGlyph($r('sys.symbol.video_fill'))
                    .fontSize(DesignTokens.font.iconInline)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_video'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: DesignTokens.space.tiny })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .padding({ top: DesignTokens.space.card, bottom: DesignTokens.space.card })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.viewModel.pickVideos();
                })
                .id('send_pick_video')
              }

              GridItem() {
                Column() {
                  SymbolGlyph($r('sys.symbol.music_fill'))
                    .fontSize(DesignTokens.font.iconInline)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_audio'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: DesignTokens.space.tiny })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .padding({ top: DesignTokens.space.card, bottom: DesignTokens.space.card })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.viewModel.pickAudio();
                })
                .id('send_pick_audio')
              }

              GridItem() {
                Column() {
                  SymbolGlyph($r('sys.symbol.doc_zipper_fill'))
                    .fontSize(DesignTokens.font.iconInline)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_archive'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: DesignTokens.space.tiny })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .padding({ top: DesignTokens.space.card, bottom: DesignTokens.space.card })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.viewModel.pickArchives();
                })
                .id('send_pick_archive')
              }
            }
            .columnsTemplate('1fr 1fr 1fr 1fr')
            .rowsTemplate('1fr 1fr')
            .columnsGap(DesignTokens.space.inner)
            .rowsGap(DesignTokens.space.inner)
            .width('100%')
            .height(170)
          } else {
            // 操作行（标题在卡片外，这里放文件统计 + 添加/清空）
            Row({ space: DesignTokens.space.sm }) {
              // 已暂存文件统计
              Text($r('app.string.send_file_count_total', this.viewModel.stagedFiles.length,
                this.viewModel.getTotalSizeText()))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)

              Text($r('app.string.send_add_files'))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.accent_blue'))
                .onClick(() => {
                  this.viewModel.pickFiles();
                })
                .id('send_add_files')

              // 清空图标响应区域→48vp
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(DesignTokens.font.iconInline)
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
                .id('send_clear_files')
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .alignItems(VerticalAlign.Center)

            Scroll() {
              Column({ space: DesignTokens.space.inner }) {
                // 已暂存文件 Repeat —— 竖向列表，缩放过渡
                Repeat(this.viewModel.stagedFiles).each((ri: RepeatItem<StagedFile>) => {
                  Row({ space: DesignTokens.space.sm }) {
                    // 文件类型图标
                    if (ri.item.isImage) {
                      SymbolGlyph($r('sys.symbol.picture_fill'))
                        .fontSize(DesignTokens.font.iconInline)
                        .fontColor([$r('app.color.text_primary')])
                    } else if (ri.item.fileType.startsWith('video/')) {
                      SymbolGlyph($r('sys.symbol.video_fill'))
                        .fontSize(DesignTokens.font.iconInline)
                        .fontColor([$r('app.color.text_primary')])
                    } else if (ri.item.fileType.startsWith('audio/')) {
                      SymbolGlyph($r('sys.symbol.music_fill'))
                        .fontSize(DesignTokens.font.iconInline)
                        .fontColor([$r('app.color.text_primary')])
                    } else if (ri.item.fileType.startsWith('text/')) {
                      SymbolGlyph($r('sys.symbol.text_aligncenter'))
                        .fontSize(DesignTokens.font.iconInline)
                        .fontColor([$r('app.color.text_primary')])
                    } else if (this.isArchiveType(ri.item.fileType)) {
                      SymbolGlyph($r('sys.symbol.doc_zipper_fill'))
                        .fontSize(DesignTokens.font.iconInline)
                        .fontColor([$r('app.color.text_primary')])
                    } else {
                      SymbolGlyph($r('sys.symbol.doc_text_fill'))
                        .fontSize(DesignTokens.font.iconInline)
                        .fontColor([$r('app.color.text_primary')])
                    }

                    // 文件名（flex 自适应宽度，单行截断）
                    Text(ri.item.fileName)
                      .fontSize(DesignTokens.font.bodyS)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)

                    // 红底关闭按钮
                    Row() {
                      SymbolGlyph($r('sys.symbol.xmark'))
                        .fontSize(DesignTokens.font.iconXs)
                        .fontColor([$r('app.color.text_on_color')])
                    }
                    .width(DesignTokens.size.iconXs)
                    .height(DesignTokens.size.iconXs)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(VerticalAlign.Center)
                    .backgroundColor($r('app.color.danger_red'))
                    .borderRadius(DesignTokens.radius.max)
                    .responseRegion({
                      x: -12,
                      y: -12,
                      width: 48,
                      height: 48
                    })
                    .onClick(() => {
                      this.viewModel.removeStagedFile(ri.index);
                    })
                    .id('send_staged_file_remove')
                  }
                  .width('100%')
                  .height(44)
                  .alignItems(VerticalAlign.Center)
                  .padding({ left: DesignTokens.space.sm, right: DesignTokens.space.sm })
                  .transition(
                    TransitionEffect.OPACITY
                      .combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
                      .animation({
                        duration: 300,
                        curve: Curve.FastOutSlowIn,
                        delay: ri.index * DesignTokens.animation.listAppearDelay
                      })
                  )
                  .id('send_staged_file_item')
                }).key((item: StagedFile) => item.uri)
              }
            }
            .scrollable(ScrollDirection.Vertical)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .constraintSize({ maxHeight: 130 })
            .width('100%')
            .height('100%')
            .align(Alignment.Top)
            .margin({ top: DesignTokens.space.md })
          }
        }
        .padding(DesignTokens.space.card)
        .constraintSize({ minHeight: DesignTokens.size.cardMinHeight })
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })

        // 卡片外标题行（左上角左对齐 + 右侧模式入口/刷新）
        Row({ space: DesignTokens.space.md }) {
          Column() {
            Text($r('app.string.nearby_devices_title'))
              .fontSize(DesignTokens.font.titleS)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            Text($r('app.string.nearby_devices_subtitle'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: DesignTokens.space.tiny })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // 发送模式入口图标，刷新按钮左侧
          SymbolGlyph(
            this.viewModel.sendMode === SendMode.single ? $r('sys.symbol.person') : $r('sys.symbol.person_2'))
            .fontSize(DesignTokens.font.titleM)
            .fontColor([$r('app.color.text_primary')])
            .responseRegion({
              x: -12,
              y: -12,
              width: 48,
              height: 48
            })
            .bindMenu(this.sendModeMenuBuilder)
            .id('send_mode_entry')

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
              .id('send_refresh_loading')
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(DesignTokens.font.titleM)
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
              .id('send_refresh_btn')
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: DesignTokens.space.lg })
        .justifyContent(FlexAlign.End)

        // 卡片（标题在外）
        Column() {

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
                .margin({ top: DesignTokens.space.tiny })

              Text(this.viewModel.checksumProgress + '/' + this.viewModel.checksumTotal)
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: DesignTokens.space.tiny })
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.md)
            .margin({ top: DesignTokens.space.sm })
          }


          // 附近设备多列栅格 —— GridRow 按窗口宽度断点切换列数（sm/md 单列、lg 2 列、xl 3 列），
          // 高度由内容撑起，可嵌套在页面 Scroll 内（Grid 组件不自适应高度，故不使用 Grid+columnsTemplate）
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
              .id('send_no_devices')
          } else {
            GridRow({
              columns: {
                xs: 1,
                sm: 1,
                md: 1,
                lg: 2,
                xl: 3
              },
              gutter: { x: DesignTokens.space.inner, y: DesignTokens.space.inner },
              breakpoints: {
                value: ['320vp', '600vp', '840vp', '1440vp'],
                reference: BreakpointsReference.WindowSize
              }
            }) {
              Repeat(this.viewModel.deviceItemViewModels).each((ri: RepeatItem<DeviceItemViewModel>) => {
                GridCol() {
                  DeviceListItem({
                    device: ri.item,
                    viewModel: this.viewModel,
                    onSend: (vm: DeviceItemViewModel) => {
                      this.sendToSelectedDevice(vm.item);
                    },
                    onInfo: (vm: DeviceItemViewModel) => {
                      let d = vm.item;
                      let navParam: Record<string, Object> = {
                        'alias': d.alias,
                        'ip': d.ip,
                        'port': d.port,
                        'fingerprint': d.fingerprint,
                        'version': d.version,
                        'deviceModel': d.deviceModel,
                        'deviceType': d.deviceType,
                        'protocol': d.protocol
                      };
                      this.onNavigateTo('DeviceDetailsPage', navParam);
                    }
                  })
                }
              })
              // 键值必须内容化：Repeat 官方语义是"更新前后键值相同，即使数据改变，页面也不会刷新"。
              // 若仅以 fingerprint 作键，对端别名/IP/端口/型号/类型/版本/协议变化后键值不变，条目永不刷新。
              // 将全部影响渲染的字段纳入键值，任一字段变化即键值变化，条目必然按新数据刷新
              // （官方示例同款推荐做法：UI 显示与属性相关时，建议键值生成函数返回属性参与拼接的值）
                .key((item: DeviceItemViewModel) =>
                item.fingerprint + '|' + item.alias + '|' + item.ip + ':' + item.item.port + '|' + item.deviceModel +
                  '|' + item.deviceType + '|' + item.item.version + '|' + item.item.protocol)
            }
            .width('100%')
          }
        }
        .padding(DesignTokens.space.card)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.sm })

        // 收藏区块（标题 + 卡片）：仅存在离线收藏设备时渲染——
        // 在线收藏由附近列表承载展示（条目上的实心爱心即收藏标记），
        // 全部收藏在线或无收藏记录时，整个区块连同标题一起隐藏，避免空置区块
        if (this.viewModel.getFavoriteDevicesForDisplay().length > 0) {
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
            // 收藏设备多列栅格 —— 与附近设备列表同一断点列数配置。
            // 数据源为 ViewModel 过滤后的离线收藏展示数组；条件分支已保证数组非空，无需空态占位文案。
            // 条目复用附近设备列表的 DeviceListItem：isDeviceFavorite 恒真 →
            // 心形实心红、多目标进度条自动生效
            GridRow({
              columns: {
                xs: 1,
                sm: 1,
                md: 1,
                lg: 2,
                xl: 3
              },
              gutter: { x: DesignTokens.space.inner, y: DesignTokens.space.inner },
              breakpoints: {
                value: ['320vp', '600vp', '840vp', '1440vp'],
                reference: BreakpointsReference.WindowSize
              }
            }) {
              Repeat(this.viewModel.getFavoriteDeviceItemViewModels()).each((ri: RepeatItem<DeviceItemViewModel>) => {
                GridCol() {
                  DeviceListItem({
                    device: ri.item,
                    viewModel: this.viewModel,
                    onSend: (vm: DeviceItemViewModel) => {
                      // 点击发送复用现有流程；离线设备允许尝试，失败走既有错误反馈
                      this.sendToSelectedDevice(vm.item);
                    },
                    // 详情导航与附近列表一致；离线设备缺省字段已由合并规则填默认值
                    onInfo: (vm: DeviceItemViewModel) => {
                      let d = vm.item;
                      let navParam: Record<string, Object> = {
                        'alias': d.alias,
                        'ip': d.ip,
                        'port': d.port,
                        'fingerprint': d.fingerprint,
                        'version': d.version,
                        'deviceModel': d.deviceModel,
                        'deviceType': d.deviceType,
                        'protocol': d.protocol
                      };
                      this.onNavigateTo('DeviceDetailsPage', navParam);
                    }
                  })
                }
              })
              // 键值必须内容化（与附近列表同一口径）：Repeat 官方语义是"更新前后键值相同，
              // 即使数据改变，页面也不会刷新"。收藏条目的展示字段来自持久化兜底并会被上线同步更新，
              // 仅以 fingerprint 作键时内容变化不引起键值变化；将影响渲染的字段全部纳入键值，
              // 保证任一字段变化都触发条目按新数据刷新
                .key((item: DeviceItemViewModel) =>
                item.fingerprint + '|' + item.alias + '|' + item.ip + ':' + item.item.port + '|' + item.deviceModel +
                  '|' + item.deviceType + '|' + item.item.version + '|' + item.item.protocol)
            }
            .width('100%')
          }
          .padding(DesignTokens.space.card)
          .borderRadius(DesignTokens.radius.lg)
          .backgroundColor($r('app.color.card_background'))
          .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
          .margin({ top: DesignTokens.space.sm })
        }
      }
      .width('100%')
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
