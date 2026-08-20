import { common } from '@kit.AbilityKit';
import { getLogger, LogContext } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { prepareSendFiles, sendToDevice, respondToRequest, getActiveProgress,
  markSendCompleted, clearSendProgress,
  SendResult, sendResultErrorMessage, getSendSessions, getSendMode, getServerFingerprint,
  peekRecvCompleted, peekRecvCancelled, peekRecvText,
  consumeRecvCompleted, consumeRecvCancelled, consumeRecvText, isAutoFinish } from '../service/AppService';
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
  // 事件层已自动确认并接收请求时为 true；
  // 页面自动确认，不再向原生侧重复响应。
  alreadyAccepted?: boolean
}

export enum TransferState {
  Idle,
  Transferring,
  Completed,
  Failed
}

// 从 TransferPage 抽出的传输协调器业务逻辑。
// 通过 dismissAction 将导航交还给视图（自动关闭）
// 以及视图自身的 onCancel() 包装——VM 绝不触碰 UIContext。
// 传输事件通过 AppService 的 peek/consume 消费（已移除 AppStorage）。
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
  // 由视图的验证按钮读取（用于指纹比对的远端指纹）。
  @Trace public targetFingerprint: string = ''
  // UIContext 边界的桥接：视图注入一个 back() 动作，供
  // 由自动关闭定时器驱动。VM 文件不包含 UI 导入。
  public dismissAction: (() => void) | undefined = undefined

  // 每个文件的最大 bytesSent 跟踪器：键 = "sessionId:fileId"，值 = 已见的最大 bytesSent。
  // 确保已完成的文件的贡献在其条目消失时不会丢失
  // 从 activeProgress 中消失（原生层停止轮询已完成的文件）。
  private perFileMaxSent: Record<string, number> = {}
  private fileUris: Array<string> = []
  private targetPort: number = 0
  private targetProtocol: string = ''
  private sessionId: string = ''
  private acceptedFileIds: Array<string> = []
  private autoConfirm: boolean = false
  private alreadyAccepted: boolean = false
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
      this.alreadyAccepted = params.alreadyAccepted === true;
      this.acceptedFileIds = params.acceptedFileIds ?? [];
      this.targetFingerprint = params.targetFingerprint;
      this.targetProtocol = params.targetProtocol;
    }

    if (params.isClipboard === true) {
      this.isClipboard = true;
      this.isTextMessage = true;
      this.textMessageContent = params.clipboardContent ?? '';
      // 不要在这里设置 transferState = Completed。文本预览
      // 可用，但实际文件传输仍必须发生（发送方
      // 需要上传文件）。以 Completed 开始会导致发送方
      // 以收到 204 后立即退出，并阻塞进度更新。
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

  // 清除定时器并标记为已关闭（从视图的 aboutToDisappear 调用）。
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

  // 清除待处理的自动关闭并标记为已关闭（手动返回按钮）。
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
    // 一次性接收事件（发送方完成 / 发送方取消）被处理
    // 与传输状态无关。取消可能在用户仍在操作时到达
    // 仍在决策中（Idle）；之前下方仅限 Transferring 的判断
    // 静默丢弃了它，导致页面停留在确认界面。
    let recvCompleted: string = peekRecvCompleted();
    if (!this.isSend && recvCompleted.length > 0) {
      logger.info('[updateProgress] recv completed, session=' + recvCompleted.substring(0, 8) + ' mySession=' + this.sessionId.substring(0, 8));
      if (recvCompleted !== this.sessionId) {
        // 来自其他会话的过期完成——消费它，以免其
        // 阻塞本会话的进度更新，然后落到
        // 下方正常的进度计算。
        logger.info('[updateProgress] consuming stale recvCompleted for session=' + recvCompleted.substring(0, 8));
        consumeRecvCompleted();
      } else {
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
        // 文本消息（剪贴板流程）不应自动关闭。
        if (!this.isClipboard) {
          this.scheduleDismiss();
        }
        return;
      }
    }
    let recvCancelled: string = peekRecvCancelled();
    if (!this.isSend && recvCancelled.length > 0) {
      logger.info('[updateProgress] recv cancelled, session=' + recvCancelled.substring(0, 8) + ' mySession=' + this.sessionId.substring(0, 8));
      if (recvCancelled !== this.sessionId) {
        // 来自其他会话的过期取消——消费它，以免其
        // 不阻塞进度更新，然后继续向下执行。
        logger.info('[updateProgress] consuming stale recvCancelled for session=' + recvCancelled.substring(0, 8));
        consumeRecvCancelled();
      } else {
        let wasTransferring: boolean = this.transferState === TransferState.Transferring;
        this.transferState = TransferState.Failed;
        this.errorMessage = this.recvCancelledMessage();
        consumeRecvCancelled();
        // 仅当传输已在进行时才自动关闭；当
        // 仍在等待确认，离开页面让用户看到
        // 取消反馈，可以手动返回。
        if (wasTransferring) {
          this.scheduleDismiss();
        }
        return;
      }
    }
    if (this.transferState !== TransferState.Transferring) {
      logger.info('[updateProgress] skip, transferState=' + this.transferState + ' not Transferring');
      return;
    }
    let allProgress: Array<TransferProgress> = getActiveProgress();
    let currentSendSid: string = this.isSend ? nativeGetCurrentSendSessionId() : '';
    // 从当前活动进度条目更新单文件最大值跟踪器。
    // 这确保即使已完成文件的条目从
    // activeProgress（原生层停止轮询它），其贡献得以保留。
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
    // 汇总所有单文件最大值作为总发送字节数（永不减少）
    let sentBytes: number = 0;
    let keys = Object.keys(this.perFileMaxSent);
    for (let i = 0; i < keys.length; i++) {
      sentBytes = sentBytes + this.perFileMaxSent[keys[i]];
    }
    logger.info('[updateProgress] activeCount=' + allProgress.length + ' perFileCount=' + keys.length + ' sentBytes=' + sentBytes + ' totalBytes=' + (this.isSend ? this.totalSize : 0));
    // 发送侧：以 this.totalSize（所有文件之和）作为分母，
    // 而非活动进度条目之和。已完成的文件条目
    // 从 activeProgress 中移除，这会缩小分母
    // 并导致进度提前跳到 100%。
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
    // 仅检查接收侧的完成状态。
    // 发送侧，完成状态由 startSendTransfer() 中的 sendToDevice promise 决定，
    // 这是所有文件已完全传输的可靠信号。
    if (!this.isSend && sentBytes >= totalBytes && totalBytes > 0) {
      this.progressPercent = 100;
      this.transferState = TransferState.Completed;
      // 文本消息（剪贴板流程）不应自动关闭——用户
      // 需要时间阅读/复制内容后再手动关闭。
      if (!this.isClipboard) {
        this.scheduleDismiss();
      }
    }
  }

  private scheduleDismiss(): void {
    // 仅当开启「自动完成」时，传输完成后自动退出传输页面
    if (!isAutoFinish()) {
      logger.info('[scheduleDismiss] skipped, autoFinish disabled');
      return;
    }
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
      // 快速传输（尤其是自动确认的）可能已经完成
      // 或在页面仍处于决策中时已被取消；消费这些
      // 立即消费一次性事件，避免页面停留在 0%。
      this.updateProgress();
    }
  }

  // 取消的业务部分（原生中止 + 状态）。导航由
  // 本函数返回后的视图包装。
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
        // 原生侧无条件中止本地上传，且仅 POST
        // 当已知远端会话 id 时，向接收方发送 /cancel。
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

  // 当流程需要时启动自动确认定时器（发送侧，或
  // 接收侧带有 autoConfirm 标志）。
  scheduleAutoConfirmIfNeeded(): void {
    if (this.isSend) {
      this.scheduleAutoConfirm();
    } else if (this.autoConfirm) {
      this.scheduleAutoConfirm();
    }
  }

  // 为传输流程启动自动确认定时器。
  scheduleAutoConfirm(): void {
    this.autoConfirmTimer = setTimeout(() => {
      logger.info('[autoConfirm] timer fired, state=' + this.transferState + ' dismissed=' + (this.dismissed ? 'true' : 'false'));
      this.onConfirm();
    }, 300);
  }

  // 剪贴板接收流程会在加载后不久自动接收请求。
  scheduleClipboardAccept(): void {
    setTimeout(() => {
      respondToRequest(this.sessionId, true, this.acceptedFileIds);
      this.transferState = TransferState.Transferring;
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
    if (this.alreadyAccepted) {
      // 事件层已自动确认并接收请求；原生侧
      // 已有决策，重复响应会报错。直接翻转
      // 进入传输中状态（页面仍显示进度）。
      logger.info('[startReceiveTransfer] alreadyAccepted, skipping respond, session=' + this.sessionId.substring(0, 8));
      return;
    }
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

  private recvCancelledMessage(): string {
    if (this.context === undefined) {
      return '';
    }
    return this.context.resourceManager.getStringSync($r('app.string.recv_cancelled_message').id);
  }

  private defaultSendErrorPrefix(): string {
    if (this.context === undefined) {
      return '';
    }
    return this.context.resourceManager.getStringSync($r('app.string.send_error_prefix').id);
  }
}
