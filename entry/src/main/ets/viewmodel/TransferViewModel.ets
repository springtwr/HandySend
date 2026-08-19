import { common } from '@kit.AbilityKit';
import { getLogger, LogContext } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { prepareSendFiles, sendToDevice, respondToRequest, getActiveProgress,
  markSendCompleted, clearSendProgress,
  SendResult, sendResultErrorMessage, getSendSessions, getSendMode, getServerFingerprint,
  peekRecvCompleted, peekRecvCancelled, peekRecvText,
  consumeRecvCompleted, consumeRecvCancelled, consumeRecvText } from '../service/AppService';
import { nativeCancelTransfer, nativeCancelLocalSession, nativeGetCurrentSendSessionId } from '../service/NativeBridge';
import { NativeCancelTarget } from '../model/NativeTypes';
import { DiscoveredDevice, TransferProgress, SendFileItem, SendSessionState } from '../model/Types';
import { copyText } from '../utils/ClipboardUtil';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TransferViewModel');

export interface TransferPageParams {
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
  sendMode?: string
  acceptedFileIds?: Array<string>
}

export enum TransferState {
  Idle,
  Transferring,
  Completed,
  Failed
}

// Transfer coordinator business logic extracted from TransferPage.
// Navigation is delegated back to the view via dismissAction (auto-dismiss)
// and the view's own onCancel() wrapper — the VM never touches UIContext.
// Transfer events are consumed via AppService peek/consume (AppStorage removed).
@ObservedV2
export class TransferViewModel {
  @Trace public sourceAlias: string = ''
  @Trace public sourceIp: string = ''
  @Trace public sourceDeviceType: string = ''
  @Trace public sourceDeviceModel: string = ''
  @Trace public targetAlias: string = ''
  @Trace public targetIp: string = ''
  @Trace public targetDeviceType: string = ''
  @Trace public targetDeviceModel: string = ''
  @Trace public transferState: TransferState = TransferState.Idle
  @Trace public progressPercent: number = 0
  @Trace public fileCount: number = 0
  @Trace public totalSize: number = 0
  @Trace public isSend: boolean = true
  @Trace public isTextMessage: boolean = false
  @Trace public textMessageContent: string = ''
  @Trace public isClipboard: boolean = false
  @Trace public isTextSend: boolean = false
  @Trace public errorMessage: string = ''
  @Trace public currentSendMode: string = 'single'
  @Trace public sendSessions: Array<SendSessionState> = []
  // Read by the view's verify button (remote fingerprint for fingerprint compare).
  @Trace public targetFingerprint: string = ''
  // Bridge for the UIContext boundary: the view injects a back() action used
  // by the auto-dismiss timer. VM file has no UI imports.
  public dismissAction: (() => void) | undefined = undefined

  // Per-file max bytesSent tracker: key = "sessionId:fileId", value = max bytesSent seen.
  // Ensures completed files' contributions are never lost when their entries
  // disappear from activeProgress (native stops polling finished files).
  private perFileMaxSent: Record<string, number> = {}
  private fileUris: Array<string> = []
  private targetPort: number = 0
  private targetProtocol: string = ''
  private sessionId: string = ''
  private acceptedFileIds: Array<string> = []
  private autoConfirm: boolean = false
  private dismissTimer: number = -1
  private autoConfirmTimer: number = -1
  private dismissed: boolean = false
  private context: common.UIAbilityContext | undefined = undefined

  load(params: TransferPageParams, context: common.UIAbilityContext): void {
    this.context = context;
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
      this.acceptedFileIds = params.acceptedFileIds ?? [];
      this.targetFingerprint = params.targetFingerprint;
      this.targetProtocol = params.targetProtocol;
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

    if (params.sendMode !== undefined) {
      this.currentSendMode = params.sendMode;
    } else {
      this.currentSendMode = getSendMode();
    }

    logger.info('[aboutToAppear] mode=' + (this.isSend ? 'send' : 'receive') + ' fileCount=' + this.fileCount + ' uriCount=' + this.fileUris.length);
  }

  // Clears timers + marks dismissed (called from the view's aboutToDisappear).
  unload(): void {
    this.dismissed = true;
    if (this.dismissTimer >= 0) {
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
    if (this.autoConfirmTimer >= 0) {
      clearTimeout(this.autoConfirmTimer);
      this.autoConfirmTimer = -1;
    }
  }

  // Clears pending auto-dismiss and marks dismissed (manual back buttons).
  markDismissed(): void {
    if (this.dismissTimer >= 0) {
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
    this.dismissed = true;
  }

  isDismissed(): boolean {
    return this.dismissed;
  }

  shouldRefreshSessions(): boolean {
    return this.isSend && this.currentSendMode === 'multiple';
  }

  refreshSessions(): void {
    this.sendSessions = getSendSessions();
  }

  getServerFingerprintValue(): string {
    return getServerFingerprint();
  }

  copyTextToClipboard(text: string): boolean {
    return copyText(text);
  }

  openUrl(url: string): void {
    if (this.context === undefined) {
      return;
    }
    this.context.openLink(url).catch((_e: Object) => {
      logger.error('openLink failed: ' + JSON.stringify(_e));
    });
  }

  updateProgress(): void {
    if (this.isClipboard) {
      return;
    }
    if (this.transferState !== TransferState.Transferring) {
      logger.info('[updateProgress] skip, transferState=' + this.transferState + ' not Transferring');
      return;
    }
    let recvCompleted: string = peekRecvCompleted();
    if (!this.isSend && recvCompleted.length > 0) {
      logger.info('[updateProgress] recv completed, session=' + recvCompleted.substring(0, 8) + ' mySession=' + this.sessionId.substring(0, 8));
      if (recvCompleted !== this.sessionId) {
        return;
      }
      let recvText: string = peekRecvText();
      if (recvText.length > 0) {
        try {
          let msg = JSON.parse(recvText) as Record<string, string>;
          if (msg['sessionId'] === this.sessionId) {
            this.textMessageContent = msg['content'] as string;
            this.isTextMessage = true;
            this.progressPercent = 100;
            this.transferState = TransferState.Completed;
            consumeRecvCompleted();
            consumeRecvText();
            return;
          }
        } catch (_e) {
          consumeRecvText();
        }
      }
      this.progressPercent = 100;
      this.transferState = TransferState.Completed;
      consumeRecvCompleted();
      this.scheduleDismiss();
      return;
    }
    let recvCancelled: string = peekRecvCancelled();
    if (!this.isSend && recvCancelled.length > 0) {
      logger.info('[updateProgress] recv cancelled, session=' + recvCancelled.substring(0, 8) + ' mySession=' + this.sessionId.substring(0, 8));
      if (recvCancelled !== this.sessionId) {
        return;
      }
      this.transferState = TransferState.Failed;
      consumeRecvCancelled();
      this.scheduleDismiss();
      return;
    }
    let allProgress: Array<TransferProgress> = getActiveProgress();
    let currentSendSid: string = this.isSend ? nativeGetCurrentSendSessionId() : '';
    // Update per-file max tracker from current active progress entries.
    // This ensures that even when a completed file's entry disappears from
    // activeProgress (native stops polling it), its contribution is preserved.
    for (let i = 0; i < allProgress.length; i++) {
      let p: TransferProgress = allProgress[i];
      let shouldTrack: boolean = false;
      if (this.isSend && !p.sessionId.startsWith('share-')) {
        shouldTrack = currentSendSid.length > 0 && p.sessionId.startsWith(currentSendSid);
      } else if (!this.isSend && p.sessionId === this.sessionId) {
        shouldTrack = true;
      }
      if (shouldTrack) {
        let key: string = p.sessionId + ':' + p.fileId;
        let prev: number | undefined = this.perFileMaxSent[key];
        if (prev === undefined || p.bytesSent > prev) {
          this.perFileMaxSent[key] = p.bytesSent;
        }
      }
    }
    // Sum all per-file max values for total sent bytes (never decreases)
    let sentBytes: number = 0;
    let keys = Object.keys(this.perFileMaxSent);
    for (let i = 0; i < keys.length; i++) {
      sentBytes = sentBytes + this.perFileMaxSent[keys[i]];
    }
    logger.info('[updateProgress] activeCount=' + allProgress.length + ' perFileCount=' + keys.length + ' sentBytes=' + sentBytes + ' totalBytes=' + (this.isSend ? this.totalSize : 0));
    // For send side: use this.totalSize (sum of ALL files) as denominator,
    // not the sum of active progress entries. Completed file entries are
    // removed from activeProgress, which would shrink the denominator
    // and cause progress to jump to 100% prematurely.
    let totalBytes: number = this.isSend ? this.totalSize : 0;
    if (!this.isSend) {
      for (let i = 0; i < allProgress.length; i++) {
        let p: TransferProgress = allProgress[i];
        if (p.sessionId === this.sessionId) {
          totalBytes = totalBytes + p.totalBytes;
        }
      }
    }
    if (totalBytes > 0) {
      let pct: number = (sentBytes * 100) / totalBytes;
      this.progressPercent = pct;
    }
    // Only check completion for receive side.
    // For send side, completion is determined by the sendToDevice promise in startSendTransfer(),
    // which is the reliable signal that ALL files have been fully transferred.
    if (!this.isSend && sentBytes >= totalBytes && totalBytes > 0) {
      this.progressPercent = 100;
      this.transferState = TransferState.Completed;
      this.scheduleDismiss();
    }
  }

  private scheduleDismiss(): void {
    logger.info('[scheduleDismiss] called, dismissed=' + (this.dismissed ? 'true' : 'false'));
    this.dismissTimer = setTimeout(() => {
      logger.info('[scheduleDismiss] timer fired, dismissed=' + (this.dismissed ? 'true' : 'false'));
      if (!this.dismissed) {
        this.dismissed = true;
        if (this.dismissAction !== undefined) {
          this.dismissAction();
        }
      }
    }, 2000);
  }

  onConfirm(): void {
    logger.info('[onConfirm] called, transferState=' + this.transferState);
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

  // Business part of cancel (native abort + state). Navigation is done by the
  // view wrapper after this returns.
  onCancel(): void {
    logger.info('[onCancel] ENTER mode=' + (this.isSend ? 'send' : 'receive') + ' state=' + this.transferState + ' dismissed=' + (this.dismissed ? 'true' : 'false'));
    this.dismissed = true;
    if (this.dismissTimer >= 0) {
      logger.info('[onCancel] clearing dismissTimer');
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
    if (this.autoConfirmTimer >= 0) {
      logger.info('[onCancel] clearing autoConfirmTimer');
      clearTimeout(this.autoConfirmTimer);
      this.autoConfirmTimer = -1;
    }
    if (this.transferState === TransferState.Idle) {
      logger.info('[onCancel] Idle path');
      if (!this.isSend && this.sessionId.length > 0) {
        respondToRequest(this.sessionId, false);
      }
    } else if (this.transferState === TransferState.Transferring) {
      if (this.isSend) {
        // The native side aborts local uploads unconditionally, and only POST
        // /cancel to the receiver when we already know the remote session id.
        let cancelSessionId: string = nativeGetCurrentSendSessionId();
        logger.info('[onCancel] send cancel, session=' + cancelSessionId.substring(0, 8) + ' target=' + this.targetIp + ':' + this.targetPort);
        let cancelTarget: NativeCancelTarget = {
          ip: this.targetIp,
          port: this.targetPort,
          fingerprint: this.targetFingerprint,
          protocol: this.targetProtocol
        };
        nativeCancelTransfer(cancelTarget, cancelSessionId).then(() => {
          logger.info('[onCancel] cancel done');
        }).catch((e: Object) => {
          logger.error('[onCancel] cancel failed: ' + JSON.stringify(e));
        });
      } else if (this.sessionId.length > 0) {
        nativeCancelLocalSession(this.sessionId).then(() => {
          logger.info('[onCancel] local session cancelled');
        }).catch((e: Object) => {
          logger.error('[onCancel] local cancel failed: ' + JSON.stringify(e));
        });
      }
      this.transferState = TransferState.Failed;
    }
  }

  // Starts the auto-confirm timer when the flow requires it (send side, or
  // receive side with autoConfirm flag).
  scheduleAutoConfirmIfNeeded(): void {
    if (this.isSend) {
      this.scheduleAutoConfirm();
    } else if (this.autoConfirm) {
      this.scheduleAutoConfirm();
    }
  }

  // Starts the auto-confirm timer for the transfer flow.
  scheduleAutoConfirm(): void {
    this.autoConfirmTimer = setTimeout(() => {
      logger.info('[autoConfirm] timer fired, state=' + this.transferState + ' dismissed=' + (this.dismissed ? 'true' : 'false'));
      this.onConfirm();
    }, 300);
  }

  // Clipboard receive flow auto-accepts the request shortly after load.
  scheduleClipboardAccept(): void {
    setTimeout(() => {
      respondToRequest(this.sessionId, true);
    }, 100);
  }

  async startSendTransfer(): Promise<void> {
    logger.info('[startSendTransfer] begin, uriCount=' + this.fileUris.length);
    clearSendProgress();
    this.perFileMaxSent = {};
    this.progressPercent = 0;
    try {
      let items: Array<SendFileItem> = await prepareSendFiles(this.fileUris);
      logger.info('[startSendTransfer] prepareSendFiles returned, dismissed=' + (this.dismissed ? 'true' : 'false') + ' items=' + items.length);
      if (this.dismissed) {
        logger.info('[startSendTransfer] dismissed after prepareSendFiles, aborting');
        return;
      }
      logger.info('[startSendTransfer] prepareSendFiles done, itemCount=' + items.length);
      if (items.length === 0) {
        logger.info('[startSendTransfer] no items prepared, fail');
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
        lastSeen: Date.now(),
        channels: [{ host: this.targetIp, port: this.targetPort, protocol: this.targetProtocol }]
      };
      if (this.isTextSend) {
        logger.info('[startSendTransfer] isTextSend, calling sendToDevice...');
        let result = await sendToDevice(targetDevice, items).catch((e: Error): SendResult => {
          return { success: false, error: { kind: 'other', message: String(e) } };
        });
        logger.info('[startSendTransfer] isTextSend sendToDevice returned, success=' + (result.success ? 'true' : 'false') + ' dismissed=' + (this.dismissed ? 'true' : 'false'));
        if (this.dismissed) {
          logger.info('[startSendTransfer] isTextSend dismissed after sendToDevice, aborting');
          return;
        }
        if (result.success) {
          this.progressPercent = 100;
          this.transferState = TransferState.Completed;
          markSendCompleted();
          this.scheduleDismiss();
        } else {
          this.transferState = TransferState.Failed;
          this.errorMessage = sendResultErrorMessage(result.error) || this.defaultSendFailedMessage();
        }
        return;
      }
      logger.info('[startSendTransfer] calling sendToDevice for files...');
      let result = await sendToDevice(targetDevice, items);
      logger.info('[startSendTransfer] sendToDevice returned, success=' + (result.success ? 'true' : 'false') + ' dismissed=' + (this.dismissed ? 'true' : 'false'));
      if (this.dismissed) {
        logger.info('[startSendTransfer] dismissed after sendToDevice, aborting');
        return;
      }
      if (result.success) {
        logger.info('[startSendTransfer] complete, setting 100%');
        this.progressPercent = 100;
        this.transferState = TransferState.Completed;
        markSendCompleted();
        this.scheduleDismiss();
      } else {
        this.transferState = TransferState.Failed;
        this.errorMessage = sendResultErrorMessage(result.error) || this.defaultSendFailedMessage();
      }
    } catch (_e) {
      logger.error('[startSendTransfer] exception: ' + String(_e) + ' dismissed=' + (this.dismissed ? 'true' : 'false'));
      if (!this.dismissed) {
        this.transferState = TransferState.Failed;
        this.errorMessage = this.defaultSendErrorPrefix() + String(_e);
      }
    }
  }

  startReceiveTransfer(accept: boolean): void {
    if (accept) {
      respondToRequest(this.sessionId, true, this.acceptedFileIds);
    } else {
      respondToRequest(this.sessionId, false);
    }
  }

  private defaultSendFailedMessage(): string {
    if (this.context === undefined) {
      return '';
    }
    return this.context.resourceManager.getStringSync($r('app.string.send_failed_prefix').id);
  }

  private defaultSendErrorPrefix(): string {
    if (this.context === undefined) {
      return '';
    }
    return this.context.resourceManager.getStringSync($r('app.string.send_error_prefix').id);
  }
}
