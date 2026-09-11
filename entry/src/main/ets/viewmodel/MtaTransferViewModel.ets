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
  SenderState
} from '../model/mta/MtaSendModels';
import { ReceivedFileEntry, ReceiverLogEntry, ReceiverStage } from '../model/mta/MtaReceiveModels';
import { TransferFileDescriptor } from '../model/Types';
import {
  MTA_MODE_RECEIVE,
  MTA_MODE_SEND,
  MtaTransferPageParams,
  mtaDeviceFromParams,
  mtaReceiveStageLabel,
  mtaSendStageLabel
} from '../model/mta/MtaMainModels';
import {
  acceptMtaReceiveRequest,
  cancelMtaReceive,
  getMtaReceiveSnapshot,
  rejectMtaReceiveRequest,
  resumeMtaReceiveAfterSend,
  stopMtaDiscoveryScan,
  subscribe,
  suspendMtaReceiveForSend,
  unsubscribe
} from '../service/AppService';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaTransferVM', '互传传输');

// 传输页展示层类型经 ViewModel 出口（View 层不直接 import model/mta）。
export { MtaTransferPageParams, MTA_MODE_SEND, MTA_MODE_RECEIVE } from '../model/mta/MtaMainModels';
export { ReceivedFileEntry } from '../model/mta/MtaReceiveModels';

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

  private sendService: MtaSendService | undefined = undefined
  private sendHandlers: MtaSendEventHandlers = new MtaSendEventHandlers()
  private receiveSubscribed: boolean = false
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
    this.sendHandlers.onLog = (entry: ReceiverLogEntry): void => {
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
    this.stageText = mtaSendStageLabel(state.stage);
    this.progressPercent = state.progress.percent;
    this.currentBytes = state.progress.sentBytes;
    let total = state.progress.totalBytes;
    if (total <= 0 && state.session !== undefined) {
      total = state.session.totalBytes;
    }
    this.totalBytes = total;
    this.currentFileName = state.currentFileName;
    this.errorMessage = state.lastError;
    if (state.stage === MtaSenderStage.COMPLETED || state.stage === MtaSenderStage.FAILED ||
      state.stage === MtaSenderStage.CANCELLED) {
      this.finished = true;
      this.isSending = false;
    }
  }

  /** 会话结束：按开关恢复 MTA 接收服务 */
  private onSessionEnded(): void {
    this.isSending = false;
    resumeMtaReceiveAfterSend().catch((e: Object): void => {
      logger.warn('恢复 MTA 接收服务异常: ' + String(e));
    });
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
  loadReceive(): void {
    this.mode = MTA_MODE_RECEIVE;
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
    } else if (this.completedSticky) {
      // 已处于完成记忆态：冻结完成态展示（结果文案、文件列表、进度条与阶段/字节文案），
      // 忽略接收服务会话重置造成的回退，直到新请求到来或页面销毁
      return;
    }

    this.stageText = mtaReceiveStageLabel(snapshot.stage);
    this.progressPercent = snapshot.progress.percent;
    this.currentBytes = snapshot.progress.receivedBytes;
    this.totalBytes = snapshot.progress.totalBytes;
    this.errorMessage = snapshot.lastError;
    let request = snapshot.receiveRequest;
    if (request !== undefined) {
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

  /** 页面退出时释放资源（进行中的发送会被取消并恢复接收服务） */
  destroy(): void {
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
