import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getLocalDeviceInfo, subscribe, unsubscribe,
  prepareSendFiles, sendToDevice, respondToRequest, getActiveProgress,
  getDeviceType, getDeviceModel, markSendCompleted } from '../service/AppService';
import { nativeCancelTransfer, nativeCancelLocalSession, nativeGetCurrentSendSessionId } from '../service/NativeBridge';
import { NativeCancelTarget } from '../model/NativeTypes';
import { DiscoveredDevice, TransferProgress, SendFileItem } from '../model/Types';

const TAG = 'TransferPage';
const DOMAIN = 0x0001;

interface TransferPageParams {
  mode: string
  sourceAlias: string
  sourceIp: string
  sourceDeviceType: string
  sourceDeviceModel: string
  targetAlias: string
  targetIp: string
  targetDeviceType: string
  targetDeviceModel: string
  fileUris: Array<string>
  targetPort: number
  targetFingerprint: string
  targetProtocol: string
  sessionId: string
  autoConfirm: boolean
  fileCount: number
  totalSize: number
}

enum TransferState {
  Idle,
  Transferring,
  Completed,
  Failed
}

@Entry
@Component
struct TransferPage {
  @State sourceAlias: string = ''
  @State sourceIp: string = ''
  @State sourceDeviceType: string = ''
  @State sourceDeviceModel: string = ''
  @State targetAlias: string = ''
  @State targetIp: string = ''
  @State targetDeviceType: string = ''
  @State targetDeviceModel: string = ''
  @State transferState: TransferState = TransferState.Idle
  @State progressPercent: number = 0
  @State fileCount: number = 0
  @State totalSize: number = 0
  @State isSend: boolean = true

  @StorageLink('recvTransferCompleted') recvTransferCompleted: string = ''
  @StorageLink('recvTransferCancelled') recvTransferCancelled: string = ''

  private fileUris: Array<string> = []
  private targetPort: number = 0
  private targetFingerprint: string = ''
  private targetProtocol: string = ''
  private sessionId: string = ''
  private autoConfirm: boolean = false
  private refreshCallback: () => void = () => {}
  private dismissTimer: number = -1

  aboutToAppear(): void {
    const params = router.getParams() as TransferPageParams;
    if (params !== undefined) {
      this.isSend = params.mode === 'send';

      this.sourceAlias = params.sourceAlias;
      this.sourceIp = params.sourceIp;
      this.sourceDeviceType = params.sourceDeviceType;
      this.sourceDeviceModel = params.sourceDeviceModel;

      this.targetAlias = params.targetAlias;
      this.targetIp = params.targetIp;
      this.targetDeviceType = params.targetDeviceType;
      this.targetDeviceModel = params.targetDeviceModel;

      this.fileCount = params.fileCount;
      this.totalSize = params.totalSize;

      if (this.isSend) {
        this.fileUris = params.fileUris;
        this.targetPort = params.targetPort;
        this.targetFingerprint = params.targetFingerprint;
        this.targetProtocol = params.targetProtocol;
      } else {
        this.sessionId = params.sessionId;
        this.autoConfirm = params.autoConfirm;
      }
    }

    hilog.info(DOMAIN, TAG, '[aboutToAppear] mode=%{public}s fileCount=%{public}d uriCount=%{public}d',
      this.isSend ? 'send' : 'receive', this.fileCount, this.fileUris.length);

    this.refreshCallback = () => {
      hilog.info(DOMAIN, TAG, '[refreshCallback] fired, transferState=%{public}d', this.transferState);
      this.updateProgress();
    };
    subscribe(this.refreshCallback);

    if (this.isSend) {
      setTimeout(() => {
        this.onConfirm();
      }, 300);
    } else if (this.autoConfirm) {
      setTimeout(() => {
        this.onConfirm();
      }, 300);
    }
  }

  aboutToDisappear(): void {
    unsubscribe(this.refreshCallback);
    if (this.dismissTimer >= 0) {
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
  }

  updateProgress(): void {
    if (this.transferState !== TransferState.Transferring) {
      hilog.info(DOMAIN, TAG, '[updateProgress] skip, transferState=%{public}d not Transferring', this.transferState);
      return;
    }
    if (!this.isSend && this.recvTransferCompleted.length > 0) {
      hilog.info(DOMAIN, TAG, '[updateProgress] recv completed, session=%{public}s', this.recvTransferCompleted);
      this.progressPercent = 100;
      this.transferState = TransferState.Completed;
      this.recvTransferCompleted = '';
      this.scheduleDismiss();
      return;
    }
    if (!this.isSend && this.recvTransferCancelled.length > 0) {
      hilog.info(DOMAIN, TAG, '[updateProgress] recv cancelled, session=%{public}s', this.recvTransferCancelled);
      this.transferState = TransferState.Failed;
      this.recvTransferCancelled = '';
      this.scheduleDismiss();
      return;
    }
    let allProgress: Array<TransferProgress> = getActiveProgress();
    hilog.info(DOMAIN, TAG, '[updateProgress] state=Transferring isSend=%{public}s progressItems=%{public}d',
      this.isSend ? 'true' : 'false', allProgress.length);
    let totalBytes: number = 0;
    let sentBytes: number = 0;
    for (let i = 0; i < allProgress.length; i++) {
      let p: TransferProgress = allProgress[i];
      if (this.isSend && !p.sessionId.startsWith('share-')) {
        totalBytes = totalBytes + p.totalBytes;
        sentBytes = sentBytes + p.bytesSent;
      } else if (!this.isSend) {
        totalBytes = totalBytes + p.totalBytes;
        sentBytes = sentBytes + p.bytesSent;
      }
    }
    if (totalBytes > 0) {
      let pct: number = (sentBytes * 100) / totalBytes;
      this.progressPercent = pct;
      hilog.info(DOMAIN, TAG, '[updateProgress] totalBytes=%{public}d sentBytes=%{public}d pct=%{public}s',
        totalBytes, sentBytes, pct.toFixed(1));
    }
    if (sentBytes >= totalBytes && totalBytes > 0) {
      hilog.info(DOMAIN, TAG, '[updateProgress] TRANSFER COMPLETE');
      this.transferState = TransferState.Completed;
      this.progressPercent = 100;
      if (this.isSend) {
        markSendCompleted();
      }
      this.scheduleDismiss();
    }
  }

  scheduleDismiss(): void {
    this.dismissTimer = setTimeout(() => {
      router.back();
    }, 2000);
  }

  onConfirm(): void {
    hilog.info(DOMAIN, TAG, '[onConfirm] called, transferState=%{public}d', this.transferState);
    if (this.transferState !== TransferState.Idle) {
      return;
    }
    this.transferState = TransferState.Transferring;

    if (this.isSend) {
      this.startSendTransfer();
    } else {
      this.startReceiveTransfer(true);
    }
  }

  onCancel(): void {
    if (this.dismissTimer >= 0) {
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
    if (this.transferState === TransferState.Idle) {
      if (!this.isSend && this.sessionId.length > 0) {
        respondToRequest(this.sessionId, false);
      }
      router.back();
    } else if (this.transferState === TransferState.Transferring) {
      if (this.isSend) {
        // The native side aborts local uploads unconditionally, and only POST
        // /cancel to the receiver when we already know the remote session id.
        let cancelSessionId: string = nativeGetCurrentSendSessionId();
        hilog.info(DOMAIN, TAG, '[onCancel] send cancel, session=%{public}s target=%{public}s:%{public}d',
          cancelSessionId, this.targetIp, this.targetPort);
        let cancelTarget: NativeCancelTarget = {
          ip: this.targetIp,
          port: this.targetPort,
          fingerprint: this.targetFingerprint,
          protocol: this.targetProtocol
        };
        nativeCancelTransfer(cancelTarget, cancelSessionId).then(() => {
          hilog.info(DOMAIN, TAG, '[onCancel] cancel done');
        }).catch((e: Object) => {
          hilog.error(DOMAIN, TAG, '[onCancel] cancel failed: %{public}s', JSON.stringify(e));
        });
      } else if (this.sessionId.length > 0) {
        nativeCancelLocalSession(this.sessionId).then(() => {
          hilog.info(DOMAIN, TAG, '[onCancel] local session cancelled');
        }).catch((e: Object) => {
          hilog.error(DOMAIN, TAG, '[onCancel] local cancel failed: %{public}s', JSON.stringify(e));
        });
      }
      this.transferState = TransferState.Failed;
      setTimeout(() => {
        router.back();
      }, 1000);
    } else {
      router.back();
    }
  }

  async startSendTransfer(): Promise<void> {
    hilog.info(DOMAIN, TAG, '[startSendTransfer] begin, uriCount=%{public}d', this.fileUris.length);
    try {
      let items: Array<SendFileItem> = await prepareSendFiles(this.fileUris);
      hilog.info(DOMAIN, TAG, '[startSendTransfer] prepareSendFiles done, itemCount=%{public}d', items.length);
      if (items.length === 0) {
        hilog.info(DOMAIN, TAG, '[startSendTransfer] no items prepared, fail');
        this.transferState = TransferState.Failed;
        return;
      }
      let targetDevice: DiscoveredDevice = {
        alias: this.targetAlias,
        ip: this.targetIp,
        port: this.targetPort,
        fingerprint: this.targetFingerprint,
        version: '',
        deviceModel: this.targetDeviceModel,
        deviceType: this.targetDeviceType,
        protocol: this.targetProtocol,
        lastSeen: Date.now()
      };
      let success: boolean = await sendToDevice(targetDevice, items);
      hilog.info(DOMAIN, TAG, '[startSendTransfer] sendToDevice returned, success=%{public}s', success ? 'true' : 'false');
      if (success) {
        hilog.info(DOMAIN, TAG, '[startSendTransfer] complete, setting 100%%');
        this.progressPercent = 100;
        this.transferState = TransferState.Completed;
        markSendCompleted();
        this.scheduleDismiss();
      } else {
        this.transferState = TransferState.Failed;
      }
    } catch (_e) {
      this.transferState = TransferState.Failed;
    }
  }

  startReceiveTransfer(accept: boolean): void {
    respondToRequest(this.sessionId, accept);
  }

  getDeviceIconResource(deviceType: string): Resource {
    if (deviceType === 'desktop') {
      return $r('app.media.ic_device_matebook');
    } else if (deviceType === 'web') {
      return $r('app.media.ic_browser');
    } else if (deviceType === 'headless') {
      return $r('app.media.ic_terminal');
    } else if (deviceType === 'server') {
      return $r('app.media.ic_server');
    } else if (deviceType === 'tablet') {
      return $r('app.media.ic_device_pad');
    } else {
      return $r('app.media.ic_public_devices_phone');
    }
  }

  getIpLastPart(ip: string): string {
    let parts: Array<string> = ip.split('.');
    if (parts.length > 0) {
      return parts[parts.length - 1];
    }
    return '0';
  }

  formatSize(size: number): string {
    let KB: number = 1024;
    let MB: number = KB * 1024;
    let GB: number = MB * 1024;
    if (size >= GB) {
      return (size / GB).toFixed(1) + ' GB';
    }
    if (size >= MB) {
      return (size / MB).toFixed(1) + ' MB';
    }
    if (size >= KB) {
      return (size / KB).toFixed(1) + ' KB';
    }
    return size + ' B';
  }

  @Builder
  deviceCard(alias: string, ip: string, deviceType: string, deviceModel: string, isSource: boolean): void {
    Column() {
      Row({ space: 12 }) {
        Image(this.getDeviceIconResource(deviceType))
          .width(36)
          .height(36)
          .fillColor('#182431')

        Column() {
          Text(alias)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#182431')

          Row({ space: 8 }) {
            Text('#' + this.getIpLastPart(ip))
              .fontSize(12)
              .fontColor('#36D')
              .backgroundColor('#E8F0FE')
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(4)

            Text(deviceModel)
              .fontSize(12)
              .fontColor('#36D')
              .backgroundColor('#E8F0FE')
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(4)
          }
          .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (isSource) {
          Text('FROM')
            .fontSize(10)
            .fontColor('#FFFFFF')
            .backgroundColor('#007DFF')
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
        } else {
          Text('TO')
            .fontSize(10)
            .fontColor('#FFFFFF')
            .backgroundColor('#2B8C2B')
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
        }
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .border({ width: 1, color: '#E8E8E8' })
  }

  build() {
    Column() {
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor('#182431')
          .onClick(() => {
            this.onCancel();
          })

        Text($r('app.string.transfer_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
          .margin({ left: 12 })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          this.deviceCard(this.sourceAlias, this.sourceIp, this.sourceDeviceType, this.sourceDeviceModel, true)

          Column() {
            Image($r('app.media.ic_gallery_sort_order'))
              .width(24)
              .height(24)
              .fillColor('#999999')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .margin({ top: 8, bottom: 8 })

          if (this.transferState !== TransferState.Idle) {
            Column() {
              Progress({ value: this.progressPercent, total: 100, type: ProgressType.Linear })
                .width('100%')
                .style({ strokeWidth: 8, enableSmoothEffect: true })
                .color('#007DFF')

              Text(this.progressPercent.toFixed(0) + '%')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor('#182431')
                .margin({ top: 8 })

              if (this.transferState === TransferState.Completed) {
                Text($r('app.string.transfer_complete'))
                  .fontSize(13)
                  .fontColor('#2B8C2B')
                  .margin({ top: 4 })
              } else if (this.transferState === TransferState.Failed) {
                Text($r('app.string.transfer_failed'))
                  .fontSize(13)
                  .fontColor('#FF4D4F')
                  .margin({ top: 4 })
              }
            }
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 8, bottom: 8 })
          }

          this.deviceCard(this.targetAlias, this.targetIp, this.targetDeviceType, this.targetDeviceModel, false)

          Column() {
            if (this.isSend) {
              Text(this.fileCount + ' file(s)')
                .fontSize(13)
                .fontColor('#666666')
            } else {
              Text(this.fileCount + ' file(s)')
                .fontSize(13)
                .fontColor('#666666')
            }
            if (this.totalSize > 0) {
              Text(this.formatSize(this.totalSize))
                .fontSize(12)
                .fontColor('#999999')
                .margin({ top: 4 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .margin({ top: 16 })

          if (this.transferState === TransferState.Idle && !this.isSend) {
            Row({ space: 16 }) {
              Button() {
                Row({ space: 6 }) {
                  Image($r('app.media.ic_public_cancel_filled'))
                    .width(18)
                    .height(18)
                    .fillColor('#FF4D4F')
                  Text($r('app.string.transfer_cancel'))
                    .fontSize(16)
                    .fontColor('#FF4D4F')
                }
                .justifyContent(FlexAlign.Center)
              }
              .layoutWeight(1)
              .height(48)
              .backgroundColor('#FFFFFF')
              .border({ width: 1, color: '#FF4D4F', style: BorderStyle.Solid })
              .borderRadius(24)
              .onClick(() => {
                this.onCancel();
              })

              Button() {
                Row({ space: 6 }) {
                  Image($r('app.media.ic_public_ok_filled'))
                    .width(18)
                    .height(18)
                    .fillColor('#FFFFFF')
                  Text($r('app.string.transfer_confirm'))
                    .fontSize(16)
                    .fontColor('#FFFFFF')
                }
                .justifyContent(FlexAlign.Center)
              }
              .layoutWeight(1)
              .height(48)
              .backgroundColor('#007DFF')
              .borderRadius(24)
              .onClick(() => {
                this.onConfirm();
              })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .margin({ top: 32 })
          } else if (this.transferState === TransferState.Transferring) {
            Button() {
              Row({ space: 6 }) {
                Image($r('app.media.ic_public_cancel_filled'))
                  .width(18)
                  .height(18)
                  .fillColor('#FFFFFF')
                Text($r('app.string.transfer_abort'))
                  .fontSize(16)
                  .fontColor('#FFFFFF')
              }
              .justifyContent(FlexAlign.Center)
            }
            .width('60%')
            .height(48)
            .backgroundColor('#FF4D4F')
            .borderRadius(24)
            .margin({ top: 32 })
            .onClick(() => {
              this.onCancel();
            })
          } else {
            Button() {
              Text('Back')
                .fontSize(16)
                .fontColor('#FFFFFF')
            }
            .width('60%')
            .height(48)
            .backgroundColor('#999999')
            .borderRadius(24)
            .margin({ top: 32 })
            .onClick(() => {
              router.back();
            })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }
}
