import { common } from '@kit.AbilityKit';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import {
  prepareSendFiles,
  sendToDevice,
  respondToRequest,
  getActiveProgress,
  markSendCompleted,
  clearSendProgress,
  removeProgressForSession,
  SendResult,
  sendResultErrorMessage,
  getSendSessions,
  getSendMode,
  getServerFingerprint,
  peekRecvCompleted,
  peekRecvCancelled,
  peekRecvFailed,
  peekRecvText,
  consumeRecvCompleted,
  consumeRecvCancelled,
  consumeRecvFailed,
  consumeRecvText,
  consumeRecvMediaFiles,
  isAutoFinish,
  cleanupMediaSandboxFiles,
  calculateChecksumsForFiles,
  consumePrePreparedItems,
  isRecvSessionCancelled,
  isRecvSessionFailed,
  nativeCancelTransfer,
  nativeCancelTransferLocal,
  nativeCancelLocalSession,
  nativeGetCurrentSendSessionId,
  updateGallerySavedStatus,
  saveMediaToGallery
} from '../service/AppService';
import { NativeCancelTarget } from '../model/NativeTypes';
import {
  DiscoveredDevice,
  TransferProgress,
  SendFileItem,
  SendSessionState,
  MediaFileInfo,
  GallerySaveResult,
  TransferFileDescriptor,
  TransferFileProgress
} from '../model/Types';
import { copyText } from '../utils/ClipboardUtil';
import { computeTransferFileProgress, computeSessionProgress } from '../utils/TransferProgressUtil';
import { getStringSyncFromContext } from '../utils/ResourceUtil';
import { SpeedEstimator } from '../utils/SpeedEstimator';

// 传输页展示层类型经 ViewModel 出口（View 层不直接 import model/Types）。
export { SendSessionState,
  SendSessionStatus,
  TransferFileProgress,
  FileProgressStatus,
  MediaFileInfo,
  GallerySaveResult,
  TransferFileDescriptor,
  DiscoveredDevice } from '../model/Types';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TransferViewModel', '传输');

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
  // 页面自动确认，不重复向原生侧响应。
  alreadyAccepted?: boolean
  // 本次传输的文件元数据清单（发送/接收两侧均传入），
  // 用于渲染文件清单与逐文件进度。
  fileDescriptors?: Array<TransferFileDescriptor>
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
// 传输事件通过 AppService 的 peek/consume 消费。
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
  @Trace public textMessageContent: string = ''
  @Trace public isClipboard: boolean = false
  @Trace public isTextSend: boolean = false
  @Trace public errorMessage: string = ''
  @Trace public currentSendMode: string = 'single'
  @Trace public sendSessions: Array<SendSessionState> = []
  // 文件清单元数据（发送/接收两侧共用），驱动逐文件进度/状态。
  @Trace public fileInfos: Array<TransferFileDescriptor> = []
  // 逐文件 UI 进度列表，随 progress_update 事件实时重建。
  @Trace public fileProgressList: Array<TransferFileProgress> = []
  // 多目标发送时每会话（sessionId）的已发送百分比，供会话列表展示（0-100）。
  @Trace public sessionProgress: Record<string, number> = {}
  // 由视图的验证按钮读取（用于指纹比对的远端指纹）。
  @Trace public targetFingerprint: string = ''
  // 相册保存弹窗状态
  @Trace public galleryDialogVisible: boolean = false
  @Trace public pendingMediaFiles: Array<MediaFileInfo> = []
  // UI 显示用速度/ETA（降频到约 1 秒刷新一次，避免跳动）。
  @Trace public displaySpeed: number = 0
  @Trace public displayEta: number = -1
  // UIContext 边界的桥接：视图注入一个 back() 动作，供
  // 由自动关闭定时器驱动。VM 文件不包含 UI 导入。
  public dismissAction: (() => void) | undefined = undefined
  // 每个文件的最大 bytesSent 跟踪器：键 = "sessionId:fileId"，值 = 已见的最大 bytesSent。
  // 确保已完成的文件的贡献在其条目消失时不会丢失
  // 从 activeProgress 中消失（原生层停止轮询已完成的文件）。
  private perFileMaxSent: Record<string, number> = {}
  // 速度滑动窗口估算器（与 MTA 路径共用同一算子，口径见 SpeedEstimator）。
  private speedEstimator: SpeedEstimator = new SpeedEstimator()
  // 字节无增长达到该阈值时速度视为过期，显示回退占位符。
  private static readonly SPEED_STALE_MS: number = 3000
  // 上次将速度/ETA 同步到 @Trace 显示属性的时间戳；约 1 秒同步一次。
  private lastDisplaySyncTime: number = 0
  // 显示同步间隔（毫秒）。
  private static readonly DISPLAY_SYNC_INTERVAL: number = 1000
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
    this.fileInfos = params.fileDescriptors ?? new Array<TransferFileDescriptor>();

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

    // 进入页面即构建一次逐文件进度列表（Idle/等待确认阶段也能看到文件清单与 waiting 状态）。
    this.rebuildFileProgress();

    logger.debug(
      'mode=' + (this.isSend ? 'send' : 'receive') + ' fileCount=' + this.fileCount + ' uriCount=' +
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
    this.rebuildSessionProgress();
  }

  // 多目标发送边缘路径：为每个会话聚合已发送字节/总字节的百分比。
  // 直接基于 activeProgress（而非 perFileMaxSent），因为多目标各会话
  // 都可能被原生层推送进度，而 perFileMaxSent 仅追踪当前发送会话。
  private rebuildSessionProgress(): void {
    this.sessionProgress = computeSessionProgress(this.sendSessions, getActiveProgress());
  }

  // 依据 perFileMaxSent + activeProgress 重建逐文件进度列表（纯逻辑抽取到 TransferProgressUtil）。
  // 匹配以本次传输的文件清单为基准：严格按 fileId 精确匹配（fileId 为本次传输唯一标识，
  // 天然排除上一轮/其他会话残留的进度条目，避免"未开始就显示 100%"）。
  private rebuildFileProgress(): void {
    let sentByFileId: Record<string, number> = {};
    let keys = Object.keys(this.perFileMaxSent);
    for (let i = 0; i < keys.length; i++) {
      let idx = keys[i].lastIndexOf(':');
      if (idx >= 0) {
        sentByFileId[keys[i].substring(idx + 1)] = this.perFileMaxSent[keys[i]];
      }
    }
    let allProgress: Array<TransferProgress> = getActiveProgress();
    for (let i = 0; i < allProgress.length; i++) {
      let fid: string = this.resolveProgressFileId(allProgress[i]);
      if (fid.length === 0) {
        continue;
      }
      let prev: number | undefined = sentByFileId[fid];
      if (prev === undefined || allProgress[i].bytesSent > prev) {
        sentByFileId[fid] = allProgress[i].bytesSent;
      }
    }
    this.fileProgressList = computeTransferFileProgress(this.fileInfos, sentByFileId, this.fileProgressList);
  }

  // 接收完成兜底：将会话内全部文件按完整大小构造 sentByFileId，
  // 重建逐文件进度列表，使每个文件显示 100% 完成。
  // 背景：finishReceiveSession 在设置 pendingRecvCompleted 前同步移除了
  // activeProgress 中的进度条目，小文件瞬间完成时 perFileMaxSent 可能尚未被
  // 字节驱动路径填充，逐文件进度停留在 0%/waiting。此处以已确认的成功完成信号
  // 为凭据兜底，fileInfos 为空时自然生成空列表。
  private markAllFilesCompleted(): void {
    let sentByFileId: Record<string, number> = {};
    for (let i = 0; i < this.fileInfos.length; i++) {
      sentByFileId[this.fileInfos[i].fileId] = this.fileInfos[i].size;
    }
    this.fileProgressList = computeTransferFileProgress(this.fileInfos, sentByFileId, this.fileProgressList);
  }

  // 将进度条目解析为本次传输文件清单中的 fileId。
  // 仅按 fileId 精确匹配：fileId 为本次传输的唯一标识（UUID/时间戳），
  // 与 fileInfos 一一对应，可排除跨会话残留进度。
  private resolveProgressFileId(p: TransferProgress): string {
    let i = 0;
    for (i = 0; i < this.fileInfos.length; i++) {
      if (this.fileInfos[i].fileId === p.fileId) {
        return p.fileId;
      }
    }
    return '';
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
    // 仍在决策中（Idle）；若仅对 Transferring 状态处理取消，
    // 会静默丢弃它，导致页面停留在确认界面。
    // 取消优先于完成：发送方取消与最后文件进度事件
    // 存在竞态（两者可能同时挂起），此时应呈现"已取消"。
    let recvCancelled: string = peekRecvCancelled();
    if (!this.isSend && recvCancelled.length > 0) {
      logger.debug('recv cancelled, session=' + recvCancelled.substring(0, 8) + ' mySession=' +
        this.sessionId.substring(0, 8), { sessionId: recvCancelled, direction: 'recv' });
      if (recvCancelled !== this.sessionId) {
        // 来自其他会话的过期取消——消费它，以免其
        // 不阻塞进度更新，然后继续向下执行。
        logger.debug('consuming stale recvCancelled for session=' + recvCancelled.substring(0, 8));
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
    // 传输中断失败信号：连接断开/写入失败时，Rust 侧以
    // SessionEnd(Finished) 上报（文件未全部完成），ReceiveRepository
    // 据此置 pendingRecvFailed。处理方式与取消一致，但展示"传输失败"。
    let recvFailed: string = peekRecvFailed();
    if (!this.isSend && recvFailed.length > 0) {
      logger.debug('recv failed, session=' + recvFailed.substring(0, 8) + ' mySession=' +
        this.sessionId.substring(0, 8), { sessionId: recvFailed, direction: 'recv' });
      if (recvFailed !== this.sessionId) {
        // 来自其他会话的过期失败信号——消费它，以免其
        // 阻塞本会话的进度更新，然后继续向下执行。
        logger.debug('consuming stale recvFailed for session=' + recvFailed.substring(0, 8));
        consumeRecvFailed();
      } else {
        let wasTransferring: boolean = this.transferState === TransferState.Transferring;
        this.transferState = TransferState.Failed;
        this.errorMessage = this.recvFailedMessage();
        consumeRecvFailed();
        // 仅当传输已在进行时才自动关闭；当
        // 仍在等待确认，离开页面让用户看到
        // 失败反馈，可以手动返回。
        if (wasTransferring) {
          this.scheduleDismiss();
        }
        return;
      }
    }
    let recvCompleted: string = peekRecvCompleted();
    if (!this.isSend && recvCompleted.length > 0) {
      logger.debug('recv completed, session=' + recvCompleted.substring(0, 8) + ' mySession=' +
        this.sessionId.substring(0, 8), { sessionId: recvCompleted, direction: 'recv' });
      if (recvCompleted !== this.sessionId) {
        // 来自其他会话的过期完成——消费它，以免其
        // 阻塞本会话的进度更新，然后落到
        // 下方正常的进度计算。
        logger.debug('consuming stale recvCompleted for session=' + recvCompleted.substring(0, 8));
        consumeRecvCompleted();
      } else {
        // 防御竞态：finishReceiveSession 是异步函数，取消事件可能在
        // await exportSessionFiles 期间到达并已将 receiveSessionStates
        // 标记为 canceledBySender，但 pendingRecvCompleted 在异步
        // 完成后才被设置。此时必须丢弃已过期的完成信号。
        if (isRecvSessionCancelled(this.sessionId)) {
          logger.debug('recvCompleted arrived but session already cancelled, discarding');
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
              this.progressPercent = 100;
              this.transferState = TransferState.Completed;
              // 文本消息完成时同样将逐文件进度兜底为 100%（不依赖字节驱动路径）
              this.markAllFilesCompleted();
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
        // 完成信号分支提前 return，不走字节驱动重建路径；
        // 此处将逐文件进度兜底为 100%，避免小文件显示"0% + 已完成"的矛盾。
        this.markAllFilesCompleted();
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
            logger.error('failed to parse pendingRecvMediaFiles');
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
      logger.debug('skip, transferState=' + this.transferState + ' not Transferring');
      return;
    }
    let allProgress: Array<TransferProgress> = getActiveProgress();
    // 从当前活动进度条目更新单文件最大值跟踪器。
    // 以本次传输的文件清单为基准、按 fileId 精确匹配实际进度（fileId 为本次传输唯一标识，
    // 排除跨会话/历史残留条目），避免依赖 sessionId 前缀/会话一致性导致进度事件匹配失败。
    for (let i = 0; i < allProgress.length; i++) {
      let p: TransferProgress = allProgress[i];
      let fid: string = this.resolveProgressFileId(p);
      if (fid.length === 0) {
        continue;
      }
      let key: string = p.sessionId + ':' + fid;
      let prev: number | undefined = this.perFileMaxSent[key];
      if (prev === undefined || p.bytesSent > prev) {
        this.perFileMaxSent[key] = p.bytesSent;
      }
    }
    // 依据 perFileMaxSent 重建逐文件进度列表（供文件清单/进度条绑定）
    this.rebuildFileProgress();
    // 汇总所有单文件最大值作为总发送字节数（永不减少）
    let sentBytes: number = 0;
    let keys = Object.keys(this.perFileMaxSent);
    for (let i = 0; i < keys.length; i++) {
      sentBytes = sentBytes + this.perFileMaxSent[keys[i]];
    }
    logger.debug('active=' + allProgress.length + ' infos=' + this.fileInfos.length +
      ' info0=' + (this.fileInfos.length > 0 ? (this.fileInfos[0].fileId + '/' + this.fileInfos[0].fileName) : '') +
      ' perFileKeys=' + keys.length + ' fp0=' + (this.fileProgressList.length > 0 ?
      (Math.round(this.fileProgressList[0].percent) + '%/' + this.fileProgressList[0].status) : '') +
      ' sentBytes=' + sentBytes + ' totalSize=' + this.totalSize);
    // 发送侧和接收侧统一以 this.totalSize（所有文件之和）作为分母。
    // 从 activeProgress 动态累加 p.totalBytes 会导致分母偏小：
    // 小文件瞬间完成后大文件尚未开始，activeProgress 中只有小文件的条目，
    // 且已完成的文件条目也可能被移除，进而进度误判为 100%。
    let totalBytes: number = this.totalSize;
    if (totalBytes > 0) {
      let pct: number = (sentBytes * 100) / totalBytes;
      this.progressPercent = pct;
    }
    // ── 实时速度与预计剩余时间（滑动窗口差分，算子见 SpeedEstimator）──
    let now: number = Date.now();
    this.speedEstimator.update(sentBytes, now);
    // 降频同步到 @Trace 显示属性（约 1 秒一次），避免 UI 跳动
    if (now - this.lastDisplaySyncTime >= TransferViewModel.DISPLAY_SYNC_INTERVAL) {
      let speed: number = this.speedEstimator.getSpeed();
      // 速度不可用（窗口数据不足/覆盖灌充期）或已过期（字节长时间无增量）：回退占位符
      if (speed <= 0 || this.speedEstimator.isStale(now, TransferViewModel.SPEED_STALE_MS)) {
        this.displaySpeed = 0;
        this.displayEta = -1;
      } else {
        this.displaySpeed = speed;
        this.displayEta = this.speedEstimator.etaSeconds(totalBytes, sentBytes);
      }
      this.lastDisplaySyncTime = now;
    }
    // 仅检查接收侧的完成状态。
    // 发送侧，完成状态由 startSendTransfer() 中的 sendToDevice promise 决定，
    // 这是所有文件已完全传输的可靠信号。
    if (!this.isSend && sentBytes >= totalBytes && totalBytes > 0) {
      // 防御竞态：取消/失败事件可能在 perFileMaxSent 已达 100% 后到达，
      // 但 peekRecvCancelled/peekRecvFailed 尚未被消费。字节计数不能覆盖取消/失败判定。
      if (isRecvSessionCancelled(this.sessionId) || isRecvSessionFailed(this.sessionId)) {
        logger.debug('byte-count complete but session cancelled/failed, setting Failed');
        this.transferState = TransferState.Failed;
        this.errorMessage = isRecvSessionCancelled(this.sessionId) ?
          this.recvCancelledMessage() : this.recvFailedMessage();
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
          logger.error('failed to parse pendingRecvMediaFiles (byte-count path)');
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
      logger.debug('skipped, autoFinish disabled');
      return;
    }
    logger.debug('called, dismissed=' + (this.dismissed ? 'true' : 'false'));
    this.dismissTimer = setTimeout(() => {
      logger.debug('timer fired, dismissed=' + (this.dismissed ? 'true' : 'false'));
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
      logger.debug('clearing dismissTimer');
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
  }

  onConfirm(): void {
    logger.debug('called, transferState=' + this.transferState);
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

  // 取消的业务部分（原生中断 + 状态）。导航由
  // 本函数返回后的视图包装。
  onCancel(): void {
    logger.debug(
      'ENTER mode=' + (this.isSend ? 'send' : 'receive') + ' state=' + this.transferState + ' dismissed=' +
        (this.dismissed ? 'true' : 'false'));
    this.dismissed = true;
    if (this.dismissTimer >= 0) {
      logger.debug('clearing dismissTimer');
      clearTimeout(this.dismissTimer);
      this.dismissTimer = -1;
    }
    if (this.autoConfirmTimer >= 0) {
      logger.debug('clearing autoConfirmTimer');
      clearTimeout(this.autoConfirmTimer);
      this.autoConfirmTimer = -1;
    }
    if (this.transferState === TransferState.Idle) {
      logger.debug('Idle path');
      if (!this.isSend && this.sessionId.length > 0) {
        respondToRequest(this.sessionId, false);
      }
    } else if (this.transferState === TransferState.Transferring) {
      if (this.isSend) {
        // 发送侧取消：先触发本地 CancellationToken 中断进行中的上传，
        // 再向接收方发送 /cancel 请求通知远端。
        let cancelSessionId: string = nativeGetCurrentSendSessionId();
        logger.debug(
          'send cancel, session=' + cancelSessionId.substring(0, 8) + ' target=' + this.targetIp + ':' +
            this.targetPort, { sessionId: cancelSessionId, direction: 'send', targetAlias: this.targetAlias });
        // 本地取消：触发 CancellationToken，立即中断 send_files 循环和进行中的 HTTP 上传
        nativeCancelTransferLocal(cancelSessionId);
        logger.debug('local cancel triggered for session=' + cancelSessionId.substring(0, 8),
          { sessionId: cancelSessionId, direction: 'send' });
        // 远程取消：通知接收方清理会话
        let cancelTarget: NativeCancelTarget = {
          ip: this.targetIp,
          port: this.targetPort,
          fingerprint: this.targetFingerprint,
          protocol: this.targetProtocol
        };
        nativeCancelTransfer(cancelTarget, cancelSessionId).then(() => {
          logger.debug('remote cancel done', { sessionId: cancelSessionId, direction: 'send' });
        }).catch((e: Object) => {
          logger.warn('remote cancel failed: ' + JSON.stringify(e));
        });
      } else if (this.sessionId.length > 0) {
        nativeCancelLocalSession(this.sessionId).then(() => {
          logger.debug('local session cancelled', { sessionId: this.sessionId, direction: 'recv' });
        }).catch((e: Object) => {
          logger.warn('local cancel failed: ' + JSON.stringify(e));
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
        'timer fired, state=' + this.transferState + ' dismissed=' + (this.dismissed ? 'true' : 'false'));
      this.onConfirm();
    }, 300);
  }

  // 剪贴板接收流程会在加载后不久自动接收请求。
  scheduleClipboardAccept(): void {
    setTimeout(() => {
      respondToRequest(this.sessionId, true, this.acceptedFileIds);
      this.transferState = TransferState.Transferring;
      this.displaySpeed = 0;
      this.displayEta = -1;
      this.speedEstimator.reset();
      this.lastDisplaySyncTime = 0;
    }, 100);
  }

  async startSendTransfer(): Promise<void> {
    logger.debug('begin, uriCount=' + this.fileUris.length,
      { direction: 'send', targetAlias: this.targetAlias });
    clearSendProgress();
    this.perFileMaxSent = {};
    this.progressPercent = 0;
    this.displaySpeed = 0;
    this.displayEta = -1;
    this.speedEstimator.reset();
    this.lastDisplaySyncTime = 0;
    try {
      // 优先消费主页面预准备的文件（已含校验和与手动文本条目的 preview），避免重复 prepareSendFiles
      let items: Array<SendFileItem> | undefined = consumePrePreparedItems();
      if (items !== undefined && items.length > 0) {
        logger.debug('using pre-prepared items, count=' + items.length);
      } else {
        // 回退：无预准备缓存时自行准备（如深链接直接进入 TransferPage）。
        // 不传入手动文本来源，故此处不补设 preview——文本消息准备职责归位于
        // 发送页的预准备路径与共享准备层，本页不再单独维护补设实现。
        items = await prepareSendFiles(this.fileUris);
        logger.debug(
          'prepareSendFiles returned, dismissed=' + (this.dismissed ? 'true' : 'false') +
            ' items=' + items.length);
        if (this.dismissed) {
          logger.debug('dismissed after prepareSendFiles, aborting');
          return;
        }
        if (items.length === 0) {
          logger.debug('no items prepared, fail');
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
        logger.debug('isTextSend, calling sendToDevice...');
        let result = await sendToDevice(targetDevice, items).catch((e: Error): SendResult => {
          return { success: false, error: { kind: 'other', message: String(e) } };
        });
        logger.debug(
          'isTextSend sendToDevice returned, success=' + (result.success ? 'true' : 'false') +
            ' dismissed=' + (this.dismissed ? 'true' : 'false'));
        // 单文件发送不创建 sendSession，终态延迟清理机制失效，需在返回后立即清理该会话进度条目。
        // 位于 dismissed 早退判断之前，确保取消且页面已关闭的场景同样被覆盖。
        if (result.sessionId !== undefined && result.sessionId.length > 0) {
          removeProgressForSession(result.sessionId);
        }
        // 失败/取消不清理 send/ 目录：fd 直读改造后该目录仅存手动文本暂存文件
        // （stagedFiles 直接引用其路径），删除会让暂存列表成为僵尸条目、重试无法
        // 重新打开文件。成功路径由 markSendCompleted 统一清理。
        if (this.dismissed) {
          logger.debug('isTextSend dismissed after sendToDevice, aborting');
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
      logger.debug('calling sendToDevice for files...');
      let result = await sendToDevice(targetDevice, items);
      logger.debug(
        'sendToDevice returned, success=' + (result.success ? 'true' : 'false') + ' dismissed=' +
          (this.dismissed ? 'true' : 'false'));
      // 单文件发送不创建 sendSession，终态延迟清理机制失效，需在返回后立即清理该会话进度条目。
      // 位于 dismissed 早退判断之前，确保取消且页面已关闭的场景同样被覆盖。
      if (result.sessionId !== undefined && result.sessionId.length > 0) {
        removeProgressForSession(result.sessionId);
      }
      // 失败/取消不清理 send/ 目录（见 isTextSend 分支注释）；成功由 markSendCompleted 清理。
      if (this.dismissed) {
        logger.debug('dismissed after sendToDevice, aborting');
        return;
      }
      if (result.success) {
        logger.debug('complete, setting 100%',
          { direction: 'send', targetAlias: this.targetAlias });
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
        'exception: ' + String(_e) + ' dismissed=' + (this.dismissed ? 'true' : 'false'),
        { direction: 'send', targetAlias: this.targetAlias });
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
        'alreadyAccepted, skipping respond, session=' + this.sessionId.substring(0, 8));
      return;
    }
    if (accept) {
      respondToRequest(this.sessionId, true, this.acceptedFileIds);
    } else {
      respondToRequest(this.sessionId, false);
    }
  }

  private defaultSendFailedMessage(): string {
    return getStringSyncFromContext(this.context, $r('app.string.send_failed_prefix'));
  }

  private recvCancelledMessage(): string {
    return getStringSyncFromContext(this.context, $r('app.string.recv_cancelled_message'));
  }

  private recvFailedMessage(): string {
    return getStringSyncFromContext(this.context, $r('app.string.transfer_failed'));
  }

  private defaultSendErrorPrefix(): string {
    return getStringSyncFromContext(this.context, $r('app.string.send_error_prefix'));
  }

  // ── 相册保存弹窗方法 ──

  shouldShowGalleryDialog(): boolean {
    return this.galleryDialogVisible && this.pendingMediaFiles.length > 0;
  }

  onGalleryDialogDismiss(): void {
    logger.debug('called');
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
    logger.debug('success=' + result.successCount + ' fail=' + result.failCount);
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

  // 相册保存数据层操作（SaveToGalleryDialog 经 onPerformSave 上抛调用）。
  async performGallerySave(mediaFiles: Array<MediaFileInfo>): Promise<GallerySaveResult> {
    if (this.context === undefined) {
      return { successCount: 0, failCount: mediaFiles.length, errors: ['no context'] };
    }
    return saveMediaToGallery(this.context, mediaFiles);
  }
}
