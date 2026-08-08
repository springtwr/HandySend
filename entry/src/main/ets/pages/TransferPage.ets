    import { router, promptAction, mediaquery } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { getLocalDeviceInfo, subscribe, unsubscribe,
  prepareSendFiles, sendToDevice, respondToRequest, getActiveProgress,
  getDeviceType, getDeviceModel, markSendCompleted, clearActiveProgress,
  SendResult } from '../service/AppService';
import { nativeCancelTransfer, nativeCancelLocalSession, nativeGetCurrentSendSessionId } from '../service/NativeBridge';
import { NativeCancelTarget } from '../model/NativeTypes';
import { DiscoveredDevice, TransferProgress, SendFileItem } from '../model/Types';

const TAG = 'TransferPage';
const DOMAIN = 0x0001;
const MAX_CONTENT_WIDTH: number = 800;

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
  isClipboard?: boolean
  clipboardContent?: string
  isTextSend?: boolean
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
  @StorageLink('recvTextMessage') recvTextMessage: string = ''

  @State isTextMessage: boolean = false
  @State textMessageContent: string = ''
  @State isClipboard: boolean = false
  @State isTextSend: boolean = false
  @State private isSm: boolean = true
  @State errorMessage: string = '' // 详细错误信息
  
  private fileUris: Array<string> = []
  private targetPort: number = 0
  private targetFingerprint: string = ''
  private targetProtocol: string = ''
  private sessionId: string = ''
  private autoConfirm: boolean = false
  private refreshCallback: () => void = () => {}
  private dismissTimer: number = -1
  private autoConfirmTimer: number = -1
  private dismissed: boolean = false
  private smListener: mediaquery.MediaQueryListener | null = null

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

      if (params.isClipboard === true) {
        this.isClipboard = true;
        this.isTextMessage = true;
        this.textMessageContent = params.clipboardContent ?? '';
        this.transferState = TransferState.Completed;
      }

      if (this.isSend && params.isTextSend === true) {
        this.isTextSend = true;
      }
    }

    hilog.info(DOMAIN, TAG, '[aboutToAppear] mode=%{public}s fileCount=%{public}d uriCount=%{public}d',
      this.isSend ? 'send' : 'receive', this.fileCount, this.fileUris.length);

    this.refreshCallback = () => {
      hilog.info(DOMAIN, TAG, '[refreshCallback] fired, transferState=%{public}d', this.transferState);
      this.updateProgress();
    };
    subscribe(this.refreshCallback);

    if (this.isClipboard) {
      setTimeout(() => {
        respondToRequest(this.sessionId, true);
      }, 100);
      return;
    }

    if (this.isSend) {
      this.autoConfirmTimer = setTimeout(() => {
        hilog.info(DOMAIN, TAG, '[autoConfirm] timer fired, state=%{public}d dismissed=%{public}s',
          this.transferState, this.dismissed ? 'true' : 'false');
        this.onConfirm();
      }, 300);
    } else if (this.autoConfirm) {
      this.autoConfirmTimer = setTimeout(() => {
        hilog.info(DOMAIN, TAG, '[autoConfirm] timer fired, state=%{public}d dismissed=%{public}s',
          this.transferState, this.dismissed ? 'true' : 'false');
        this.onConfirm();
      }, 300);
    }

    this.smListener = this.getUIContext().getMediaQuery().matchMediaSync('(320vp<=width<520vp)');
    this.smListener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isSm = result.matches;
    });
    this.isSm = this.smListener.matches;
  }

  aboutToDisappear(): void {
    hilog.info(DOMAIN, TAG, '[aboutToDisappear] mode=%{public}s state=%{public}d dismissed=%{public}s',
      this.isSend ? 'send' : 'receive', this.transferState, this.dismissed ? 'true' : 'false');
    this.dismissed = true;
    unsubscribe(this.refreshCallback);
    if (this.dismissTimer >= 0) {
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
    if (this.autoConfirmTimer >= 0) {
      clearTimeout(this.autoConfirmTimer);
      this.autoConfirmTimer = -1;
    }
    if (this.smListener !== null) {
      this.smListener.off('change');
    }
  }

  onBackPress(): boolean {
    hilog.info(DOMAIN, TAG, '[onBackPress] intercepted, delegating to onCancel');
    this.onCancel();
    return true;
  }

  updateProgress(): void {
    if (this.isClipboard) {
      return;
    }
    if (this.transferState !== TransferState.Transferring) {
      hilog.info(DOMAIN, TAG, '[updateProgress] skip, transferState=%{public}d not Transferring', this.transferState);
      return;
    }
    if (!this.isSend && this.recvTransferCompleted.length > 0) {
      hilog.info(DOMAIN, TAG, '[updateProgress] recv completed, session=%{public}s mySession=%{public}s',
        this.recvTransferCompleted, this.sessionId);
      if (this.recvTransferCompleted !== this.sessionId) {
        return;
      }
      if (this.recvTextMessage.length > 0) {
        let msg = JSON.parse(this.recvTextMessage) as Record<string, string>;
        if (msg['sessionId'] === this.sessionId) {
          this.textMessageContent = msg['content'] as string;
          this.isTextMessage = true;
          this.progressPercent = 100;
          this.transferState = TransferState.Completed;
          this.recvTransferCompleted = '';
          this.recvTextMessage = '';
          return;
        }
      }
      this.progressPercent = 100;
      this.transferState = TransferState.Completed;
      this.recvTransferCompleted = '';
      this.scheduleDismiss();
      return;
    }
    if (!this.isSend && this.recvTransferCancelled.length > 0) {
      hilog.info(DOMAIN, TAG, '[updateProgress] recv cancelled, session=%{public}s mySession=%{public}s',
        this.recvTransferCancelled, this.sessionId);
      if (this.recvTransferCancelled !== this.sessionId) {
        return;
      }
      this.transferState = TransferState.Failed;
      this.recvTransferCancelled = '';
      this.scheduleDismiss();
      return;
    }
    let allProgress: Array<TransferProgress> = getActiveProgress();
    let currentSendSid: string = this.isSend ? nativeGetCurrentSendSessionId() : '';
    let totalBytes: number = 0;
    let sentBytes: number = 0;
    for (let i = 0; i < allProgress.length; i++) {
      let p: TransferProgress = allProgress[i];
      if (this.isSend && !p.sessionId.startsWith('share-')) {
        let matchCurrent: boolean = currentSendSid.length > 0 && p.sessionId.startsWith(currentSendSid);
        if (matchCurrent) {
          totalBytes = totalBytes + p.totalBytes;
          sentBytes = sentBytes + p.bytesSent;
        }
      } else if (!this.isSend && p.sessionId === this.sessionId) {
        totalBytes = totalBytes + p.totalBytes;
        sentBytes = sentBytes + p.bytesSent;
      }
    }
    if (totalBytes > 0) {
      let pct: number = (sentBytes * 100) / totalBytes;
      this.progressPercent = pct;
    }
    if (sentBytes >= totalBytes && totalBytes > 0) {
      this.progressPercent = 100;
      if (this.isSend) {
        this.transferState = TransferState.Completed;
        markSendCompleted();
        this.scheduleDismiss();
      }
    }
  }

  scheduleDismiss(): void {
    hilog.info(DOMAIN, TAG, '[scheduleDismiss] called, dismissed=%{public}s', this.dismissed ? 'true' : 'false');
    this.dismissTimer = setTimeout(() => {
      hilog.info(DOMAIN, TAG, '[scheduleDismiss] timer fired, dismissed=%{public}s', this.dismissed ? 'true' : 'false');
      if (!this.dismissed) {
        this.dismissed = true;
        router.back();
      }
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
    hilog.info(DOMAIN, TAG, '[onCancel] ENTER mode=%{public}s state=%{public}d dismissed=%{public}s',
      this.isSend ? 'send' : 'receive', this.transferState, this.dismissed ? 'true' : 'false');
    this.dismissed = true;
    if (this.dismissTimer >= 0) {
      hilog.info(DOMAIN, TAG, '[onCancel] clearing dismissTimer');
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
    if (this.autoConfirmTimer >= 0) {
      hilog.info(DOMAIN, TAG, '[onCancel] clearing autoConfirmTimer');
      clearTimeout(this.autoConfirmTimer);
      this.autoConfirmTimer = -1;
    }
    if (this.transferState === TransferState.Idle) {
      hilog.info(DOMAIN, TAG, '[onCancel] Idle path, calling router.back()');
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
      hilog.info(DOMAIN, TAG, '[onCancel] Transferring path, calling router.back()');
      router.back();
    } else {
      hilog.info(DOMAIN, TAG, '[onCancel] Other state path, calling router.back()');
      router.back();
    }
  }

  async startSendTransfer(): Promise<void> {
    hilog.info(DOMAIN, TAG, '[startSendTransfer] begin, uriCount=%{public}d', this.fileUris.length);
    clearActiveProgress();
    this.progressPercent = 0;
    try {
      let items: Array<SendFileItem> = await prepareSendFiles(this.fileUris);
      hilog.info(DOMAIN, TAG, '[startSendTransfer] prepareSendFiles returned, dismissed=%{public}s items=%{public}d',
        this.dismissed ? 'true' : 'false', items.length);
      if (this.dismissed) {
        hilog.info(DOMAIN, TAG, '[startSendTransfer] dismissed after prepareSendFiles, aborting');
        return;
      }
      hilog.info(DOMAIN, TAG, '[startSendTransfer] prepareSendFiles done, itemCount=%{public}d', items.length);
      if (items.length === 0) {
        hilog.info(DOMAIN, TAG, '[startSendTransfer] no items prepared, fail');
        this.transferState = TransferState.Failed;
        return;
      }
      let actualTotal: number = 0;
      for (let i = 0; i < items.length; i++) {
        actualTotal = actualTotal + items[i].size;
      }
      this.totalSize = actualTotal;
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
      if (this.isTextSend) {
        hilog.info(DOMAIN, TAG, '[startSendTransfer] isTextSend, calling sendToDevice...');
        let result = await sendToDevice(targetDevice, items).catch((e: Error): SendResult => {
          return { success: false, error: String(e) } as SendResult;
        });
        hilog.info(DOMAIN, TAG, '[startSendTransfer] isTextSend sendToDevice returned, success=%{public}s dismissed=%{public}s',
          result.success ? 'true' : 'false', this.dismissed ? 'true' : 'false');
        if (this.dismissed) {
          hilog.info(DOMAIN, TAG, '[startSendTransfer] isTextSend dismissed after sendToDevice, aborting');
          return;
        }
        if (result.success) {
          this.progressPercent = 100;
          this.transferState = TransferState.Completed;
          markSendCompleted();
          this.scheduleDismiss();
        } else {
          this.transferState = TransferState.Failed;
          this.errorMessage = result.error || (getContext() as common.UIAbilityContext).resourceManager.getStringSync($r('app.string.send_failed_prefix').id);
        }
        return;
      }
      hilog.info(DOMAIN, TAG, '[startSendTransfer] calling sendToDevice for files...');
      let result = await sendToDevice(targetDevice, items);
      hilog.info(DOMAIN, TAG, '[startSendTransfer] sendToDevice returned, success=%{public}s dismissed=%{public}s',
        result.success ? 'true' : 'false', this.dismissed ? 'true' : 'false');
      if (this.dismissed) {
        hilog.info(DOMAIN, TAG, '[startSendTransfer] dismissed after sendToDevice, aborting');
        return;
      }
      if (result.success) {
        hilog.info(DOMAIN, TAG, '[startSendTransfer] complete, setting 100%%');
        this.progressPercent = 100;
        this.transferState = TransferState.Completed;
        markSendCompleted();
        this.scheduleDismiss();
      } else {
        this.transferState = TransferState.Failed;
        this.errorMessage = result.error || (getContext() as common.UIAbilityContext).resourceManager.getStringSync($r('app.string.send_failed_prefix').id);
      }
    } catch (_e) {
      hilog.error(DOMAIN, TAG, '[startSendTransfer] exception: %{public}s dismissed=%{public}s',
        String(_e), this.dismissed ? 'true' : 'false');
      if (!this.dismissed) {
        this.transferState = TransferState.Failed;
        this.errorMessage = (getContext() as common.UIAbilityContext).resourceManager.getStringSync($r('app.string.send_error_prefix').id) + String(_e);
      }
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

  isUrl(text: string): boolean {
    return /^https?:\/\/\S+/.test(text.trim());
  }

  copyTextToClipboard(text: string): void {
    let pasteData = pasteboard.createPlainTextData(text);
    pasteboard.getSystemPasteboard().setData(pasteData);
    promptAction.showToast({ message: $r('app.string.copy_success'), duration: 2000 });
  }

  openUrl(url: string): void {
    let context = getContext() as common.UIAbilityContext;
    context.openLink(url).catch((_e: Object) => {
      hilog.error(DOMAIN, TAG, 'openLink failed: %{public}s', JSON.stringify(_e));
    });
  }

  @Builder
  deviceCard(alias: string, ip: string, deviceType: string, deviceModel: string, isSource: boolean): void {
    Column() {
      Row({ space: 12 }) {
        Image(this.getDeviceIconResource(deviceType))
          .width(36)
          .height(36)
          .fillColor($r('app.color.text_primary'))

        Column() {
          Text(alias)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))

          Row({ space: 8 }) {
            Text('#' + this.getIpLastPart(ip))
              .fontSize(12)
              .fontColor($r('app.color.ip_blue_text'))
              .backgroundColor($r('app.color.accent_blue_bg'))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(4)

            Text(deviceModel)
              .fontSize(12)
              .fontColor($r('app.color.ip_blue_text'))
              .backgroundColor($r('app.color.accent_blue_bg'))
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
            .fontColor($r('app.color.text_on_color'))
            .backgroundColor($r('app.color.accent_blue'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
        } else {
          Text('TO')
            .fontSize(10)
            .fontColor($r('app.color.text_on_color'))
            .backgroundColor($r('app.color.success_green'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
        }
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(12)
    .border({ width: 1, color: $r('app.color.border_light') })
  }

  @Builder
  clipboardView(): void {
    Column() {
      Text($r('app.string.clipboard_from_device', this.sourceAlias))
        .fontSize(15)
        .fontColor($r('app.color.clipboard_text'))
        .margin({ top: 12, bottom: 12 })

      Column() {
        Text(this.textMessageContent)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .lineHeight(20)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .maxLines(12)
          .width('100%')
      }
      .width('88%')
      .padding(16)
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(12)
      .border({ width: 1, color: $r('app.color.border_light') })

      if (this.isUrl(this.textMessageContent)) {
        Row({ space: 16 }) {
          Button() {
            Row({ space: 6 }) {
              Text($r('app.string.open_link'))
                .fontSize(16)
                .fontColor($r('app.color.text_on_color'))
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(48)
          .backgroundColor($r('app.color.accent_blue'))
          .borderRadius(24)
          .onClick(() => {
            this.openUrl(this.textMessageContent.trim());
          })

          Button() {
            Row({ space: 6 }) {
              Text($r('app.string.copy'))
                .fontSize(16)
                .fontColor($r('app.color.text_on_color'))
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(48)
          .backgroundColor($r('app.color.accent_blue'))
          .borderRadius(24)
          .onClick(() => {
            this.copyTextToClipboard(this.textMessageContent);
            if (this.dismissTimer >= 0) {
              clearTimeout(this.dismissTimer);
              this.dismissTimer = -1;
            }
            this.dismissed = true;
            router.back();
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 32 })

        Button() {
          Text($r('app.string.close'))
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('60%')
        .height(48)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_medium'), style: BorderStyle.Solid })
        .borderRadius(24)
        .margin({ top: 16 })
        .onClick(() => {
          if (this.dismissTimer >= 0) {
            clearTimeout(this.dismissTimer);
            this.dismissTimer = -1;
          }
          this.dismissed = true;
          router.back();
        })
      } else {
        Row({ space: 16 }) {
          Button() {
            Row({ space: 6 }) {
              Text($r('app.string.close'))
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(48)
          .backgroundColor($r('app.color.card_background'))
          .border({ width: 1, color: $r('app.color.border_medium'), style: BorderStyle.Solid })
          .borderRadius(24)
          .onClick(() => {
            if (this.dismissTimer >= 0) {
              clearTimeout(this.dismissTimer);
              this.dismissTimer = -1;
            }
            this.dismissed = true;
            router.back();
          })

          Button() {
            Row({ space: 6 }) {
              Text($r('app.string.copy'))
                .fontSize(16)
                .fontColor($r('app.color.text_on_color'))
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(48)
          .backgroundColor($r('app.color.accent_blue'))
          .borderRadius(24)
          .onClick(() => {
            this.copyTextToClipboard(this.textMessageContent);
            if (this.dismissTimer >= 0) {
              clearTimeout(this.dismissTimer);
              this.dismissTimer = -1;
            }
            this.dismissed = true;
            router.back();
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 32 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  textSendView(): void {
    Column() {
      this.deviceCard(this.sourceAlias, this.sourceIp, this.sourceDeviceType, this.sourceDeviceModel, true)

      Column() {
        Image($r('app.media.ic_gallery_sort_order'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: 8, bottom: 8 })

      this.deviceCard(this.targetAlias, this.targetIp, this.targetDeviceType, this.targetDeviceModel, false)

      Column() {
        Text($r('app.string.transfer_file_count', this.fileCount))
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
        if (this.totalSize > 0) {
          Text(this.formatSize(this.totalSize))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 4 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: 16 })

      if (this.transferState === TransferState.Transferring) {
        LoadingProgress()
          .width(32)
          .height(32)
          .color($r('app.color.accent_blue'))
          .margin({ top: 24 })
        Text($r('app.string.sending'))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 12 })
      } else {
        Text($r('app.string.sent'))
          .fontSize(13)
          .fontColor($r('app.color.success_green'))
          .margin({ top: 24 })
        Button() {
          Text($r('app.string.back'))
            .fontSize(16)
            .fontColor($r('app.color.text_on_color'))
        }
        .width('60%')
        .height(48)
        .backgroundColor($r('app.color.accent_blue'))
        .borderRadius(24)
        .margin({ top: 32 })
        .onClick(() => {
          if (this.dismissTimer >= 0) {
            clearTimeout(this.dismissTimer);
            this.dismissTimer = -1;
          }
          this.dismissed = true;
          router.back();
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
          .onClick(() => {
            this.onCancel();
          })

        Text($r('app.string.transfer_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Row() {
          Column() {
            if (this.isClipboard) {
              this.clipboardView()
            } else if (this.isTextSend) {
              this.textSendView()
            } else {
              this.deviceCard(this.sourceAlias, this.sourceIp, this.sourceDeviceType, this.sourceDeviceModel, true)

            Column() {
              Image($r('app.media.ic_gallery_sort_order'))
                .width(24)
                .height(24)
                .fillColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 8, bottom: 8 })

            if (this.transferState !== TransferState.Idle) {
              Column() {
                Progress({ value: this.progressPercent, total: 100, type: ProgressType.Linear })
                  .width('100%')
                  .style({ strokeWidth: 8, enableSmoothEffect: true })
                  .color($r('app.color.accent_blue'))

                Text(this.progressPercent.toFixed(0) + '%')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .margin({ top: 8 })

                if (this.transferState === TransferState.Completed) {
                  if (this.isTextMessage) {
                    Column() {
                      Text($r('app.string.transfer_complete'))
                        .fontSize(13)
                        .fontColor($r('app.color.success_green'))
                        .margin({ top: 4, bottom: 12 })

                      Column() {
                        Text(this.textMessageContent)
                          .fontSize(14)
                          .fontColor($r('app.color.text_primary'))
                          .lineHeight(20)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .maxLines(12)
                          .width('100%')
                      }
                      .width('88%')
                      .padding(16)
                      .backgroundColor($r('app.color.card_background'))
                      .borderRadius(12)
                      .border({ width: 1, color: $r('app.color.border_light') })

                      if (this.isUrl(this.textMessageContent)) {
                        Text($r('app.string.open_link'))
                          .fontSize(13)
                          .fontColor($r('app.color.accent_blue'))
                          .decoration({ type: TextDecorationType.Underline })
                          .margin({ top: 12 })
                          .onClick(() => {
                            this.openUrl(this.textMessageContent.trim());
                          })
                      }
                    }
                    .alignItems(HorizontalAlign.Center)

                    Row({ space: 16 }) {
                      Button() {
                        Row({ space: 6 }) {
                          Text($r('app.string.close'))
                            .fontSize(16)
                            .fontColor($r('app.color.text_secondary'))
                        }
                        .justifyContent(FlexAlign.Center)
                      }
                      .layoutWeight(1)
                      .height(48)
                      .backgroundColor($r('app.color.card_background'))
                      .border({ width: 1, color: $r('app.color.border_medium'), style: BorderStyle.Solid })
                      .borderRadius(24)
                      .onClick(() => {
                        if (this.dismissTimer >= 0) {
                          clearTimeout(this.dismissTimer);
                          this.dismissTimer = -1;
                        }
                        this.dismissed = true;
                        router.back();
                      })

                      Button() {
                        Row({ space: 6 }) {
                          Text($r('app.string.copy'))
                            .fontSize(16)
                            .fontColor($r('app.color.text_on_color'))
                        }
                        .justifyContent(FlexAlign.Center)
                      }
                      .layoutWeight(1)
                      .height(48)
                      .backgroundColor($r('app.color.accent_blue'))
                      .borderRadius(24)
                      .onClick(() => {
                        this.copyTextToClipboard(this.textMessageContent);
                      })
                    }
                    .width('100%')
                    .justifyContent(FlexAlign.Center)
                    .margin({ top: 32 })
                  } else {
                    Text($r('app.string.transfer_complete'))
                      .fontSize(13)
                      .fontColor($r('app.color.success_green'))
                      .margin({ top: 4 })
                  }
                } else if (this.transferState === TransferState.Failed) {
                  Column() {
                    Text($r('app.string.transfer_failed'))
                      .fontSize(13)
                      .fontColor($r('app.color.danger_red'))
                    
                    if (this.errorMessage) {
                      Text(this.errorMessage)
                        .fontSize(12)
                        .fontColor($r('app.color.text_secondary'))
                        .margin({ top: 4 })
                        .textAlign(TextAlign.Center)
                        .maxLines(3)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                  }
                  .margin({ top: 4 })
                }
              }
              .alignItems(HorizontalAlign.Center)
              .margin({ top: 8, bottom: 8 })
            }

            this.deviceCard(this.targetAlias, this.targetIp, this.targetDeviceType, this.targetDeviceModel, false)

            Column() {
              if (this.isSend) {
                Text($r('app.string.transfer_file_count', this.fileCount))
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
              } else {
                Text($r('app.string.transfer_file_count', this.fileCount))
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
              }
              if (this.totalSize > 0) {
                Text(this.formatSize(this.totalSize))
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
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
                      .fillColor($r('app.color.danger_red'))
                    Text($r('app.string.transfer_cancel'))
                      .fontSize(16)
                      .fontColor($r('app.color.danger_red'))
                  }
                  .justifyContent(FlexAlign.Center)
                }
                .layoutWeight(1)
                .height(48)
                .backgroundColor($r('app.color.card_background'))
                .border({ width: 1, color: $r('app.color.danger_red'), style: BorderStyle.Solid })
                .borderRadius(24)
                .onClick(() => {
                  this.onCancel();
                })

                Button() {
                  Row({ space: 6 }) {
                    Image($r('app.media.ic_public_ok_filled'))
                      .width(18)
                      .height(18)
                      .fillColor($r('app.color.text_on_color'))
                    Text($r('app.string.transfer_confirm'))
                      .fontSize(16)
                      .fontColor($r('app.color.text_on_color'))
                  }
                  .justifyContent(FlexAlign.Center)
                }
                .layoutWeight(1)
                .height(48)
                .backgroundColor($r('app.color.accent_blue'))
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
                    .fillColor($r('app.color.text_on_color'))
                  Text($r('app.string.transfer_abort'))
                    .fontSize(16)
                    .fontColor($r('app.color.text_on_color'))
                }
                .justifyContent(FlexAlign.Center)
              }
              .width('60%')
              .height(48)
              .backgroundColor($r('app.color.danger_red'))
              .borderRadius(24)
              .margin({ top: 32 })
              .onClick(() => {
                this.onCancel();
              })
            } else {
              Button() {
                Text($r('app.string.back'))
                  .fontSize(16)
                  .fontColor($r('app.color.text_on_color'))
              }
              .width('60%')
              .height(48)
              .backgroundColor($r('app.color.text_secondary'))
              .borderRadius(24)
              .margin({ top: 32 })
              .onClick(() => {
                if (this.dismissTimer >= 0) {
                  clearTimeout(this.dismissTimer);
                  this.dismissTimer = -1;
                }
                this.dismissed = true;
                router.back();
              })
            }
            }
          }
          .width(this.isSm ? '100%' : MAX_CONTENT_WIDTH)
          .padding({ left: 16, right: 16, bottom: 24 })
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
}
