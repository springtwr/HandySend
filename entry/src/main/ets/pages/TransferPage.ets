import { mediaquery, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { subscribe, unsubscribe } from '../service/AppService';
import { DesignTokens } from '../common/DesignTokens';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { TransferViewModel, TransferPageParams, TransferState } from '../viewmodel/TransferViewModel';
import { MediaFileInfo, GallerySaveResult } from '../model/Types';
import { formatSizeDetailed } from '../utils/FormatUtil';
import { getStringSync } from '../utils/ResourceUtil';
import { TransferDeviceCard } from '../views/TransferDeviceCard';
import { TransferSessionList } from '../views/TransferSessionList';
import { TransferProgressView } from '../views/TransferProgressView';
import { TransferFileList } from '../views/TransferFileList';
import { SaveToGalleryDialog } from '../views/SaveToGalleryDialog';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TransferPage');
const MAX_CONTENT_WIDTH: number = 800;

@ComponentV2
export struct TransferPage {
  @Local viewModel: TransferViewModel = new TransferViewModel();
  @Local private isSm: boolean = true
  // 路由参数（经 TransferPageBuilder 传入，与旧 pushUrl params 结构一致）
  @Param pageParam: Object = {}
  private refreshCallback: () => void = () => {
  }
  private smListener: mediaquery.MediaQueryListener | null = null
  // 相册保存弹窗 id（在 openGalleryDialog 中获取）
  private galleryDialogId: number = -1
  // 上一次 refreshCallback 时弹窗是否可见（用于检测状态变化）
  private prevGalleryDialogVisible: boolean = false
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()

  aboutToAppear(): void {
    let params: TransferPageParams = this.pageParam as TransferPageParams;
    if (params !== undefined) {
      this.viewModel.load(params, this.getUIContext().getHostContext() as common.UIAbilityContext);
    }

    // 自动关闭桥：VM 的完成定时器通过该动作返回导航。
    this.viewModel.dismissAction = () => {
      this.pathStack.pop();
    };

    this.refreshCallback = () => {
      logger.debug('[refreshCallback] fired, transferState=' + this.viewModel.transferState);
      this.viewModel.updateProgress();
      // 检测相册保存弹窗状态变化，打开弹窗
      if (this.viewModel.galleryDialogVisible && !this.prevGalleryDialogVisible) {
        this.prevGalleryDialogVisible = true;
        this.openGalleryDialog();
      } else if (!this.viewModel.galleryDialogVisible && this.prevGalleryDialogVisible) {
        this.prevGalleryDialogVisible = false;
      }
      // 更新发送会话用于多设备展示
      if (this.viewModel.shouldRefreshSessions()) {
        this.getUIContext()
          .animateTo({ duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn }, () => {
            this.viewModel.refreshSessions();
          });
      }
    };
    subscribe(this.refreshCallback);

    if (this.viewModel.isClipboard) {
      this.viewModel.scheduleClipboardAccept();
    }

    this.viewModel.scheduleAutoConfirmIfNeeded();

    this.smListener = this.getUIContext().getMediaQuery().matchMediaSync('(320vp<=width<520vp)');
    this.smListener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isSm = result.matches;
    });
    this.isSm = this.smListener.matches;
  }

  aboutToDisappear(): void {
    logger.debug('[aboutToDisappear] mode=' + (this.viewModel.isSend ? 'send' : 'receive') + ' state=' +
      this.viewModel.transferState + ' dismissed=' + (this.viewModel.isDismissed() ? 'true' : 'false'));
    unsubscribe(this.refreshCallback);
    this.viewModel.unload();
    if (this.smListener !== null) {
      this.smListener.off('change');
    }
  }

  onBackPress(): boolean {
    logger.debug('[onBackPress] intercepted, transferState=' + this.viewModel.transferState);
    // 弹窗可见时先关闭弹窗，不执行返回
    if (this.viewModel.galleryDialogVisible) {
      logger.debug('[onBackPress] gallery dialog visible, dismissing dialog');
      this.viewModel.onGalleryDialogDismiss();
      return true;
    }
    if (this.viewModel.transferState === TransferState.Transferring) {
      logger.debug('[onBackPress] transferring, showing confirm dialog');
      this.getUIContext().showAlertDialog({
        title: $r('app.string.transfer_abort'),
        message: $r('app.string.transfer_abort_confirm'),
        primaryButton: {
          value: $r('app.string.dialog_cancel'),
          action: () => {
          }
        },
        secondaryButton: {
          value: $r('app.string.dialog_confirm'),
          action: () => {
            this.onCancel();
          }
        }
      });
      return true;
    }
    this.onCancel();
    return true;
  }
  private onCancel(): void {
    // 弹窗可见时先关闭弹窗
    if (this.viewModel.galleryDialogVisible) {
      this.viewModel.onGalleryDialogDismiss();
    }
    this.viewModel.onCancel();
    this.pathStack.pop();
  }

  private dismissAndBack(): void {
    this.viewModel.markDismissed();
    this.pathStack.pop();
  }

  private copyTextToClipboard(text: string): void {
    if (this.viewModel.copyTextToClipboard(text)) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copy_success'), duration: 2000 });
    }
  }

  private buildMediaCountText(): string {
    let imageCount: number = 0;
    let videoCount: number = 0;
    let files: Array<MediaFileInfo> = this.viewModel.pendingMediaFiles;
    for (let i = 0; i < files.length; i++) {
      if (files[i].isImage) {
        imageCount = imageCount + 1;
      } else {
        videoCount = videoCount + 1;
      }
    }
    if (imageCount > 0 && videoCount > 0) {
      return getStringSync(this.getUIContext(), $r('app.string.gallery_save_media_count'))
        .replace('%d', String(imageCount)).replace('%d', String(videoCount));
    } else if (imageCount > 0) {
      return getStringSync(this.getUIContext(), $r('app.string.gallery_save_image_count'))
        .replace('%d', String(imageCount));
    } else if (videoCount > 0) {
      return getStringSync(this.getUIContext(), $r('app.string.gallery_save_video_count'))
        .replace('%d', String(videoCount));
    }
    return '';
  }

  private getContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private openGalleryDialog(): void {
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.saveToGalleryDialog();
      },
      autoCancel: true,
      alignment: DialogAlignment.Center
    };
    this.getUIContext().getPromptAction().openCustomDialog(dialogOptions).then((id: number) => {
      this.galleryDialogId = id;
    }).catch(() => {
    });
  }

  @Builder
  saveToGalleryDialog() {
    SaveToGalleryDialog({
      mediaFiles: this.viewModel.pendingMediaFiles,
      mediaCountText: this.buildMediaCountText(),
      onPerformSave: (mediaFiles: Array<MediaFileInfo>) => {
        return this.viewModel.performGallerySave(mediaFiles);
      },
      onSaveComplete: (result: GallerySaveResult) => {
        this.viewModel.onGallerySaveComplete(result);
        this.showGallerySaveResultToast(result);
      },
      onDismiss: () => {
        this.viewModel.onGalleryDialogDismiss();
      },
      onCloseDialog: () => {
        this.closeGalleryDialog();
      }
    })
  }

  private closeGalleryDialog(): void {
    if (this.galleryDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.galleryDialogId);
      this.galleryDialogId = -1;
    }
  }

  private showGallerySaveResultToast(result: GallerySaveResult): void {
    let message: string = '';
    if (result.failCount === 0 && result.successCount > 0) {
      message = getStringSync(this.getUIContext(), $r('app.string.gallery_save_success'));
    } else if (result.successCount === 0) {
      message = getStringSync(this.getUIContext(), $r('app.string.gallery_save_failed'));
    } else {
      let partial: string = getStringSync(this.getUIContext(), $r('app.string.gallery_save_partial'));
      message = partial.replace('%d', String(result.successCount)).replace('%d',
        String(result.successCount + result.failCount));
    }
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  getIpLastPart(ip: string): string {
    let parts: Array<string> = ip.split('.');
    if (parts.length > 0) {
      return parts[parts.length - 1];
    }
    return '0';
  }

  isUrl(text: string): boolean {
    return /^https?:\/\/\S+/.test(text.trim());
  }

  @Builder
  clipboardView(): void {
    Column() {
      Text($r('app.string.clipboard_from_device', this.viewModel.sourceAlias))
        .fontSize(DesignTokens.font.subtitleM)
        .fontColor($r('app.color.clipboard_text'))
        .margin({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })

      Column() {
        Text(this.viewModel.textMessageContent)
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .lineHeight(20)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .maxLines(12)
          .width('100%')
      }
      .width('88%')
      .padding(DesignTokens.space.md)
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })

      if (this.isUrl(this.viewModel.textMessageContent)) {
        Row({ space: DesignTokens.space.md }) {
          Button() {
             Row({ space: DesignTokens.space.tiny }) {
               Text($r('app.string.open_link'))
                .fontSize(DesignTokens.font.subtitleM)
                .fontColor($r('app.color.text_on_color'))
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(DesignTokens.size.thumbSm)
          .backgroundColor($r('app.color.accent_blue'))
          .borderRadius(DesignTokens.radius.max)
          .onClick(() => {
            this.viewModel.openUrl(this.viewModel.textMessageContent.trim());
          })

           Button() {
             Row({ space: DesignTokens.space.tiny }) {
               Text($r('app.string.copy'))
                 .fontSize(DesignTokens.font.subtitleM)
                 .fontColor($r('app.color.text_on_color'))
             }
             .justifyContent(FlexAlign.Center)
           }
           .layoutWeight(1)
           .height(DesignTokens.size.thumbSm)
           .backgroundColor($r('app.color.accent_blue'))
           .borderRadius(DesignTokens.radius.max)
           .onClick(() => {
             this.copyTextToClipboard(this.viewModel.textMessageContent);
             this.dismissAndBack();
           })
         }
         .width('100%')
         .justifyContent(FlexAlign.Center)
         .margin({ top: DesignTokens.space.lg })

         Button() {
           Text($r('app.string.close'))
             .fontSize(DesignTokens.font.subtitleM)
             .fontColor($r('app.color.text_secondary'))
         }
         .width('60%')
         .height(DesignTokens.size.thumbSm)
         .backgroundColor($r('app.color.card_background'))
         .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_medium'), style: BorderStyle.Solid })
         .borderRadius(DesignTokens.radius.max)
        .margin({ top: DesignTokens.space.md })
        .onClick(() => {
          this.dismissAndBack();
        })
      } else {
         Row({ space: DesignTokens.space.md }) {
           Button() {
             Row({ space: DesignTokens.space.tiny }) {
               Text($r('app.string.close'))
                 .fontSize(DesignTokens.font.subtitleM)
                 .fontColor($r('app.color.text_secondary'))
             }
             .justifyContent(FlexAlign.Center)
           }
           .layoutWeight(1)
           .height(DesignTokens.size.thumbSm)
           .backgroundColor($r('app.color.card_background'))
           .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_medium'), style: BorderStyle.Solid })
           .borderRadius(DesignTokens.radius.max)
           .onClick(() => {
             this.dismissAndBack();
           })

           Button() {
             Row({ space: DesignTokens.space.tiny }) {
               Text($r('app.string.copy'))
                 .fontSize(DesignTokens.font.subtitleM)
                 .fontColor($r('app.color.text_on_color'))
             }
             .justifyContent(FlexAlign.Center)
           }
           .layoutWeight(1)
           .height(DesignTokens.size.thumbSm)
           .backgroundColor($r('app.color.accent_blue'))
           .borderRadius(DesignTokens.radius.max)
           .onClick(() => {
             this.copyTextToClipboard(this.viewModel.textMessageContent);
             this.dismissAndBack();
           })
         }
         .width('100%')
         .justifyContent(FlexAlign.Center)
         .margin({ top: DesignTokens.space.lg })
       }
     }
     .width('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  textSendView(): void {
    Column() {
      TransferDeviceCard({
        alias: this.viewModel.sourceAlias,
        ip: this.viewModel.sourceIp,
        deviceType: this.viewModel.sourceDeviceType,
        deviceModel: this.viewModel.sourceDeviceModel
      })

      Column() {
        SymbolGlyph($r('sys.symbol.arrow_down'))
          .fontSize(DesignTokens.font.titleM)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })

      TransferDeviceCard({
        alias: this.viewModel.targetAlias,
        ip: this.viewModel.targetIp,
        deviceType: this.viewModel.targetDeviceType,
        deviceModel: this.viewModel.targetDeviceModel
      })

      Column() {
        Text($r('app.string.transfer_file_count', this.viewModel.fileCount))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_tertiary'))
        if (this.viewModel.totalSize > 0) {
          Text(formatSizeDetailed(this.viewModel.totalSize))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: DesignTokens.space.mini })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: DesignTokens.space.md })

      if (this.viewModel.transferState === TransferState.Transferring) {
               LoadingProgress()
                 .width(DesignTokens.size.iconMd)
                 .height(DesignTokens.size.iconMd)
          .color($r('app.color.accent_blue'))
          .margin({ top: DesignTokens.space.lg })
        Text($r('app.string.sending'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: DesignTokens.space.sm })
      } else if (this.viewModel.transferState === TransferState.Failed) {
        if (this.viewModel.errorMessage.length > 0) {
          Text(this.viewModel.errorMessage)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.danger_red'))
            .margin({ top: DesignTokens.space.lg })
            .textAlign(TextAlign.Center)
            .width('80%')
        } else {
          Text($r('app.string.send_failed_prefix'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.danger_red'))
            .margin({ top: DesignTokens.space.lg })
            .textAlign(TextAlign.Center)
            .width('80%')
        }
        Button() {
          Text($r('app.string.back'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontColor($r('app.color.text_on_color'))
        }
        .width('60%')
        .height(DesignTokens.size.thumbSm)
        .backgroundColor($r('app.color.accent_blue'))
        .borderRadius(DesignTokens.radius.max)
        .margin({ top: DesignTokens.space.lg })
        .onClick(() => {
          this.dismissAndBack();
        })
      } else {
        Text($r('app.string.sent'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.success_green'))
          .margin({ top: DesignTokens.space.lg })
        Button() {
          Text($r('app.string.back'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontColor($r('app.color.text_on_color'))
        }
        .width('60%')
        .height(DesignTokens.size.thumbSm)
        .backgroundColor($r('app.color.accent_blue'))
        .borderRadius(DesignTokens.radius.max)
        .margin({ top: DesignTokens.space.lg })
        .onClick(() => {
          this.dismissAndBack();
        })
      }
    }
    .width('100%')
  }

  build() {
    NavDestination() {
      Column() {
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
              this.onCancel();
            })

        Text($r('app.string.transfer_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)

        // 验证按钮——携带本地 + 远端指纹跳转到 VerifyPage（实心强调蓝，浅色模式下对比清晰）
        if (this.viewModel.targetFingerprint.length > 0) {
          Text($r('app.string.verify_button'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_on_color'))
            .fontWeight(FontWeight.Medium)
            .padding({
              left: DesignTokens.space.sm,
              right: DesignTokens.space.sm,
              top: DesignTokens.space.tiny,
              bottom: DesignTokens.space.tiny
            })
            .borderRadius(DesignTokens.radius.max)
            .backgroundColor($r('app.color.accent_blue'))
            .onClick(() => {
              let localFp: string = this.viewModel.getServerFingerprintValue();
              this.pathStack.pushPathByName('VerifyPage', {
                localFingerprint: localFp,
                remoteFingerprint: this.viewModel.targetFingerprint
              });
            })
        }
      }
      .width('100%')
      .height(DesignTokens.size.headerHeight)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      if (this.viewModel.isClipboard) {
        Scroll() {
          Row() {
            Column() {
              this.clipboardView()
            }
            .width(this.isSm ? '100%' : MAX_CONTENT_WIDTH)
            .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      } else if (this.viewModel.isTextSend) {
        Scroll() {
          Row() {
            Column() {
              this.textSendView()
            }
            .width(this.isSm ? '100%' : MAX_CONTENT_WIDTH)
            .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      } else {
        // 文件传输：方向 + 对端设备卡固定顶部，文件列表撑满剩余空间，操作按钮置底。
        Row() {
          Column() {
            // 方向说明：接收时对端=发送方（来自），发送时对端=接收方（发送到）。
            if (this.viewModel.isSend) {
              Text($r('app.string.transfer_direction_to', this.viewModel.targetAlias))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ bottom: DesignTokens.space.tiny })
            } else {
              Text($r('app.string.transfer_direction_from', this.viewModel.sourceAlias))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ bottom: DesignTokens.space.tiny })
            }

            // 对端设备卡：只展示对端（接收=发送方，发送=接收方）。
            if (this.viewModel.isSend) {
              TransferDeviceCard({
                alias: this.viewModel.targetAlias,
                ip: this.viewModel.targetIp,
                deviceType: this.viewModel.targetDeviceType,
                deviceModel: this.viewModel.targetDeviceModel
              })
            } else {
              TransferDeviceCard({
                alias: this.viewModel.sourceAlias,
                ip: this.viewModel.sourceIp,
                deviceType: this.viewModel.sourceDeviceType,
                deviceModel: this.viewModel.sourceDeviceModel
              })
            }

            // ── 多设备会话列表（边缘路径） ──
            if (this.viewModel.isSend && this.viewModel.currentSendMode === 'multiple' &&
              this.viewModel.sendSessions.length > 0) {
              Column() {
                Text($r('app.string.multi_device_sessions'))
                  .fontSize(DesignTokens.font.bodyM)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                  .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.tiny })

                TransferSessionList({ viewModel: this.viewModel })
              }
              .width('100%')
            }

            // 文件清单（逐文件独立进度条）——撑满剩余空间
            TransferFileList({ viewModel: this.viewModel })
              .layoutWeight(1)
              .width('100%')
              .margin({ top: DesignTokens.space.sm })

            // 完成/失败/文本状态
            if (this.viewModel.transferState !== TransferState.Idle) {
              TransferProgressView({
                viewModel: this.viewModel,
                onBack: () => {
                  this.dismissAndBack();
                },
                onCopy: (text: string) => {
                  this.copyTextToClipboard(text);
                }
              })
              .width('100%')
              .margin({ top: DesignTokens.space.sm })
            }

            // ── 底部操作按钮（置底） ──
            if (this.viewModel.transferState === TransferState.Idle && !this.viewModel.isSend) {
              Row({ space: DesignTokens.space.md }) {
                Button() {
                  Row({ space: DesignTokens.space.tiny }) {
                    SymbolGlyph($r('sys.symbol.xmark'))
                      .fontSize(DesignTokens.font.subtitleL)
                      .fontColor([$r('app.color.danger_red')])
                    Text($r('app.string.transfer_cancel'))
                      .fontSize(DesignTokens.font.subtitleM)
                      .fontColor($r('app.color.danger_red'))
                  }
                  .justifyContent(FlexAlign.Center)
                }
                .layoutWeight(1)
                .height(DesignTokens.size.thumbSm)
                .backgroundColor($r('app.color.card_background'))
                .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.danger_red'), style: BorderStyle.Solid })
                .borderRadius(DesignTokens.radius.max)
                .onClick(() => {
                  this.onCancel();
                })

                Button() {
                  Row({ space: DesignTokens.space.tiny }) {
                    SymbolGlyph($r('sys.symbol.checkmark'))
                      .fontSize(DesignTokens.font.subtitleL)
                      .fontColor([$r('app.color.text_on_color')])
                    Text($r('app.string.transfer_confirm'))
                      .fontSize(DesignTokens.font.subtitleM)
                      .fontColor($r('app.color.text_on_color'))
                  }
                  .justifyContent(FlexAlign.Center)
                }
                .layoutWeight(1)
                .height(DesignTokens.size.thumbSm)
                .backgroundColor($r('app.color.accent_blue'))
                .borderRadius(DesignTokens.radius.max)
                .onClick(() => {
                  this.viewModel.onConfirm();
                })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .margin({ top: DesignTokens.space.tiny })
            } else if (this.viewModel.transferState === TransferState.Transferring) {
              Button() {
                Row({ space: DesignTokens.space.tiny }) {
                  SymbolGlyph($r('sys.symbol.xmark'))
                    .fontSize(DesignTokens.font.subtitleL)
                    .fontColor([$r('app.color.text_on_color')])
                  Text($r('app.string.transfer_abort'))
                    .fontSize(DesignTokens.font.subtitleM)
                    .fontColor($r('app.color.text_on_color'))
                }
                .justifyContent(FlexAlign.Center)
              }
              .width('60%')
              .height(DesignTokens.size.thumbSm)
              .backgroundColor($r('app.color.danger_red'))
              .borderRadius(DesignTokens.radius.max)
              .margin({ top: DesignTokens.space.tiny })
              .onClick(() => {
                this.getUIContext().showAlertDialog({
                  title: $r('app.string.transfer_abort'),
                  message: $r('app.string.transfer_abort_confirm'),
                  primaryButton: {
                    value: $r('app.string.dialog_cancel'),
                    action: () => {
                    }
                  },
                  secondaryButton: {
                    value: $r('app.string.dialog_confirm'),
                    action: () => {
                      this.onCancel();
                    }
                  }
                });
              })
            } else {
              Button() {
                Text($r('app.string.back'))
                  .fontSize(DesignTokens.font.subtitleM)
                  .fontColor($r('app.color.text_on_color'))
              }
              .width('60%')
              .height(DesignTokens.size.thumbSm)
              .backgroundColor($r('app.color.accent_blue'))
              .borderRadius(DesignTokens.radius.max)
              .margin({ top: DesignTokens.space.tiny })
              .onClick(() => {
                this.dismissAndBack();
              })
            }
          }
          .width(this.isSm ? '100%' : MAX_CONTENT_WIDTH)
          .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.tiny })
          .height('100%')
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      return this.onBackPress();
    })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}

// 路由表引用：TransferPageBuilder(name, param)
@Builder
export function TransferPageBuilder(name: string, param: Object) {
  TransferPage({ pageParam: param })
}
