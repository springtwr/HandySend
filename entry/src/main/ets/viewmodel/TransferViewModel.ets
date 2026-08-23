import { common } from '@kit.AbilityKit';
import { getLogger, LogContext } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import {
  prepareSendFiles,
  sendToDevice,
  respondToRequest,
  getActiveProgress,
  markSendCompleted,
  clearSendProgress,
  SendResult,
  sendResultErrorMessage,
  getSendSessions,
  getSendMode,
  getServerFingerprint,
  peekRecvCompleted,
  peekRecvCancelled,
  peekRecvText,
  consumeRecvCompleted,
  consumeRecvCancelled,
  consumeRecvText,
  peekRecvMediaFiles,
  consumeRecvMediaFiles,
  isAutoFinish,
  isSaveToGallery,
  saveMediaToGallery,
  cleanupMediaSandboxFiles,
  calculateChecksumsForFiles,
  consumePrePreparedItems,
  isRecvSessionCancelled
} from '../service/AppService';
import { nativeCancelTransfer, nativeCancelLocalSession, nativeGetCurrentSendSessionId } from '../service/NativeBridge';
import { NativeCancelTarget } from '../model/NativeTypes';
import { DiscoveredDevice, TransferProgress, SendFileItem, SendSessionState, MediaFileInfo, GallerySaveResult } from '../model/Types';
import { copyText } from '../utils/ClipboardUtil';
import { updateGallerySavedStatus } from '../service/ReceiveHistoryService';

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
  // 相册保存弹窗状态
  @Trace public galleryDialogVisible: boolean = false
  @Trace public pendingMediaFiles: Array<MediaFileInfo> = []
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

    logger.debug(
      '[aboutToAppear] mode=' + (this.isSend ? 'send' : 'receive') + ' fileCount=' + this.fileCount + ' uriCount=' +
        this.fileUris.length);
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

  getContext(): common.UIAbilityContext | undefined {
    return this.context;
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
    // 取消优先于完成：发送方取消与最后文件进度事件
    // 存在竞态（两者可能同时挂起），此时应呈现"已取消"。
    let recvCancelled: string = peekRecvCancelled();
    if (!this.isSend && recvCancelled.length > 0) {
      logger.debug('[updateProgress] recv cancelled, session=' + recvCancelled.substring(0, 8) + ' mySession=' +
        this.sessionId.substring(0, 8));
      if (recvCancelled !== this.sessionId) {
        // 来自其他会话的过期取消——消费它，以免其
        // 不阻塞进度更新，然后继续向下执行。
        logger.debug('[updateProgress] consuming stale recvCancelled for session=' + recvCancelled.substring(0, 8));
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
    let recvCompleted: string = peekRecvCompleted();
    if (!this.isSend && recvCompleted.length > 0) {
      logger.debug('[updateProgress] recv completed, session=' + recvCompleted.substring(0, 8) + ' mySession=' +
        this.sessionId.substring(0, 8));
      if (recvCompleted !== this.sessionId) {
        // 来自其他会话的过期完成——消费它，以免其
        // 阻塞本会话的进度更新，然后落到
        // 下方正常的进度计算。
        logger.debug('[updateProgress] consuming stale recvCompleted for session=' + recvCompleted.substring(0, 8));
        consumeRecvCompleted();
      } else {
        // 防御竞态：finishReceiveSession 是异步函数，取消事件可能在
        // await exportSessionFiles 期间到达并已将 receiveSessionStates
        // 标记为 canceledBySender，但 pendingRecvCompleted 在异步
        // 完成后才被设置。此时必须丢弃已过期的完成信号。
        if (isRecvSessionCancelled(this.sessionId)) {
          logger.debug('[updateProgress] recvCompleted arrived but session already cancelled, discarding');
          consumeRecvCompleted();
          consumeRecvText();
          // 取消状态尚未通过 peekRecvCancelled 到达（可能已被消费），
          // 直接设为 Failed 让用户看到取消反馈。
          this.transferState = TransferState.Failed;
          this.errorMessage = this.recvCancelledMessage();
          if (!this.isClipboard) {
            this.scheduleDismiss();
          }
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
        // 消费媒体文件信息，判断是否需要弹出相册保存弹窗
        let mediaJson: string = consumeRecvMediaFiles();
        if (mediaJson.length > 0) {
          try {
            let parsed: Array<MediaFileInfo> = JSON.parse(mediaJson) as Array<MediaFileInfo>;
            if (parsed.length > 0) {
              this.pendingMediaFiles = parsed;
              this.galleryDialogVisible = true;
              // 取消已有的自动关闭定时器，弹窗显示期间不应关闭页面
              this.cancelDismissTimer();
            }
          } catch (_e) {
            logger.error('[updateProgress] failed to parse pendingRecvMediaFiles');
          }
        }
        // 文本消息（剪贴板流程）不应自动关闭。
        // 弹窗可见时也不应自动关闭——弹窗关闭后恢复。
        if (!this.isClipboard && !this.galleryDialogVisible) {
          this.scheduleDismiss();
        }
        return;
      }
    }
    if (this.transferState !== TransferState.Transferring) {
      logger.debug('[updateProgress] skip, transferState=' + this.transferState + ' not Transferring');
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
    logger.debug('[updateProgress] activeCount=' + allProgress.length + ' perFileCount=' + keys.length + ' sentBytes=' +
      sentBytes + ' totalSize=' + this.totalSize);
    // 发送侧和接收侧统一以 this.totalSize（所有文件之和）作为分母。
    // 接收侧此前从 activeProgress 动态累加 p.totalBytes，
    // 但小文件瞬间完成后大文件尚未开始，activeProgress 中
    // 只有小文件的条目，导致分母偏小、进度误判为 100%。
    // 已完成的文件条目也可能从 activeProgress 中移除，进一步缩小分母。
    let totalBytes: number = this.totalSize;
    if (totalBytes > 0) {
      let pct: number = (sentBytes * 100) / totalBytes;
      this.progressPercent = pct;
    }
    // 仅检查接收侧的完成状态。
    // 发送侧，完成状态由 startSendTransfer() 中的 sendToDevice promise 决定，
    // 这是所有文件已完全传输的可靠信号。
    if (!this.isSend && sentBytes >= totalBytes && totalBytes > 0) {
      // 防御竞态：取消事件可能在 perFileMaxSent 已达 100% 后到达，
      // 但 peekRecvCancelled 尚未被消费。字节计数不能覆盖取消判定。
      if (isRecvSessionCancelled(this.sessionId)) {
        logger.debug('[updateProgress] byte-count complete but session cancelled, setting Failed');
        this.transferState = TransferState.Failed;
        this.errorMessage = this.recvCancelledMessage();
        if (!this.isClipboard) {
          this.scheduleDismiss();
        }
        return;
      }
      this.progressPercent = 100;
      this.transferState = TransferState.Completed;
      // 消费媒体文件信息，判断是否需要弹出相册保存弹窗
      let mediaJson: string = consumeRecvMediaFiles();
      if (mediaJson.length > 0) {
        try {
          let parsed: Array<MediaFileInfo> = JSON.parse(mediaJson) as Array<MediaFileInfo>;
          if (parsed.length > 0) {
            this.pendingMediaFiles = parsed;
            this.galleryDialogVisible = true;
            // 取消已有的自动关闭定时器，弹窗显示期间不应关闭页面
            this.cancelDismissTimer();
          }
        } catch (_e) {
          logger.error('[updateProgress] failed to parse pendingRecvMediaFiles (byte-count path)');
        }
      }
      // 文本消息（剪贴板流程）不应自动关闭——用户
      // 需要时间阅读/复制内容后再手动关闭。
      // 弹窗可见时也不应自动关闭——弹窗关闭后恢复。
      if (!this.isClipboard && !this.galleryDialogVisible) {
        this.scheduleDismiss();
      }
    }
  }

  private scheduleDismiss(): void {
    // 仅当开启「自动完成」时，传输完成后自动退出传输页面
    if (!isAutoFinish()) {
      logger.debug('[scheduleDismiss] skipped, autoFinish disabled');
      return;
    }
    logger.debug('[scheduleDismiss] called, dismissed=' + (this.dismissed ? 'true' : 'false'));
    this.dismissTimer = setTimeout(() => {
      logger.debug('[scheduleDismiss] timer fired, dismissed=' + (this.dismissed ? 'true' : 'false'));
      if (!this.dismissed) {
        this.dismissed = true;
        if (this.dismissAction !== undefined) {
          this.dismissAction();
        }
      }
    }, 2000);
  }

  // 取消已有的自动关闭定时器（弹窗显示期间调用）
  private cancelDismissTimer(): void {
    if (this.dismissTimer >= 0) {
      logger.debug('[cancelDismissTimer] clearing dismissTimer');
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
  }

  onConfirm(): void {
    logger.debug('[onConfirm] called, transferState=' + this.transferState);
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
    logger.debug(
      '[onCancel] ENTER mode=' + (this.isSend ? 'send' : 'receive') + ' state=' + this.transferState + ' dismissed=' +
        (this.dismissed ? 'true' : 'false'));
    this.dismissed = true;
    if (this.dismissTimer >= 0) {
      logger.debug('[onCancel] clearing dismissTimer');
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
    if (this.autoConfirmTimer >= 0) {
      logger.debug('[onCancel] clearing autoConfirmTimer');
      clearTimeout(this.autoConfirmTimer);
      this.autoConfirmTimer = -1;
    }
    if (this.transferState === TransferState.Idle) {
      logger.debug('[onCancel] Idle path');
      if (!this.isSend && this.sessionId.length > 0) {
        respondToRequest(this.sessionId, false);
      }
    } else if (this.transferState === TransferState.Transferring) {
      if (this.isSend) {
        // 原生侧无条件中止本地上传，且仅 POST
        // 当已知远端会话 id 时，向接收方发送 /cancel。
        let cancelSessionId: string = nativeGetCurrentSendSessionId();
        logger.debug(
          '[onCancel] send cancel, session=' + cancelSessionId.substring(0, 8) + ' target=' + this.targetIp + ':' +
            this.targetPort);
        let cancelTarget: NativeCancelTarget = {
          ip: this.targetIp,
          port: this.targetPort,
          fingerprint: this.targetFingerprint,
          protocol: this.targetProtocol
        };
        nativeCancelTransfer(cancelTarget, cancelSessionId).then(() => {
          logger.debug('[onCancel] cancel done');
        }).catch((e: Object) => {
          logger.error('[onCancel] cancel failed: ' + JSON.stringify(e));
        });
      } else if (this.sessionId.length > 0) {
        nativeCancelLocalSession(this.sessionId).then(() => {
          logger.debug('[onCancel] local session cancelled');
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
      logger.debug(
        '[autoConfirm] timer fired, state=' + this.transferState + ' dismissed=' + (this.dismissed ? 'true' : 'false'));
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
    logger.debug('[startSendTransfer] begin, uriCount=' + this.fileUris.length);
    clearSendProgress();
    this.perFileMaxSent = {};
    this.progressPercent = 0;
    try {
      // 优先消费主页面预准备的文件（已含校验和），避免重复 prepareSendFiles
      let items: Array<SendFileItem> | undefined = consumePrePreparedItems();
      if (items !== undefined && items.length > 0) {
        logger.debug('[startSendTransfer] using pre-prepared items, count=' + items.length);
      } else {
        // 回退：无预准备缓存时自行准备（如深链接直接进入 TransferPage）
        items = await prepareSendFiles(this.fileUris);
        logger.debug(
          '[startSendTransfer] prepareSendFiles returned, dismissed=' + (this.dismissed ? 'true' : 'false') +
            ' items=' + items.length);
        if (this.dismissed) {
          logger.debug('[startSendTransfer] dismissed after prepareSendFiles, aborting');
          return;
        }
        if (items.length === 0) {
          logger.debug('[startSendTransfer] no items prepared, fail');
          this.transferState = TransferState.Failed;
          return;
        }
        // 自行准备时也计算校验和（主页面未提前计算的情况）
        await calculateChecksumsForFiles(items);
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
        logger.debug('[startSendTransfer] isTextSend, calling sendToDevice...');
        let result = await sendToDevice(targetDevice, items).catch((e: Error): SendResult => {
          return { success: false, error: { kind: 'other', message: String(e) } };
        });
        logger.debug(
          '[startSendTransfer] isTextSend sendToDevice returned, success=' + (result.success ? 'true' : 'false') +
            ' dismissed=' + (this.dismissed ? 'true' : 'false'));
        if (this.dismissed) {
          logger.debug('[startSendTransfer] isTextSend dismissed after sendToDevice, aborting');
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
      logger.debug('[startSendTransfer] calling sendToDevice for files...');
      let result = await sendToDevice(targetDevice, items);
      logger.debug(
        '[startSendTransfer] sendToDevice returned, success=' + (result.success ? 'true' : 'false') + ' dismissed=' +
          (this.dismissed ? 'true' : 'false'));
      if (this.dismissed) {
        logger.debug('[startSendTransfer] dismissed after sendToDevice, aborting');
        return;
      }
      if (result.success) {
        logger.debug('[startSendTransfer] complete, setting 100%');
        this.progressPercent = 100;
        this.transferState = TransferState.Completed;
        markSendCompleted();
        this.scheduleDismiss();
      } else {
        this.transferState = TransferState.Failed;
        this.errorMessage = sendResultErrorMessage(result.error) || this.defaultSendFailedMessage();
      }
    } catch (_e) {
      logger.error(
        '[startSendTransfer] exception: ' + String(_e) + ' dismissed=' + (this.dismissed ? 'true' : 'false'));
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
      logger.debug(
        '[startReceiveTransfer] alreadyAccepted, skipping respond, session=' + this.sessionId.substring(0, 8));
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

  // ── 相册保存弹窗方法 ──

  shouldShowGalleryDialog(): boolean {
    return this.galleryDialogVisible && this.pendingMediaFiles.length > 0;
  }

  onGalleryDialogDismiss(): void {
    logger.debug('[onGalleryDialogDismiss] called');
    this.galleryDialogVisible = false;
    // 清理保留的媒体文件沙箱副本
    if (this.pendingMediaFiles.length > 0) {
      cleanupMediaSandboxFiles(this.pendingMediaFiles);
      this.pendingMediaFiles = [];
    }
    // 弹窗关闭后恢复自动关闭流程
    if (this.transferState === TransferState.Completed && !this.isClipboard && isAutoFinish()) {
      this.scheduleDismiss();
    }
  }

  onGallerySaveComplete(result: GallerySaveResult): void {
    logger.debug('[onGallerySaveComplete] success=' + result.successCount + ' fail=' + result.failCount);
    // 清理保留的媒体文件沙箱副本
    if (this.pendingMediaFiles.length > 0) {
      cleanupMediaSandboxFiles(this.pendingMediaFiles);
      this.pendingMediaFiles = [];
    }
    this.galleryDialogVisible = false;
    // 更新历史记录的 savedToGallery 标记
    if (result.successCount > 0 && this.sessionId.length > 0) {
      updateGallerySavedStatus(this.sessionId, true);
    }
    // 弹窗关闭后恢复自动关闭流程
    if (this.transferState === TransferState.Completed && !this.isClipboard && isAutoFinish()) {
      this.scheduleDismiss();
    }
  }
}
