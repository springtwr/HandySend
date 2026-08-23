import { mediaquery } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { subscribe, unsubscribe } from '../service/AppService';
import { DesignTokens } from '../common/DesignTokens';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { TransferViewModel, TransferPageParams, TransferState } from '../viewmodel/TransferViewModel';
import { SendSessionState, SendSessionStatus, MediaFileInfo, GallerySaveResult } from '../model/Types';
import { formatSizeDetailed } from '../utils/FormatUtil';
import { TransferDeviceCard } from '../views/TransferDeviceCard';
import { TransferSessionList } from '../views/TransferSessionList';
import { TransferProgressView } from '../views/TransferProgressView';
import { SaveToGalleryDialog } from '../views/SaveToGalleryDialog';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TransferPage');
const MAX_CONTENT_WIDTH: number = 800;

@Entry
@ComponentV2
struct TransferPage {
  @Local viewModel: TransferViewModel = new TransferViewModel();
  @Local private isSm: boolean = true
  private refreshCallback: () => void = () => {
  }
  private smListener: mediaquery.MediaQueryListener | null = null
  // 相册保存弹窗控制器（在 openGalleryDialog 中创建）
  private galleryDialogController: CustomDialogController | null = null
  // 上一次 refreshCallback 时弹窗是否可见（用于检测状态变化）
  private prevGalleryDialogVisible: boolean = false

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as TransferPageParams;
    if (params !== undefined) {
      this.viewModel.load(params, this.getUIContext().getHostContext() as common.UIAbilityContext);
    }

    // 自动关闭桥：VM 的完成定时器通过该动作返回导航。
    this.viewModel.dismissAction = () => {
      this.getUIContext().getRouter().back();
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
    this.getUIContext().getRouter().back();
  }

  private dismissAndBack(): void {
    this.viewModel.markDismissed();
    this.getUIContext().getRouter().back();
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
      return this.getContext().resourceManager.getStringSync($r('app.string.gallery_save_media_count').id)
        .replace('%d', String(imageCount)).replace('%d', String(videoCount));
    } else if (imageCount > 0) {
      return this.getContext().resourceManager.getStringSync($r('app.string.gallery_save_image_count').id)
        .replace('%d', String(imageCount));
    } else if (videoCount > 0) {
      return this.getContext().resourceManager.getStringSync($r('app.string.gallery_save_video_count').id)
        .replace('%d', String(videoCount));
    }
    return '';
  }

  private getContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private openGalleryDialog(): void {
    // 重新创建弹窗控制器以绑定最新数据
    this.galleryDialogController = new CustomDialogController({
      builder: SaveToGalleryDialog({
        mediaFiles: this.viewModel.pendingMediaFiles,
        mediaCountText: this.buildMediaCountText(),
        appContext: this.getContext(),
        onSaveComplete: (result: GallerySaveResult) => {
          this.viewModel.onGallerySaveComplete(result);
          this.showGallerySaveResultToast(result);
        },
        onDismiss: () => {
          this.viewModel.onGalleryDialogDismiss();
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    this.galleryDialogController.open();
  }

  private showGallerySaveResultToast(result: GallerySaveResult): void {
    let message: string = '';
    if (result.failCount === 0 && result.successCount > 0) {
      message = this.getContext().resourceManager.getStringSync($r('app.string.gallery_save_success').id);
    } else if (result.successCount === 0) {
      message = this.getContext().resourceManager.getStringSync($r('app.string.gallery_save_failed').id);
    } else {
      let partial: string = this.getContext().resourceManager.getStringSync($r('app.string.gallery_save_partial').id);
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
      .border({ width: 1, color: $r('app.color.border_light') })

      if (this.isUrl(this.viewModel.textMessageContent)) {
        Row({ space: DesignTokens.space.md }) {
          Button() {
            Row({ space: 6 }) {
              Text($r('app.string.open_link'))
                .fontSize(DesignTokens.font.subtitleM)
                .fontColor($r('app.color.text_on_color'))
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(DesignTokens.hotspot.minSize)
          .backgroundColor($r('app.color.accent_blue'))
          .borderRadius(DesignTokens.radius.max)
          .onClick(() => {
            this.viewModel.openUrl(this.viewModel.textMessageContent.trim());
          })

          Button() {
            Row({ space: 6 }) {
              Text($r('app.string.copy'))
                .fontSize(DesignTokens.font.subtitleM)
                .fontColor($r('app.color.text_on_color'))
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(DesignTokens.hotspot.minSize)
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
        .height(DesignTokens.hotspot.minSize)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_medium'), style: BorderStyle.Solid })
        .borderRadius(DesignTokens.radius.max)
        .margin({ top: DesignTokens.space.md })
        .onClick(() => {
          this.dismissAndBack();
        })
      } else {
        Row({ space: DesignTokens.space.md }) {
          Button() {
            Row({ space: 6 }) {
              Text($r('app.string.close'))
                .fontSize(DesignTokens.font.subtitleM)
                .fontColor($r('app.color.text_secondary'))
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(DesignTokens.hotspot.minSize)
          .backgroundColor($r('app.color.card_background'))
          .border({ width: 1, color: $r('app.color.border_medium'), style: BorderStyle.Solid })
          .borderRadius(DesignTokens.radius.max)
          .onClick(() => {
            this.dismissAndBack();
          })

          Button() {
            Row({ space: 6 }) {
              Text($r('app.string.copy'))
                .fontSize(DesignTokens.font.subtitleM)
                .fontColor($r('app.color.text_on_color'))
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(DesignTokens.hotspot.minSize)
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
        deviceModel: this.viewModel.sourceDeviceModel,
        isSource: true
      })

      Column() {
        SymbolGlyph($r('sys.symbol.arrow_down'))
          .fontSize(24)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })

      TransferDeviceCard({
        alias: this.viewModel.targetAlias,
        ip: this.viewModel.targetIp,
        deviceType: this.viewModel.targetDeviceType,
        deviceModel: this.viewModel.targetDeviceModel,
        isSource: false
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
          .width(32)
          .height(32)
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
        .height(DesignTokens.hotspot.minSize)
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
        .height(DesignTokens.hotspot.minSize)
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

        // 验证按钮——携带本地 + 远端指纹跳转到 VerifyPage
        if (this.viewModel.targetFingerprint.length > 0) {
          Text($r('app.string.verify_button'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.accent_blue'))
            .padding({
              left: DesignTokens.space.sm,
              right: DesignTokens.space.sm,
              top: DesignTokens.space.xs,
              bottom: DesignTokens.space.xs
            })
            .borderRadius(DesignTokens.radius.md)
            .backgroundColor($r('app.color.accent_blue_bg'))
            .onClick(() => {
              let localFp: string = this.viewModel.getServerFingerprintValue();
              this.getUIContext().getRouter().pushUrl({
                url: 'pages/VerifyPage',
                params: {
                  localFingerprint: localFp,
                  remoteFingerprint: this.viewModel.targetFingerprint
                }
              });
            })
        }
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Row() {
          Column() {
            if (this.viewModel.isClipboard) {
              this.clipboardView()
            } else if (this.viewModel.isTextSend) {
              this.textSendView()
            } else {
              TransferDeviceCard({
                alias: this.viewModel.sourceAlias,
                ip: this.viewModel.sourceIp,
                deviceType: this.viewModel.sourceDeviceType,
                deviceModel: this.viewModel.sourceDeviceModel,
                isSource: true
              })

              Column() {
                SymbolGlyph($r('sys.symbol.arrow_down'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .margin({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })

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
              }

              TransferDeviceCard({
                alias: this.viewModel.targetAlias,
                ip: this.viewModel.targetIp,
                deviceType: this.viewModel.targetDeviceType,
                deviceModel: this.viewModel.targetDeviceModel,
                isSource: false
              })

              // ── 多设备会话列表 ──
              if (this.viewModel.isSend && this.viewModel.currentSendMode === 'multiple' &&
                this.viewModel.sendSessions.length > 0) {
                Column() {
                  Text($r('app.string.multi_device_sessions'))
                    .fontSize(DesignTokens.font.bodyM)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                    .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.xs })

                  TransferSessionList({ viewModel: this.viewModel })
                }
                .width('100%')
              }

              Column() {
                if (this.viewModel.isSend) {
                  Text($r('app.string.transfer_file_count', this.viewModel.fileCount))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_tertiary'))
                } else {
                  Text($r('app.string.transfer_file_count', this.viewModel.fileCount))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_tertiary'))
                }
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

              if (this.viewModel.transferState === TransferState.Idle && !this.viewModel.isSend) {
                Row({ space: DesignTokens.space.md }) {
                  Button() {
                    Row({ space: 6 }) {
                      SymbolGlyph($r('sys.symbol.xmark'))
                        .fontSize(18)
                        .fontColor([$r('app.color.danger_red')])
                      Text($r('app.string.transfer_cancel'))
                        .fontSize(DesignTokens.font.subtitleM)
                        .fontColor($r('app.color.danger_red'))
                    }
                    .justifyContent(FlexAlign.Center)
                  }
                  .layoutWeight(1)
                  .height(DesignTokens.hotspot.minSize)
                  .backgroundColor($r('app.color.card_background'))
                  .border({ width: 1, color: $r('app.color.danger_red'), style: BorderStyle.Solid })
                  .borderRadius(DesignTokens.radius.max)
                  .onClick(() => {
                    this.onCancel();
                  })

                  Button() {
                    Row({ space: 6 }) {
                      SymbolGlyph($r('sys.symbol.checkmark'))
                        .fontSize(18)
                        .fontColor([$r('app.color.text_on_color')])
                      Text($r('app.string.transfer_confirm'))
                        .fontSize(DesignTokens.font.subtitleM)
                        .fontColor($r('app.color.text_on_color'))
                    }
                    .justifyContent(FlexAlign.Center)
                  }
                  .layoutWeight(1)
                  .height(DesignTokens.hotspot.minSize)
                  .backgroundColor($r('app.color.accent_blue'))
                  .borderRadius(DesignTokens.radius.max)
                  .onClick(() => {
                    this.viewModel.onConfirm();
                  })
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .margin({ top: DesignTokens.space.lg })
              } else if (this.viewModel.transferState === TransferState.Transferring) {
                Button() {
                  Row({ space: 6 }) {
                    SymbolGlyph($r('sys.symbol.xmark'))
                      .fontSize(18)
                      .fontColor([$r('app.color.text_on_color')])
                    Text($r('app.string.transfer_abort'))
                      .fontSize(DesignTokens.font.subtitleM)
                      .fontColor($r('app.color.text_on_color'))
                  }
                  .justifyContent(FlexAlign.Center)
                }
                .width('60%')
                .height(DesignTokens.hotspot.minSize)
                .backgroundColor($r('app.color.danger_red'))
                .borderRadius(DesignTokens.radius.max)
                .margin({ top: DesignTokens.space.lg })
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
                .height(DesignTokens.hotspot.minSize)
                .backgroundColor($r('app.color.accent_blue'))
                .borderRadius(DesignTokens.radius.max)
                .margin({ top: DesignTokens.space.lg })
                .onClick(() => {
                  this.dismissAndBack();
                })
              }
            }
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
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
