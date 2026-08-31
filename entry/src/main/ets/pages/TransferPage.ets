import { ComponentContent, SymbolGlyphModifier, uiObserver } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { subscribe, unsubscribe } from '../service/AppService';
import { DesignTokens } from '../common/DesignTokens';
import { getMaxContentWidth, getPageMargin, isTabletPortrait } from '../common/Breakpoints';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { TransferViewModel, TransferPageParams, TransferState } from '../viewmodel/TransferViewModel';
import { MediaFileInfo, GallerySaveResult, VerifyPageParams } from '../model/Types';
import { formatSizeDetailed } from '../utils/FormatUtil';
import { getStringSync } from '../utils/ResourceUtil';
import { isUrl } from '../utils/IPValidator';
import { TransferDeviceCard } from '../views/TransferDeviceCard';
import { TransferSessionList } from '../views/TransferSessionList';
import { TransferProgressView } from '../views/TransferProgressView';
import { TransferFileList } from '../views/TransferFileList';
import { SaveToGalleryDialog } from '../views/SaveToGalleryDialog';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TransferPage');

@ComponentV2
export struct TransferPage {
  // 系统宽度断点（@Env 随窗口尺寸变化自动刷新，宽 320vp~520vp 范围）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: TransferViewModel = new TransferViewModel();
  // 路由参数（经 TransferPageBuilder 传入，与旧 pushUrl params 结构一致）
  @Param pageParam: Object = new Object()
  private refreshCallback: () => void = () => {
  }
  // 相册保存弹窗 ComponentContent（与 openCustomDialog 使用同一实例，供 closeCustomDialog 关闭）
  private galleryContentNode: ComponentContent<GallerySaveDialogParams> | null = null
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
  }

  aboutToDisappear(): void {
    logger.debug('[aboutToDisappear] mode=' + (this.viewModel.isSend ? 'send' : 'receive') + ' state=' +
      this.viewModel.transferState + ' dismissed=' + (this.viewModel.isDismissed() ? 'true' : 'false'));
    unsubscribe(this.refreshCallback);
    this.viewModel.unload();
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

  private openGalleryDialog(): void {
    // 与 DialogService 一致改用 ComponentContent + wrapBuilder 方式：ComponentContent 方式默认
    // customStyle=true，弹窗内容样式完全由 SaveToGalleryDialog 自定义，系统不会追加默认背板
    // （32vp 圆角 + 背景模糊），避免出现"弹窗之外还有一层"。
    let params = new GallerySaveDialogParams();
    params.mediaFiles = this.viewModel.pendingMediaFiles;
    params.mediaCountText = this.buildMediaCountText();
    params.onPerformSave = (mediaFiles: Array<MediaFileInfo>): Promise<GallerySaveResult> => {
      return this.viewModel.performGallerySave(mediaFiles);
    };
    params.onSaveComplete = (result: GallerySaveResult): void => {
      this.viewModel.onGallerySaveComplete(result);
      this.showGallerySaveResultToast(result);
    };
    params.onDismiss = (): void => {
      this.viewModel.onGalleryDialogDismiss();
    };
    params.onCloseDialog = (): void => {
      this.closeGalleryDialog();
    };
    let contentNode = new ComponentContent(this.getUIContext(), wrapBuilder(buildGallerySaveDialog), params);
    // closeCustomDialog 必须复用与 openCustomDialog 相同的 ComponentContent 实例
    this.galleryContentNode = contentNode;
    params.contentNode = contentNode;
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(contentNode, {
        autoCancel: true,
        alignment: DialogAlignment.Center
      })
      .catch(() => {
      });
  }

  private closeGalleryDialog(): void {
    if (this.galleryContentNode !== null) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.galleryContentNode);
      this.galleryContentNode = null;
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

  // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    let maxWidth: number = getMaxContentWidth(this.breakpointInfo.widthBreakpoint);
    if (isTabletPortrait(deviceInfo.deviceType, this.breakpointInfo.heightBreakpoint)) {
      maxWidth = 800;
    }
    if (maxWidth === 0) {
      return '100%';
    }
    return maxWidth;
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

      if (isUrl(this.viewModel.textMessageContent)) {
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
        .border(
          { width: DesignTokens.component.borderSlim, color: $r('app.color.border_medium'), style: BorderStyle.Solid })
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
          .border({
            width: DesignTokens.component.borderSlim,
            color: $r('app.color.border_medium'),
            style: BorderStyle.Solid
          })
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
  }

  @Builder
  textSendView(): void {
    Column() {
      // 方向说明（与文件传输新版式一致：只展示对端设备）
      Text($r('app.string.transfer_direction_to', this.viewModel.targetAlias))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: DesignTokens.space.tiny })

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
        if (this.viewModel.isClipboard) {
          Scroll() {
            Row() {
              Column() {
                this.clipboardView()
              }
              .width(this.getContentMaxWidth())
              .padding({
                left: getPageMargin(this.breakpointInfo.widthBreakpoint),
                right: getPageMargin(this.breakpointInfo.widthBreakpoint),
                bottom: DesignTokens.space.lg
              })
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
              .width(this.getContentMaxWidth())
              .padding({
                left: getPageMargin(this.breakpointInfo.widthBreakpoint),
                right: getPageMargin(this.breakpointInfo.widthBreakpoint),
                bottom: DesignTokens.space.lg
              })
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
                  .border({
                    width: DesignTokens.component.borderSlim,
                    color: $r('app.color.danger_red'),
                    style: BorderStyle.Solid
                  })
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
            .width(this.getContentMaxWidth())
            .padding({
              left: getPageMargin(this.breakpointInfo.widthBreakpoint),
              right: getPageMargin(this.breakpointInfo.widthBreakpoint),
              bottom: DesignTokens.space.tiny
            })
            .height('100%')
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .title($r('app.string.transfer_title'), { backgroundColor: $r('app.color.page_background') })
    .menus(this.viewModel.targetFingerprint.length > 0 ? [
      {
        value: $r('app.string.verify_button'),
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.checkmark_shield_fill')),
        action: () => {
          let localFp: string = this.viewModel.getServerFingerprintValue();
          let verifyParams: VerifyPageParams = {
            localFingerprint: localFp,
            remoteFingerprint: this.viewModel.targetFingerprint
          };
          this.pathStack.pushPathByName('VerifyPage', verifyParams);
        }
      }
    ] : [])
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

// ── 相册保存弹窗 ComponentContent 参数类与全局 Builder ──
// 采用与 DialogService 一致的 ComponentContent + wrapBuilder 模式（默认 customStyle=true），
// 使弹窗内容样式完全由 SaveToGalleryDialog 自定义，避免 Builder 方式的系统默认背板产生双层弹窗。

class GallerySaveDialogParams {
  mediaFiles: Array<MediaFileInfo> = []
  mediaCountText: string = ''
  onPerformSave: (mediaFiles: Array<MediaFileInfo>) => Promise<GallerySaveResult> =
    async (_mediaFiles: Array<MediaFileInfo>): Promise<GallerySaveResult> => {
      return { successCount: 0, failCount: 0, errors: [] };
    }
  onSaveComplete: (result: GallerySaveResult) => void = (_result: GallerySaveResult) => {
  }
  onDismiss: () => void = () => {
  }
  onCloseDialog: () => void = () => {
  }
  contentNode: ComponentContent<GallerySaveDialogParams> | null = null
}

@Builder
function buildGallerySaveDialog(params: GallerySaveDialogParams) {
  SaveToGalleryDialog({
    mediaFiles: params.mediaFiles,
    mediaCountText: params.mediaCountText,
    onPerformSave: params.onPerformSave,
    onSaveComplete: params.onSaveComplete,
    onDismiss: params.onDismiss,
    onCloseDialog: params.onCloseDialog
  })
}
