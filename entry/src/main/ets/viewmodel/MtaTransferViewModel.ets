/**
 * MtaTransferViewModel.ets — MTA 专用传输页视图模型
 *
 * 支持 send / receive 两种模式：
 * - send：持有 MtaSendService，映射发送页暂存文件与目标 MTA 设备，
 *   驱动会话级阶段/进度/结果，取消与清理；发送期间经仓储暂停 MTA 接收服务。
 * - receive：订阅 MtaRepository 的接收状态快照，展示发送方/文件信息、
 *   接受/拒绝/取消下载与进度。
 *
 * 采用 V2 状态管理（@ObservedV2 + @Trace），状态整体替换/字段更新驱动刷新。
 */

import { common } from '@kit.AbilityKit';
import { MtaSendService } from '../service/mta/MtaSendService';
import {
  MtaSendEventHandlers,
  MtaSendFile,
  MtaSenderStage,
  SenderState,
  bandLabelFromFrequency,
  isWeakBand
} from '../model/mta/MtaSendModels';
import { ReceivedFileEntry, ReceiverStage } from '../model/mta/MtaProtocolModels';
import { GallerySaveResult, MediaFileInfo, TransferFileDescriptor } from '../model/Types';
import {
  MTA_MODE_RECEIVE,
  MTA_MODE_SEND,
  MTA_RECEIVE_SAVING_TEXT,
  MtaTransferPageParams,
  mtaDeviceFromParams,
  mtaReceiveStageLabel,
  mtaSendStageLabel
} from '../model/mta/MtaMainModels';
import {
  acceptMtaReceiveRequest,
  cancelMtaReceive,
  getMtaReceiveSnapshot,
  getMtaSendClickedMs,
  rejectMtaReceiveRequest,
  resumeMtaReceiveAfterSend,
  stopMtaDiscoveryScan,
  subscribe,
  suspendMtaReceiveForSend,
  unsubscribe,
  saveMediaToGallery,
  updateGallerySavedStatus
} from '../service/AppService';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { SpeedEstimator } from '../utils/SpeedEstimator';
import { formatDuration, formatSpeed } from '../utils/FormatUtil';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaTransferVM', '互传传输');

// 传输页展示层类型经 ViewModel 出口（View 层不直接 import model/mta）。
export { MtaTransferPageParams, MTA_MODE_SEND, MTA_MODE_RECEIVE } from '../model/mta/MtaMainModels';
// 进度/阶段文案标签经 ViewModel 出口（同上）
export {
  MTA_RECEIVE_SAVING_TEXT,
  MTA_PROGRESS_PROCESSED_LABEL,
  MTA_PROGRESS_TOTAL_LABEL
} from '../model/mta/MtaMainModels';
export { ReceivedFileEntry } from '../model/mta/MtaProtocolModels';
// 相册保存弹窗展示层类型经 ViewModel 出口
export { MediaFileInfo, GallerySaveResult } from '../model/Types';

/** MTA 专用传输页视图模型 */
@ObservedV2
export class MtaTransferViewModel {
  /** 模式：send / receive */
  @Trace public mode: string = MTA_MODE_SEND
  // ── 对端展示 ──
  @Trace public targetAlias: string = ''
  @Trace public deviceType: string = 'mobile'
  @Trace public deviceModel: string = ''
  @Trace public badgeText: string = ''
  // 待发送文件清单（发送文件模式用于渲染文件列表；文本发送时为空数组）
  @Trace public files: Array<TransferFileDescriptor> = []
  // ── 会话级状态 ──
  @Trace public stageText: string = ''
  @Trace public progressPercent: number = 0
  @Trace public currentBytes: number = 0
  @Trace public totalBytes: number = 0
  /** 网络字节累计（网络口径，速率采样用；不直接展示） */
  private networkBytes: number = 0
  @Trace public currentFileName: string = ''
  @Trace public errorMessage: string = ''
  @Trace public isSending: boolean = false
  @Trace public finished: boolean = false
  // ── 接收模式状态 ──
  @Trace public isReceiving: boolean = false
  @Trace public awaitingConfirm: boolean = false
  @Trace public requestSender: string = ''
  @Trace public requestFileName: string = ''
  @Trace public requestFileCount: number = 0
  @Trace public requestTotalSize: number = 0
  @Trace public receivedText: string = ''
  @Trace public receiveCompleted: boolean = false
  // 已接收文件条目（文件名 + 大小，来自接收状态快照，完成后用于渲染文件列表）
  @Trace public receivedFiles: Array<ReceivedFileEntry> = []
  // 完成结果记忆：会话重置后仍持续展示结果与文件列表，新的接收请求到来时清理
  @Trace public completedSticky: boolean = false
  @Trace public completedFiles: Array<ReceivedFileEntry> = []
  @Trace public completedText: string = ''
  // ── 相册保存（接收完成后按「保存到相册」设置展示保存弹窗）──
  @Trace public pendingMediaFiles: Array<MediaFileInfo> = []
  @Trace public galleryDialogVisible: boolean = false
  // 相册保存所需的应用上下文（接收态载入时注入）
  private galleryContext: common.UIAbilityContext | undefined = undefined
  // 当前接收任务的 taskId（用作接收历史 id 前缀，回写已保存标记）
  private receiveSessionId: string = ''
  // ── 实时速度与剩余时间（格式化文案，非字节传输阶段回退为 '--'）──
  @Trace public speedText: string = '--'
  @Trace public etaText: string = '--'
  // ── 实际连接频段（发送端建组后 / 接收端连接后展示）与 2.4GHz 受限提示 ──
  @Trace public bandText: string = ''
  @Trace public bandWarning: string = ''

  private sendService: MtaSendService | undefined = undefined
  private sendHandlers: MtaSendEventHandlers = new MtaSendEventHandlers()
  /** 发送建链计时起点（进入发送页并开始发送流程的时刻） */
  private linkStartMs: number = 0
  /** 发送端到端建链总耗时是否已记录（仅记录一次） */
  private linkTotalLogged: boolean = false
  private receiveSubscribed: boolean = false
  // 速度采样估算器与显示降频同步时间戳（约 1 秒同步一次，避免跳动）。
  private speedEstimator: SpeedEstimator = new SpeedEstimator()
  private lastDisplaySyncTime: number = 0
  // 显示同步间隔与速度过期阈值（毫秒）。
  private static readonly DISPLAY_SYNC_INTERVAL: number = 1000
  private static readonly SPEED_STALE_MS: number = 3000
  /** 接收态页面关闭回调（页面注入；拒绝后触发以自动退出页面） */
  private closeCallback: (() => void) | null = null
  /** 拒绝是否已触发（幂等：避免重复点击造成重复回送与多次导航） */
  private rejectFired: boolean = false
  // 订阅回调需保持同一引用以便退订
  private appChangeCallback: () => void = (): void => {
    this.applyReceiveSnapshot();
  }

  // ── send 模式 ──

  /**
   * 载入发送会话：绑定发送服务事件、暂停接收服务、发起发送。
   * 发送页已在导航前校验暂存内容非空与发送占用。
   */
  async loadSend(params: MtaTransferPageParams, context: common.Context): Promise<void> {
    // 计时起点优先取「点击设备」时刻（发送页点击入口已记录），缺失时退化为进入发送页时刻
    let clickedMs = getMtaSendClickedMs();
    this.linkStartMs = clickedMs > 0 ? clickedMs : Date.now();
    this.linkTotalLogged = false;
    this.mode = MTA_MODE_SEND;
    this.targetAlias = params.targetAlias;
    this.deviceType = params.deviceType;
    this.deviceModel = params.deviceModel;
    this.badgeText = params.badgeText;
    this.files = params.isTextSend ? [] : params.fileDescriptors;
    this.stageText = mtaSendStageLabel(MtaSenderStage.IDLE);
    this.isSending = true;
    this.finished = false;
    this.errorMessage = '';
    this.progressPercent = 0;
    this.currentBytes = 0;
    this.totalBytes = 0;
    this.resetSpeedTracking();

    // 纵深防御：空内容会使 sendToDevice 早期返回并跳过会话终态回调，
    // 导致 MTA 接收服务永久停摆，故在暂停接收服务前再校验一次
    let hasContent = params.isTextSend ? params.textContent.length > 0 : params.fileUris.length > 0;
    if (!hasContent) {
      this.isSending = false;
      this.finished = true;
      this.errorMessage = '无可发送内容';
      return;
    }

    let service = new MtaSendService();
    this.sendService = service;
    this.sendHandlers.onStateChange = (state: SenderState): void => {
      this.applySenderState(state);
    };
    service.setEventHandlers(this.sendHandlers);
    // 会话终态（完成/失败/取消）经回调恢复 MTA 接收服务
    service.setSessionEndListener((): void => {
      this.onSessionEnded();
    });
    service.init(context);

    // 收发互斥：发送前停止发现扫描并暂停接收服务
    stopMtaDiscoveryScan();
    await suspendMtaReceiveForSend();
    logger.debug(`发送页准备耗时=${Date.now() - this.linkStartMs}ms（停扫描+暂停接收服务）`);

    let files = this.buildSendFiles(params);
    let text = params.isTextSend ? params.textContent : '';
    let device = mtaDeviceFromParams(params);
    await service.sendToDevice(device, files, false, text);
  }

  /** 映射页面参数中的文件清单为发送服务入参 */
  private buildSendFiles(params: MtaTransferPageParams): Array<MtaSendFile> {
    let files: Array<MtaSendFile> = [];
    if (params.isTextSend) {
      // 文本发送经 sendToDevice 文本入参附加共享文本条目
      return files;
    }
    for (let i = 0; i < params.fileUris.length; i++) {
      let file = new MtaSendFile();
      file.uri = params.fileUris[i];
      if (i < params.fileDescriptors.length) {
        let descriptor = params.fileDescriptors[i];
        file.displayName = descriptor.fileName.length > 0 ? descriptor.fileName :
          this.fileNameFromUri(params.fileUris[i], i);
        file.sizeBytes = descriptor.size;
      } else {
        file.displayName = this.fileNameFromUri(params.fileUris[i], i);
      }
      files.push(file);
    }
    return files;
  }

  /** 从 URI 末段解析显示文件名 */
  private fileNameFromUri(uri: string, fallbackIndex: number): string {
    let name = uri;
    let slash = uri.lastIndexOf('/');
    if (slash >= 0 && slash < uri.length - 1) {
      name = uri.substring(slash + 1);
    }
    try {
      name = decodeURIComponent(name);
    } catch (_e) {
    }
    return name.length > 0 ? name : `file_${fallbackIndex}`;
  }

  /** 应用发送状态快照 */
  private applySenderState(state: SenderState): void {
    // 对端开始下载即"开始传输"：记录一次端到端建链总耗时（含页面准备与各握手阶段）
    if (!this.linkTotalLogged && state.stage === MtaSenderStage.TRANSFERRING) {
      this.linkTotalLogged = true;
      logger.debug(`端到端建链总耗时=${Date.now() - this.linkStartMs}ms（点击设备→对端开始下载）`);
    }
    this.stageText = mtaSendStageLabel(state.stage);
    this.progressPercent = state.progress.percent;
    this.currentBytes = state.progress.sentBytes;
    // 进度全程使用"已读源字节 / 声明原始总大小"口径（与原生对端口径一致）；
    // 原始文件总大小同时由页面文件汇总区单独展示。
    // 速率另取网络字节口径（出网字节），压缩生效时与进度分子不同。
    this.networkBytes = state.progress.networkBytes;
    this.totalBytes = state.progress.totalBytes;
    this.currentFileName = state.currentFileName;
    this.errorMessage = state.lastError;
    // 频段文案：建组完成后由会话实际频点派生（未建组或频点未知时不展示）
    let session = state.session;
    this.applyBandText(state.groupCreated, session !== undefined ? session.groupFrequency : 0);
    // 实时速度与剩余时间：仅字节传输阶段采样，其余阶段回退占位符
    if (state.stage === MtaSenderStage.TRANSFERRING) {
      this.updateSpeedDisplay();
    } else {
      this.clearSpeedDisplay();
    }
    if (state.stage === MtaSenderStage.COMPLETED || state.stage === MtaSenderStage.PARTIAL ||
      state.stage === MtaSenderStage.FAILED || state.stage === MtaSenderStage.CANCELLED) {
      this.finished = true;
      this.isSending = false;
    }
  }

  /** 由「是否已知连接频段 + 实际频点」派生频段文案与 2.4GHz 受限提示 */
  private applyBandText(known: boolean, freqMhz: number): void {
    if (!known) {
      this.bandText = '';
      this.bandWarning = '';
      return;
    }
    this.bandText = `频段：${bandLabelFromFrequency(freqMhz)}`;
    this.bandWarning = isWeakBand(freqMhz) ? '2.4GHz 频段下速度可能受限' : '';
  }

  /** 会话结束：按开关恢复 MTA 接收服务 */
  private onSessionEnded(): void {
    this.isSending = false;
    this.resetSpeedTracking();
    resumeMtaReceiveAfterSend().catch((e: Object): void => {
      logger.warn('恢复 MTA 接收服务异常: ' + String(e));
    });
  }

  // ── 实时速度与剩余时间 ──

  /** 采样一次进度并降频同步速度/剩余时间显示（仅字节传输阶段调用）。 */
  private updateSpeedDisplay(): void {
    let now: number = Date.now();
    // 速率采样取网络字节（出网/网络读入），与进度分子（有效数据）分开
    this.speedEstimator.update(this.networkBytes, now);
    if (now - this.lastDisplaySyncTime < MtaTransferViewModel.DISPLAY_SYNC_INTERVAL) {
      return;
    }
    this.lastDisplaySyncTime = now;
    // 字节长时间无增量：速度已过期，回退占位符
    if (this.speedEstimator.isStale(now, MtaTransferViewModel.SPEED_STALE_MS)) {
      this.speedText = '--';
      this.etaText = '--';
      return;
    }
    let speed: number = this.speedEstimator.getSpeed();
    this.speedText = speed > 0 ? formatSpeed(speed) : '--';
    // 总字节未知（为 0）时剩余时间不可计算
    this.etaText = this.totalBytes > 0 ?
      formatDuration(this.estimateEtaSeconds()) : '--';
  }

  /**
   * 剩余时间（秒）：压缩使网络字节与有效数据字节分离，先把剩余有效数据按已观测压缩比
   * 折算为剩余网络字节，再按网络速率估算；压缩比未观测到时（分子或网络字节为 0）按 1 处理。
   */
  private estimateEtaSeconds(): number {
    let remaining: number = this.totalBytes - this.currentBytes;
    if (remaining <= 0) {
      return 0;
    }
    let ratio: number = this.currentBytes > 0 && this.networkBytes > 0 ?
      this.networkBytes / this.currentBytes : 1;
    let networkTotal: number = this.networkBytes + Math.round(remaining * ratio);
    return this.speedEstimator.etaSeconds(networkTotal, this.networkBytes);
  }

  /** 清空速度/剩余时间显示为占位符（非字节传输阶段调用）。 */
  private clearSpeedDisplay(): void {
    this.speedText = '--';
    this.etaText = '--';
    this.lastDisplaySyncTime = 0;
  }

  /** 复位速度采样与显示（新会话开始或会话结束时调用）。 */
  private resetSpeedTracking(): void {
    this.speedEstimator.reset();
    this.networkBytes = 0;
    this.clearSpeedDisplay();
  }

  /** 取消进行中的发送 */
  async cancel(): Promise<void> {
    let service = this.sendService;
    if (service !== undefined) {
      await service.cancelSend();
    }
  }

  // ── receive 模式 ──

  /** 载入接收会话：读取仓储接收快照并订阅其状态变化 */
  loadReceive(context: common.UIAbilityContext): void {
    this.mode = MTA_MODE_RECEIVE;
    this.galleryContext = context;
    this.applyReceiveSnapshot();
    if (!this.receiveSubscribed) {
      subscribe(this.appChangeCallback);
      this.receiveSubscribed = true;
    }
  }

  /** 从仓储接收快照同步页面状态 */
  private applyReceiveSnapshot(): void {
    let snapshot = getMtaReceiveSnapshot();
    // 新的接收请求到来：清除上一次完成结果的记忆，随后按新请求正常同步
    if (snapshot.stage === ReceiverStage.REQUEST_RECEIVED) {
      this.completedSticky = false;
      this.completedFiles = [];
      this.completedText = '';
      // 新的接收请求：复位上一次会话的相册保存状态，避免残留媒体泄漏到新会话
      this.pendingMediaFiles = [];
      this.galleryDialogVisible = false;
      // 新的接收请求：复位上一次会话的速度采样，避免残留速度泄漏
      this.resetSpeedTracking();
    } else if (this.completedSticky) {
      // 已处于完成记忆态：冻结完成态展示（结果文案、文件列表、进度条与阶段/字节文案），
      // 忽略接收服务会话重置造成的回退，直到新请求到来或页面销毁
      return;
    }

    // 网络数据已全部收完、仍在解压/落盘：阶段文案切换为「解压/保存中」
    //（此时网络速率自然衰减，不会呈现异常高速率）
    let decompressingOrSaving: boolean = snapshot.stage === ReceiverStage.DOWNLOADING &&
      snapshot.progress.networkDone;
    this.stageText = decompressingOrSaving ? MTA_RECEIVE_SAVING_TEXT : mtaReceiveStageLabel(snapshot.stage);
    this.progressPercent = snapshot.progress.percent;
    this.currentBytes = snapshot.progress.receivedBytes;
    // 速率取网络读入字节口径（压缩生效时与已解压字节不同）
    this.networkBytes = snapshot.progress.netBytes;
    this.totalBytes = snapshot.progress.totalBytes;
    // 实时速度与剩余时间：下载（边收边解压）阶段采样，其余阶段（等待确认/落盘等）回退占位符
    if (snapshot.stage === ReceiverStage.DOWNLOADING) {
      this.updateSpeedDisplay();
    } else {
      this.clearSpeedDisplay();
    }
    this.errorMessage = snapshot.lastError;
    // 频段文案：连接建立后由对端群组实际频点派生（未连接时不展示，频点未知时仅展示标签）
    this.applyBandText(snapshot.goIpAddress.length > 0, snapshot.groupFrequency);
    let request = snapshot.receiveRequest;
    if (request !== undefined) {
      this.receiveSessionId = request.taskId;
      this.requestSender = request.senderName;
      this.requestFileName = request.fileName;
      this.requestFileCount = request.fileCount;
      this.requestTotalSize = request.totalSize;
      // 设备卡展示字段：协议仅提供发送方名称，型号/品牌缺失时降级为默认移动端图标与空徽标
      this.targetAlias = request.senderName;
      this.deviceType = 'mobile';
      this.deviceModel = '';
      this.badgeText = '';
      if (request.textContent.length > 0) {
        this.receivedText = request.textContent;
      }
    }
    this.awaitingConfirm = snapshot.stage === ReceiverStage.REQUEST_RECEIVED && request !== undefined;
    this.isReceiving = snapshot.stage === ReceiverStage.DOWNLOADING || snapshot.stage === ReceiverStage.SAVING;
    this.receiveCompleted = snapshot.stage === ReceiverStage.COMPLETED;
    this.receivedFiles = snapshot.receivedFiles;
    this.finished = this.receiveCompleted || snapshot.stage === ReceiverStage.FAILED;
    // 接收完成且存在待保存媒体：展示相册保存弹窗（弹窗可见期间不重复触发）
    if (snapshot.pendingMediaFiles.length > 0 && !this.galleryDialogVisible) {
      this.pendingMediaFiles = snapshot.pendingMediaFiles.slice();
      this.galleryDialogVisible = true;
    }

    // 本次接收完成或失败：首次进入记忆态并缓存结果，使结果不随会话重置而消失
    if (!this.completedSticky &&
      (snapshot.stage === ReceiverStage.COMPLETED || snapshot.stage === ReceiverStage.FAILED)) {
      this.completedSticky = true;
      // 失败不保留文件条目，避免展示半成品/残留文件
      this.completedFiles = snapshot.stage === ReceiverStage.COMPLETED ? snapshot.receivedFiles.slice() : [];
      this.completedText = snapshot.stage === ReceiverStage.FAILED ? snapshot.lastError : '';
    }
  }

  /** 注入接收态页面关闭回调（页面在 aboutToAppear 注入），并重置拒绝幂等标志 */
  setCloseCallback(callback: () => void): void {
    this.closeCallback = callback;
    this.rejectFired = false;
  }

  /** 接受接收请求 */
  acceptRequest(): void {
    acceptMtaReceiveRequest();
  }

  /** 拒绝接收请求：幂等触发一次拒绝与页面关闭回调，实现自动退出 */
  rejectRequest(): void {
    if (this.rejectFired) {
      return;
    }
    this.rejectFired = true;
    rejectMtaReceiveRequest();
    this.fireCloseCallback();
  }

  /** 触发页面关闭回调（未注入时为空操作） */
  private fireCloseCallback(): void {
    if (this.closeCallback === null) {
      return;
    }
    this.closeCallback();
  }

  /** 取消进行中的接收下载 */
  cancelReceive(): void {
    cancelMtaReceive();
  }

  // ── 相册保存（复用局域网一致的保存弹窗与安全控件） ──

  /** 用户跳过保存：关闭弹窗并清空待保存媒体 */
  onGalleryDialogDismiss(): void {
    this.galleryDialogVisible = false;
    this.pendingMediaFiles = [];
  }

  /** 保存完成：关闭弹窗，成功时将本次接收历史标记为已保存 */
  onGallerySaveComplete(result: GallerySaveResult): void {
    this.pendingMediaFiles = [];
    this.galleryDialogVisible = false;
    if (result.successCount > 0 && this.receiveSessionId.length > 0) {
      updateGallerySavedStatus(this.receiveSessionId, true);
    }
  }

  /** 相册保存数据层操作（SaveToGalleryDialog 经 onPerformSave 上抛调用） */
  async performGallerySave(mediaFiles: Array<MediaFileInfo>): Promise<GallerySaveResult> {
    if (this.galleryContext === undefined) {
      return { successCount: 0, failCount: mediaFiles.length, errors: ['no context'] };
    }
    return saveMediaToGallery(this.galleryContext, mediaFiles);
  }

  /** 页面退出时释放资源（进行中的发送会被取消并恢复接收服务） */
  destroy(): void {
    this.resetSpeedTracking();
    if (this.receiveSubscribed) {
      unsubscribe(this.appChangeCallback);
      this.receiveSubscribed = false;
    }
    let service = this.sendService;
    this.sendService = undefined;
    if (service !== undefined) {
      service.destroy();
    }
  }
}
