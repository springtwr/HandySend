/**
 * MtaSendViewModel.ets — MTA 发送调试页视图模型
 *
 * 持有页面可观察状态（发送状态快照、日志流），绑定 MtaSendService 的事件回调并把用户命令
 * 转发给服务。采用 V2 状态管理（@ObservedV2 + @Trace），状态快照整体替换以触发刷新。
 */

import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { MtaSendService } from '../service/mta/MtaSendService';
import { ReceiverLogEntry, formatBytes } from '../model/mta/MtaReceiveModels';
import {
  MtaDiscoveredDevice,
  MtaSendEventHandlers,
  MtaSendFile,
  MtaSendSession,
  MtaSenderStage,
  SenderState,
  mtaSenderStageText,
  totalFileBytes
} from '../model/mta/MtaSendModels';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaSendVM', '互传发送');

/** 发送端调试页视图模型 */
@ObservedV2
export class MtaSendViewModel {
  /** 发送端状态快照 */
  @Trace public state: SenderState = new SenderState()
  /** 日志流 */
  @Trace public logs: Array<ReceiverLogEntry> = []
  /** 命令是否执行中（防抖） */
  @Trace public isBusy: boolean = false
  /** 已选择待发送文件 */
  @Trace public pendingFiles: Array<MtaSendFile> = []
  /** 是否使用明文凭据（部分厂商如荣耀不接受加密凭据，需开启） */
  @Trace public plainCredentialMode: boolean = false

  private service: MtaSendService = new MtaSendService()
  private handlers: MtaSendEventHandlers = new MtaSendEventHandlers()
  private context: common.Context | undefined = undefined

  // ── 生命周期 ──

  /** 页面 aboutToAppear：绑定事件并注入上下文 */
  loadInitial(context: common.Context | undefined): void {
    this.context = context;
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
    this.handlers.onStateChange = (state: SenderState): void => {
      this.state = state;
    };
    this.handlers.onLog = (entry: ReceiverLogEntry): void => {
      this.logs.push(entry);
    };
  }

  // ── 展示辅助 ──

  /** 当前阶段文本 */
  stageText(): string {
    return mtaSenderStageText(this.state.stage);
  }

  /** 设备列表 */
  deviceList(): Array<MtaDiscoveredDevice> {
    return this.state.devices;
  }

  /** 是否处于扫描阶段 */
  isScanning(): boolean {
    return this.state.scanning;
  }

  /** 判断某设备是否被选中 */
  isSelected(device: MtaDiscoveredDevice): boolean {
    let selected = this.state.selected;
    return selected !== undefined && selected.bleAddress === device.bleAddress;
  }

  // ── 命令 ──

  /** 启动扫描 */
  async onStartScan(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      await this.service.startScan();
    } catch (e) {
      logger.error('启动扫描异常: ' + String(e));
    } finally {
      this.isBusy = false;
    }
  }

  /** 停止扫描 */
  async onStopScan(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      await this.service.stopScan();
    } catch (e) {
      logger.error('停止扫描异常: ' + String(e));
    } finally {
      this.isBusy = false;
    }
  }

  /** 选中设备（扫描进行中亦可选中，发送时服务会先停止扫描） */
  onSelectDevice(device: MtaDiscoveredDevice): void {
    this.service.selectDevice(device);
  }

  /** 当前发送会话（未开始时为 undefined） */
  session(): MtaSendSession | undefined {
    return this.state.session;
  }

  /** 是否已选中设备且处于可发送状态（扫描不阻塞发送，发送时服务会先停止扫描） */
  canSend(): boolean {
    return this.state.selected !== undefined && this.pendingFiles.length > 0 &&
      this.state.stage !== MtaSenderStage.GATT_CONNECTING && this.state.stage !== MtaSenderStage.GROUP_CREATING &&
      this.state.stage !== MtaSenderStage.SERVER_STARTING && this.state.stage !== MtaSenderStage.TRANSFERRING &&
      this.state.stage !== MtaSenderStage.WAITING_WS && this.state.stage !== MtaSenderStage.NEGOTIATED &&
      this.state.stage !== MtaSenderStage.REQUEST_SENT;
  }

  /** 已选设备名称 */
  selectedName(): string {
    let selected = this.state.selected;
    return selected !== undefined ? selected.deviceName : '';
  }

  /** 会话群组 SSID */
  sessionSsid(): string {
    let session = this.state.session;
    return session !== undefined ? session.groupSsid : '';
  }

  /** 会话群组口令 */
  sessionPsk(): string {
    let session = this.state.session;
    return session !== undefined ? session.groupPsk : '';
  }

  /** 会话本机 MAC */
  sessionMac(): string {
    let session = this.state.session;
    return session !== undefined ? session.localMac : '';
  }

  /** 会话 GO 网关地址 */
  sessionGoIp(): string {
    let session = this.state.session;
    return session !== undefined ? session.goIp : '';
  }

  /** 会话端口 */
  sessionPort(): number {
    let session = this.state.session;
    return session !== undefined ? session.port : 0;
  }

  /** 会话任务 ID */
  sessionTaskId(): string {
    let session = this.state.session;
    return session !== undefined ? session.taskId : '';
  }

  /** 发起发送（使用当前选中设备与已选文件） */
  async onSendToDevice(): Promise<void> {
    let selected = this.state.selected;
    if (selected === undefined || this.pendingFiles.length === 0) {
      return;
    }
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      await this.service.sendToDevice(selected, this.pendingFiles.slice(), this.plainCredentialMode);
    } catch (e) {
      logger.error('发起发送异常: ' + String(e));
    } finally {
      this.isBusy = false;
    }
  }

  // ── 文件选择 ──

  /** 使用系统文件选择器选择待发送文件 */
  async onPickFiles(): Promise<void> {
    let context = this.context;
    if (context === undefined) {
      return;
    }
    let documentPicker = new picker.DocumentViewPicker(context);
    let options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 10;
    try {
      let uris: Array<string> = await documentPicker.select(options);
      this.addUris(uris);
    } catch (e) {
      logger.error('选择文件失败: ' + String(e));
    }
  }

  /** 追加选择结果到待发送清单 */
  private addUris(uris: Array<string>): void {
    if (uris.length === 0) {
      return;
    }
    let added: Array<MtaSendFile> = this.pendingFiles.slice();
    for (let i = 0; i < uris.length; i++) {
      let file = new MtaSendFile();
      file.uri = uris[i];
      file.displayName = this.displayNameOf(uris[i], added.length);
      added.push(file);
    }
    this.pendingFiles = added;
  }

  /** 从 URI 末段解析显示文件名 */
  private displayNameOf(uri: string, fallbackIndex: number): string {
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

  /** 移除一个待发送文件 */
  onRemoveFile(index: number): void {
    let updated: Array<MtaSendFile> = [];
    for (let i = 0; i < this.pendingFiles.length; i++) {
      if (i !== index) {
        updated.push(this.pendingFiles[i]);
      }
    }
    this.pendingFiles = updated;
  }

  /** 清空待发送文件 */
  onClearFiles(): void {
    this.pendingFiles = [];
  }

  /** 待发送文件总大小文本 */
  pendingTotalText(): string {
    return formatBytes(totalFileBytes(this.pendingFiles));
  }

  // ── 进度展示 ──

  /** 进度百分比（0-100） */
  progressPercent(): number {
    return this.state.progress.percent;
  }

  /** 进度文本：已发送 / 总量 */
  progressText(): string {
    let progress = this.state.progress;
    if (progress.totalBytes > 0) {
      return `${formatBytes(progress.sentBytes)} / ${formatBytes(progress.totalBytes)}`;
    }
    return formatBytes(progress.sentBytes);
  }

  /** 是否处于传输中 */
  isTransferring(): boolean {
    return this.state.stage === MtaSenderStage.TRANSFERRING;
  }

  /** 是否已进入终态（完成/失败/取消） */
  isFinished(): boolean {
    return this.state.stage === MtaSenderStage.COMPLETED || this.state.stage === MtaSenderStage.FAILED ||
      this.state.stage === MtaSenderStage.CANCELLED;
  }

  // ── 取消与清理 ──

  /** 取消进行中的发送 */
  async onCancel(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      await this.service.cancelSend();
    } catch (e) {
      logger.error('取消发送异常: ' + String(e));
    } finally {
      this.isBusy = false;
    }
  }

  /** 一键清理全部资源 */
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
