import { mediaquery } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { subscribe, unsubscribe } from '../service/AppService';
import { DesignTokens } from '../common/DesignTokens';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { TransferViewModel, TransferPageParams, TransferState } from '../viewmodel/TransferViewModel';
import { SendSessionState, SendSessionStatus } from '../model/Types';
import { formatSizeDetailed } from '../utils/FormatUtil';
import { TransferDeviceCard } from '../views/TransferDeviceCard';
import { TransferSessionList } from '../views/TransferSessionList';
import { TransferProgressView } from '../views/TransferProgressView';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TransferPage');
const MAX_CONTENT_WIDTH: number = 800;

@Entry
@ComponentV2
struct TransferPage {
  @Local viewModel: TransferViewModel = new TransferViewModel();
  @Local private isSm: boolean = true
  private refreshCallback: () => void = () => {}
  private smListener: mediaquery.MediaQueryListener | null = null

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as TransferPageParams;
    if (params !== undefined) {
      this.viewModel.load(params, this.getUIContext().getHostContext() as common.UIAbilityContext);
    }

    // Auto-dismiss bridge: the VM's completion timer navigates back through this action.
    this.viewModel.dismissAction = () => {
      this.getUIContext().getRouter().back();
    };

    this.refreshCallback = () => {
      logger.info('[refreshCallback] fired, transferState=' + this.viewModel.transferState);
      this.viewModel.updateProgress();
      // Update send sessions for multi-device display
      if (this.viewModel.shouldRefreshSessions()) {
        this.getUIContext().animateTo({ duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn }, () => {
          this.viewModel.refreshSessions();
        });
      }
    };
    subscribe(this.refreshCallback);

    if (this.viewModel.isClipboard) {
      this.viewModel.scheduleClipboardAccept();
      return;
    }

    this.viewModel.scheduleAutoConfirmIfNeeded();

    this.smListener = this.getUIContext().getMediaQuery().matchMediaSync('(320vp<=width<520vp)');
    this.smListener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isSm = result.matches;
    });
    this.isSm = this.smListener.matches;
  }

  aboutToDisappear(): void {
    logger.info('[aboutToDisappear] mode=' + (this.viewModel.isSend ? 'send' : 'receive') + ' state=' + this.viewModel.transferState + ' dismissed=' + (this.viewModel.isDismissed() ? 'true' : 'false'));
    unsubscribe(this.refreshCallback);
    this.viewModel.unload();
    if (this.smListener !== null) {
      this.smListener.off('change');
    }
  }

  onBackPress(): boolean {
    logger.info('[onBackPress] intercepted, transferState=' + this.viewModel.transferState);
    if (this.viewModel.transferState === TransferState.Transferring) {
      logger.info('[onBackPress] transferring, showing confirm dialog');
      this.getUIContext().showAlertDialog({
        title: $r('app.string.transfer_abort'),
        message: $r('app.string.transfer_abort_confirm'),
        primaryButton: {
          value: $r('app.string.dialog_cancel'),
          action: () => {}
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
      TransferDeviceCard({ alias: this.viewModel.sourceAlias, ip: this.viewModel.sourceIp,
        deviceType: this.viewModel.sourceDeviceType, deviceModel: this.viewModel.sourceDeviceModel, isSource: true })

      Column() {
        SymbolGlyph($r('sys.symbol.arrow_down'))
          .fontSize(24)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })

      TransferDeviceCard({ alias: this.viewModel.targetAlias, ip: this.viewModel.targetIp,
        deviceType: this.viewModel.targetDeviceType, deviceModel: this.viewModel.targetDeviceModel, isSource: false })

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
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
          .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
          .onClick(() => {
            this.onCancel();
          })

        Text($r('app.string.transfer_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)

        // Verify button — navigate to VerifyPage with local + remote fingerprints
        if (this.viewModel.targetFingerprint.length > 0) {
          Text($r('app.string.verify_button'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.accent_blue'))
            .padding({ left: DesignTokens.space.sm, right: DesignTokens.space.sm, top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
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
              TransferDeviceCard({ alias: this.viewModel.sourceAlias, ip: this.viewModel.sourceIp,
                deviceType: this.viewModel.sourceDeviceType, deviceModel: this.viewModel.sourceDeviceModel, isSource: true })

            Column() {
              SymbolGlyph($r('sys.symbol.arrow_down'))
                .fontSize(24)
                .fontColor([$r('app.color.text_secondary')])
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .margin({ top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })

            if (this.viewModel.transferState !== TransferState.Idle) {
              TransferProgressView({ viewModel: this.viewModel,
                onBack: () => { this.dismissAndBack(); },
                onCopy: (text: string) => { this.copyTextToClipboard(text); }
              })
            }

            TransferDeviceCard({ alias: this.viewModel.targetAlias, ip: this.viewModel.targetIp,
              deviceType: this.viewModel.targetDeviceType, deviceModel: this.viewModel.targetDeviceModel, isSource: false })

            // ── Multi-device session list ──
            if (this.viewModel.isSend && this.viewModel.currentSendMode === 'multiple' && this.viewModel.sendSessions.length > 0) {
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
                    action: () => {}
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
