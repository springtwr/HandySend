/**
 * MtaReceiveViewModel.ets — MTA 接收调试页视图模型
 *
 * 持有页面可观察状态（接收状态快照、日志流、设备名输入），
 * 绑定 MtaReceiveService 的事件回调并把用户命令转发给服务。
 * 采用 V2 状态管理（@ObservedV2 + @Trace），状态快照整体替换以触发刷新。
 */

import { common } from '@kit.AbilityKit';
import { MtaReceiveService } from '../service/mta/MtaReceiveService';
import {
  MtaReceiveEventHandlers,
  ReceiverLogEntry,
  ReceiverStage,
  ReceiverState,
  ReceiveRequest,
  formatBytes,
  receiverStageText
} from '../model/mta/MtaReceiveModels';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.NETWORK, 'HandySend:MtaReceiveVM');

/** 接收端调试页视图模型 */
@ObservedV2
export class MtaReceiveViewModel {
  /** 接收端状态快照 */
  @Trace public state: ReceiverState = new ReceiverState()
  /** 日志流 */
  @Trace public logs: Array<ReceiverLogEntry> = []
  /** 广播设备名输入 */
  @Trace public deviceNameInput: string = 'HandySend'
  /** 命令是否执行中（防抖） */
  @Trace public isBusy: boolean = false
  /** 收到新接收请求时的回调（由页面注入，用于弹出确认框） */
  onNewRequest: (request: ReceiveRequest) => void = (request: ReceiveRequest): void => {
  }

  private service: MtaReceiveService = new MtaReceiveService();
  private handlers: MtaReceiveEventHandlers = new MtaReceiveEventHandlers();
  /** 上一次阶段（用于识别进入「待确认」的跃迁，taskId 可能为空时也能触发弹框） */
  private lastStage: ReceiverStage = ReceiverStage.IDLE;

  // ── 生命周期 ──

  /** 页面 aboutToAppear：绑定事件并注入上下文 */
  loadInitial(context: common.Context | undefined): void {
    this.bindHandlers();
    this.service.setEventHandlers(this.handlers);
    if (context !== undefined) {
      this.service.init(context);
    }
    this.state = this.service.getState();
  }

  /** 页面 aboutToDisappear：释放全部资源 */
  destroy(): void {
    this.service.destroy();
  }

  /** 事件绑定 */
  private bindHandlers(): void {
    this.handlers.onStateChange = (state: ReceiverState): void => {
      this.state = state;
      let request = state.receiveRequest;
      // 仅在跃迁进入「待确认」时弹框（taskId 可能为空，不能依赖 taskId 去重）
      if (state.stage === ReceiverStage.REQUEST_RECEIVED && request !== undefined &&
        this.lastStage !== ReceiverStage.REQUEST_RECEIVED) {
        this.onNewRequest(request);
      }
      this.lastStage = state.stage;
    };
    this.handlers.onLog = (entry: ReceiverLogEntry): void => {
      this.logs.push(entry);
    };
  }

  // ── 展示辅助 ──

  /** 当前阶段文本 */
  stageText(): string {
    return receiverStageText(this.state.stage);
  }

  /** 当前阶段是否为待用户确认 */
  isWaitingConfirm(): boolean {
    return this.state.stage === ReceiverStage.REQUEST_RECEIVED && this.state.receiveRequest !== undefined;
  }

  /** 当前阶段是否处于下载/保存中 */
  isTransferring(): boolean {
    return this.state.stage === ReceiverStage.DOWNLOADING || this.state.stage === ReceiverStage.SAVING;
  }

  // ── 凭据展示 ──

  /** 解密后的 SSID（无凭据时为空） */
  credentialsSsid(): string {
    let credentials = this.state.credentials;
    return credentials !== undefined ? credentials.ssid : '';
  }

  /** 解密后的密码（无凭据时为空） */
  credentialsPsk(): string {
    let credentials = this.state.credentials;
    return credentials !== undefined ? credentials.psk : '';
  }

  /** 解密后的 MAC（无凭据时为空） */
  credentialsMac(): string {
    let credentials = this.state.credentials;
    return credentials !== undefined ? credentials.mac : '';
  }

  // ── 接收请求展示 ──

  /** 发送方名称 */
  requestSender(): string {
    let request = this.state.receiveRequest;
    return request !== undefined ? request.senderName : '';
  }

  /** 主文件名 */
  requestFileName(): string {
    let request = this.state.receiveRequest;
    return request !== undefined ? request.fileName : '';
  }

  /** 文件数文本 */
  requestFileCountText(): string {
    let request = this.state.receiveRequest;
    return request !== undefined ? String(request.fileCount) : '';
  }

  /** 总大小文本 */
  requestTotalSizeText(): string {
    let request = this.state.receiveRequest;
    return request !== undefined ? formatBytes(request.totalSize) : '';
  }

  // ── 进度展示 ──

  /** 进度百分比（0-100） */
  progressPercent(): number {
    return this.state.progress.percent;
  }

  /** 进度文本：已接收 / 总量 */
  progressText(): string {
    let progress = this.state.progress;
    if (progress.totalBytes > 0) {
      return `${formatBytes(progress.receivedBytes)} / ${formatBytes(progress.totalBytes)}`;
    }
    return formatBytes(progress.receivedBytes);
  }

  // ── 命令 ──

  /** 启动接收服务 */
  async onStartService(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      await this.service.startService(this.deviceNameInput);
    } catch (e) {
      logger.error('启动接收服务异常: ' + String(e));
    } finally {
      this.isBusy = false;
    }
  }

  /** 停止接收服务 */
  async onStopService(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      await this.service.stopService();
    } catch (e) {
      logger.error('停止接收服务异常: ' + String(e));
    } finally {
      this.isBusy = false;
    }
  }

  /** 接受接收请求 */
  async onAcceptRequest(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      await this.service.acceptRequest();
    } catch (e) {
      logger.error('接受接收请求异常: ' + String(e));
    } finally {
      this.isBusy = false;
    }
  }

  /** 拒绝接收请求 */
  async onRejectRequest(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      await this.service.rejectRequest();
    } catch (e) {
      logger.error('拒绝接收请求异常: ' + String(e));
    } finally {
      this.isBusy = false;
    }
  }

  /** 取消下载 */
  onCancelDownload(): void {
    this.service.cancelDownload();
  }

  /** 一键清理 */
  async onCleanup(): Promise<void> {
    this.isBusy = true;
    try {
      await this.service.cleanupAll();
    } catch (e) {
      logger.error('一键清理异常: ' + String(e));
    } finally {
      this.isBusy = false;
    }
  }

  /** 清空日志流 */
  clearLogs(): void {
    this.service.clearLogs();
    this.logs = [];
  }

  /** 拼接全部日志文本（时间/级别/来源/内容），供剪贴板复制 */
  buildLogText(): string {
    let lines: Array<string> = [];
    for (let i = 0; i < this.logs.length; i++) {
      let entry = this.logs[i];
      lines.push(`${entry.timeText} [${entry.level}] ${entry.source}: ${entry.content}`);
    }
    return lines.join('\n');
  }
}
