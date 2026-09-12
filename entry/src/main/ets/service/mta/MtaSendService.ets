/**
 * MtaSendService.ets — MTA 发送端编排门面
 *
 * 串联 BLE 扫描/连接、WiFi Direct 建组、Rust TLS/WS 服务器与文件传输，维护发送端状态机
 * （SenderState）与日志流（ReceiverLogEntry），并以事件回调方式向 ViewModel 推送状态快照
 * 与新增日志。所有系统调用失败均转为可读文本写入日志，不向页面抛出异常。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  DecryptedCredentials,
  DeviceInfoJson,
  P2pInfoJson,
  ReceiverLogEntry,
  formatTimeText,
  truncateUtf8Text
} from '../../model/mta/MtaProtocolModels';
import {
  EncryptedCredentials,
  MtaBleClientEventHandlers,
  MtaDiscoveredDevice,
  MtaGroupInfo,
  MtaP2pGroupEventHandlers,
  MtaSendEventHandlers,
  MtaSendFile,
  MtaSendProgress,
  MtaSendSession,
  MtaSenderStage,
  SenderState,
  buildEntryName,
  mtaDeviceIdentityKey,
  parseRustLogLine,
  randomGroupName,
  randomPassphrase,
  randomTaskId,
  resolveGroupBand,
  totalFileBytes
} from '../../model/mta/MtaSendModels';
import { NativeEvent, NativeMtaFileEntry, NativeMtaServerConfig } from '../../model/NativeTypes';
import { MTA_SHARED_TEXT_FILE_NAME } from '../../model/mta/MtaMainModels';
import {
  nativeMtaStartServer,
  nativeMtaStopServer,
  nativePollDebugLogWithLevels,
  offBridgeEvent,
  onBridgeEvent
} from '../NativeBridge';
import { MtaConstants } from './MtaConstants';
import { MtaBleClient } from './MtaBleClient';
import { MtaCrypto } from './MtaCrypto';
import { MtaP2pGroup } from './MtaP2pGroup';
import { MTA_BRAND_ID_THIRD_PARTY, resolveMtaBrandName } from '../../model/mta/MtaBrandRegistry';
import { getDeviceAlias } from '../repository/DeviceRepository';
import { getMtaSimulatedBrand } from '../repository/SettingsRepository';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { LogLevels, normalizeLevel } from '../../common/LogLevels';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaSend', '互传发送');

/** 文本 UTF-8 字节长度（用于文本会话总大小与进度兜底） */
function utf8ByteLength(text: string): number {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    let code = text.charCodeAt(i);
    if (code < 0x80) {
      bytes += 1;
    } else if (code < 0x800) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/** 发送端服务编排门面 */
export class MtaSendService {
  /** 当前状态（对外仅暴露快照） */
  private state: SenderState = new SenderState();
  /** 事件回调（ViewModel 注入） */
  private handlers: MtaSendEventHandlers | null = null;
  /** 应用上下文（权限申请用） */
  private context: common.Context | undefined = undefined;
  /** BLE 客户端（扫描 + GATT Client） */
  private ble: MtaBleClient = new MtaBleClient();
  /** BLE 事件回调 */
  private bleHandlers: MtaBleClientEventHandlers = new MtaBleClientEventHandlers();
  /** WiFi Direct 群组管理器 */
  private p2p: MtaP2pGroup = new MtaP2pGroup();
  /** P2P 事件回调 */
  private p2pHandlers: MtaP2pGroupEventHandlers = new MtaP2pGroupEventHandlers();
  /** 加解密模块（本会话 ECDH 密钥对） */
  private crypto: MtaCrypto = new MtaCrypto();
  /** 发送者显示名（取自设备昵称，无内容时以空串发送） */
  private senderName: string = '';
  /** 本机 2 字节发送者 ID 十六进制 */
  private senderIdHex: string = '';
  /** 是否有发送会话正在处理 */
  private sessionActive: boolean = false;
  /** 当前会话是否已被用户取消（阻止取消后的旧异步链路把 CANCELLED 覆盖为 FAILED） */
  private cancelledThisSession: boolean = false;
  /** 会话终态监听（完成/失败/取消时回调，供仓储恢复接收服务） */
  private sessionEndListener: (() => void) | null = null;
  /** 是否已订阅 Rust Mta* 事件 */
  private nativeSubscribed: boolean = false;
  /** Mta* 事件统一处理回调（订阅/退订需同一引用） */
  private nativeEventHandler: (event: NativeEvent) => void = (event: NativeEvent): void => {
    this.handleNativeEvent(event);
  };
  /** 完成后延迟清理定时器 */
  private cleanupTimerId: number = -1;
  /** Rust 日志轮询定时器（-1 表示未运行） */
  private rustLogTimerId: number = -1;
  /** 群组客户端数轮询定时器（-1 表示未运行） */
  private groupClientTimerId: number = -1;
  /** 等待对端 WS 连接的超时定时器（-1 表示未运行） */
  private waitingWsTimerId: number = -1;
  /** 上次群组客户端数（-1 表示未知） */
  private lastClientCount: number = -1;

  // ── 生命周期与订阅 ──

  /** 注入事件回调 */
  setEventHandlers(handlers: MtaSendEventHandlers): void {
    this.handlers = handlers;
  }

  /** 注入应用上下文并初始化子模块 */
  init(context: common.Context): void {
    this.context = context;
    this.senderIdHex = this.randomSenderIdHex();
    // 发送方名称统一取自设备昵称（未设置时由 DeviceRepository 生成默认昵称）
    this.senderName = getDeviceAlias();
    this.bindBleHandlers();
    this.bindP2pHandlers();
    this.ble.registerEvents(this.bleHandlers);
    this.p2p.registerEvents(this.p2pHandlers);
    this.subscribeNativeEvents();
    this.startRustLogPolling();
    this.appendLog('服务', `MTA 发送页就绪，发送者 ID=${this.senderIdHex} 发送者名称=${this.senderName}`, LogLevels.INFO);
  }

  /** 当前状态快照 */
  getState(): SenderState {
    return this.state.snapshot();
  }

  /** 当前是否有发送会话进行中 */
  isSessionActive(): boolean {
    return this.sessionActive;
  }

  /** 注入会话终态监听（完成/失败/取消时触发一次）；传 null 清除 */
  setSessionEndListener(listener: (() => void) | null): void {
    this.sessionEndListener = listener;
  }

  /** 结束当前会话（幂等）：仅在实际处于活动态时通知一次终态 */
  private endSession(): void {
    if (!this.sessionActive) {
      return;
    }
    this.sessionActive = false;
    if (this.sessionEndListener !== null) {
      this.sessionEndListener();
    }
  }

  /**
   * 异步步骤间的取消检查点：会话已被取消或终止时幂等释放资源并返回 true。
   * 每个跨 await 的步骤之后调用，防止取消/终止后的旧异步链路继续推进
   * （覆盖 CANCELLED 终态、复活已停止的定时器、二次拉起已释放的资源）。
   */
  private async checkSessionAborted(): Promise<boolean> {
    if (this.sessionActive) {
      return false;
    }
    await this.releaseSendResources();
    return true;
  }

  // ── 状态与日志辅助 ──

  /** 切换阶段并推送状态快照 */
  private setStage(stage: MtaSenderStage): void {
    this.state.stage = stage;
    this.notifyState();
  }

  /** 推送当前状态快照给 ViewModel */
  private notifyState(): void {
    if (this.handlers !== null) {
      this.handlers.onStateChange(this.state.snapshot());
    }
  }

  /** 记录最近一次错误 */
  private setError(message: string): void {
    this.state.lastError = message;
    this.notifyState();
  }

  /** 追加一条带时间戳的日志，同时输出 hilog */
  private appendLog(source: string, content: string, level: string): void {
    let entry = new ReceiverLogEntry();
    entry.timeText = formatTimeText(new Date());
    entry.source = source;
    entry.level = normalizeLevel(level);
    entry.content = content;
    if (this.handlers !== null) {
      this.handlers.onLog(entry);
    }
    // 级别统一经通用分级出口输出到 hilog，未知 token 由 Logger 兜底为 info
    logger.log(entry.level, content);
  }

  /** 生成 2 字节随机发送者 ID 十六进制文本 */
  private randomSenderIdHex(): string {
    let hex = '';
    for (let i = 0; i < MtaConstants.SENDER_ID_LENGTH; i++) {
      let b = Math.floor(Math.random() * 256).toString(16);
      hex += b.length === 1 ? '0' + b : b;
    }
    return hex;
  }

  // ── BLE 事件绑定 ──

  /** 绑定 BLE 事件回调：设备发现去重合并，状态事件转日志 */
  private bindBleHandlers(): void {
    this.bleHandlers.onDeviceFound = (device: MtaDiscoveredDevice): void => {
      this.mergeDevice(device);
    };
    this.bleHandlers.onScanStateChange = (scanning: boolean, detail: string): void => {
      this.state.scanning = scanning;
      this.notifyState();
      this.appendLog('扫描', detail, LogLevels.DEBUG);
    };
    this.bleHandlers.onBluetoothStateChange = (stateText: string): void => {
      this.appendLog('蓝牙', `开关状态变化: ${stateText}`, LogLevels.DEBUG);
    };
    this.bleHandlers.onGattConnectionChange = (stateText: string): void => {
      this.appendLog('GATT', `连接状态: ${stateText}`, LogLevels.DEBUG);
    };
    this.bleHandlers.onMtuChange = (mtu: number): void => {
      this.appendLog('GATT', `MTU 协商完成: ${mtu}`, LogLevels.DEBUG);
    };
    this.bleHandlers.onRemoteDeviceInfo = (info: DeviceInfoJson): void => {
      this.appendLog('GATT', `读回对端 DeviceInfo：key=${info.key.length} 字符 mac=${info.mac}`, LogLevels.DEBUG);
    };
    this.bleHandlers.onError = (source: string, message: string): void => {
      this.appendLog(source, message, LogLevels.ERROR);
    };
  }

  /** 按「设备身份键」去重合并设备：已存在则更新，否则追加 */
  private mergeDevice(device: MtaDiscoveredDevice): void {
    let key = mtaDeviceIdentityKey(device);
    let devices = this.state.devices.slice();
    let found = false;
    for (let i = 0; i < devices.length; i++) {
      if (mtaDeviceIdentityKey(devices[i]) === key) {
        devices[i] = device;
        found = true;
        break;
      }
    }
    if (!found) {
      devices.push(device);
    }
    this.state.devices = devices;
    this.notifyState();
  }

  /** 绑定 P2P 事件回调：连接摘要与 GO IP 转日志/状态 */
  private bindP2pHandlers(): void {
    this.p2pHandlers.onGroupCreated = (info: MtaGroupInfo): void => {
      this.state.groupCreated = info.ssid.length > 0;
      this.notifyState();
    };
    this.p2pHandlers.onConnectionChange = (summary: string): void => {
      this.appendLog('P2P', summary, LogLevels.DEBUG);
    };
    this.p2pHandlers.onGoIp = (goIp: string): void => {
      if (this.state.session !== undefined) {
        this.state.session.goIp = goIp;
        this.notifyState();
      }
      this.appendLog('P2P', `取得 GO IP=${goIp}`, LogLevels.DEBUG);
    };
    this.p2pHandlers.onError = (source: string, message: string): void => {
      this.appendLog(source, message, LogLevels.ERROR);
    };
  }

  // ── 扫描命令 ──

  /** 启动扫描：权限/蓝牙检查 → BLE 扫描 */
  async startScan(): Promise<void> {
    if (this.state.scanning) {
      this.appendLog('扫描', '扫描已在运行', LogLevels.INFO);
      return;
    }
    let context = this.context;
    if (context === undefined) {
      this.appendLog('权限', '缺少应用上下文，无法申请蓝牙权限', LogLevels.ERROR);
      this.setError('缺少应用上下文');
      return;
    }
    let granted = false;
    try {
      granted = await this.ble.ensurePermission(context);
    } catch (e) {
      this.appendLog('权限', '申请 ACCESS_BLUETOOTH 失败: ' + String(e), LogLevels.ERROR);
    }
    if (!granted) {
      this.appendLog('权限', 'ACCESS_BLUETOOTH 被拒绝，无法扫描', LogLevels.ERROR);
      this.setError('蓝牙权限被拒绝');
      return;
    }
    if (!this.ble.isBluetoothOn()) {
      this.appendLog('蓝牙', `蓝牙未开启（当前 ${this.ble.getBluetoothStateText()}），请先开启后重试`, LogLevels.WARN);
      this.setError('蓝牙未开启');
      try {
        this.ble.enableBluetooth();
        this.appendLog('蓝牙', '已请求系统开启蓝牙', LogLevels.INFO);
      } catch (e) {
        this.appendLog('蓝牙', '请求开启蓝牙失败: ' + String(e), LogLevels.ERROR);
      }
      return;
    }
    this.state.devices = [];
    this.state.lastError = '';
    this.setStage(MtaSenderStage.SCANNING);
    try {
      await this.ble.startScan();
      this.appendLog('扫描', '已启动 MTA 接收端扫描', LogLevels.INFO);
    } catch (e) {
      this.appendLog('扫描', '启动扫描失败: ' + String(e), LogLevels.ERROR);
      this.setError('启动扫描失败: ' + String(e));
      this.setStage(MtaSenderStage.IDLE);
    }
  }

  /** 停止扫描 */
  async stopScan(): Promise<void> {
    try {
      await this.ble.stopScan();
    } catch (e) {
      this.appendLog('扫描', '停止扫描失败: ' + String(e), LogLevels.ERROR);
    }
    if (this.state.stage === MtaSenderStage.SCANNING) {
      this.setStage(MtaSenderStage.IDLE);
    }
  }

  /** 选中一个设备：更新选中项并停止扫描，使阶段离开「扫描中」以便发起发送 */
  selectDevice(device: MtaDiscoveredDevice): void {
    this.state.selected = device;
    this.notifyState();
    this.appendLog('选择', `已选中 ${device.deviceName} (${device.bleAddress})`, LogLevels.INFO);
    // 选定目标后停止扫描（发送前需停止扫描，把 BLE 让给 GATT 连接）
    if (this.state.scanning) {
      this.stopScan().catch((e: Object): void => {
        this.appendLog('扫描', '停止扫描失败: ' + String(e), LogLevels.ERROR);
      });
    }
  }

  // ── 发送流程 ──

  /**
   * 建立发送链路并启动传输：GATT 连接 → 读对端 DeviceInfo（含公钥）→ 建 WiFi Direct 组
   * → 文件暂存 → 启动 Rust TLS 服务器取真实端口 → 加密凭据并写回 P2pInfo → 等待对端协商/下载。
   */
  async sendToDevice(device: MtaDiscoveredDevice, files: Array<MtaSendFile>, forcePlain: boolean,
    text?: string): Promise<void> {
    if (this.sessionActive) {
      this.appendLog('服务', '已有发送会话进行中，忽略新的发送请求', LogLevels.WARN);
      return;
    }
    let textValue = text !== undefined ? text : '';
    if (files.length === 0 && textValue.length === 0) {
      this.appendLog('服务', '未选择文件且无文本内容，无法发送', LogLevels.WARN);
      this.setError('无可发送内容');
      return;
    }
    this.sessionActive = true;
    this.cancelledThisSession = false;
    this.state.selected = device;
    let session = new MtaSendSession();
    session.target = device;
    session.taskId = randomTaskId();
    session.senderIdHex = this.senderIdHex;
    session.senderName = this.senderName;
    this.state.session = session;
    this.state.lastError = '';
    this.state.groupCreated = false;
    this.state.serverRunning = false;
    this.state.progress = new MtaSendProgress();
    // 文本发送：把文本写入暂存目录的 sharedText.txt，作为唯一 ZIP 条目（1/sharedText.txt）
    let effectiveFiles = files;
    if (textValue.length > 0) {
      try {
        effectiveFiles = [this.writeSharedTextFile(session.taskId, textValue)];
      } catch (e) {
        await this.failSend('写入文本文件失败: ' + String(e));
        return;
      }
    }
    session.totalBytes = totalFileBytes(effectiveFiles);
    // 打包前校验条目数与总大小，超限快速失败，避免传输完成后才被接收端解压校验拒绝
    if (effectiveFiles.length > MtaConstants.MAX_SEND_ENTRY_COUNT) {
      await this.failSend(`文件数超过上限 ${MtaConstants.MAX_SEND_ENTRY_COUNT}`);
      return;
    }
    if (session.totalBytes > MtaConstants.MAX_SEND_TOTAL_BYTES) {
      await this.failSend(`总大小超过上限 ${MtaConstants.MAX_SEND_TOTAL_BYTES} 字节`);
      return;
    }
    this.state.currentFileName =
      effectiveFiles.length > 0 ? effectiveFiles[0].displayName : MTA_SHARED_TEXT_FILE_NAME;
    this.appendLog('服务', `开始发送到 ${device.deviceName} (${device.bleAddress})，任务=${session.taskId}`, LogLevels.INFO);

    // 发送期间停止扫描，避免与 GATT 连接争用
    await this.stopScan();
    if (await this.checkSessionAborted()) {
      return;
    }

    // 1) 生成会话 ECDH 密钥对
    try {
      session.localPublicKey = await this.crypto.generateKeyPair();
    } catch (e) {
      await this.failSend('生成 ECDH 密钥对失败: ' + String(e));
      return;
    }

    // 2) GATT 连接
    this.setStage(MtaSenderStage.GATT_CONNECTING);
    try {
      await this.ble.connectGattClient(device.bleAddress);
    } catch (e) {
      await this.failSend('GATT 连接发起失败: ' + String(e));
      return;
    }
    let connected = await this.ble.waitGattConnected(MtaConstants.GATT_CONNECT_TIMEOUT_MS);
    if (await this.checkSessionAborted()) {
      return;
    }
    if (!connected) {
      await this.failSend('GATT 连接超时');
      return;
    }
    this.appendLog('GATT', '已连接对端 GATT Server', LogLevels.INFO);

    // 3) 读对端 DeviceInfo（含公钥）
    let remoteInfo: DeviceInfoJson;
    try {
      remoteInfo = await this.ble.readRemoteDeviceInfo();
      session.remoteDeviceInfo = remoteInfo;
      this.notifyState();
    } catch (e) {
      await this.failSend('读取对端 DeviceInfo 失败: ' + String(e));
      return;
    }
    if (await this.checkSessionAborted()) {
      return;
    }

    // 4) 创建 WiFi Direct 组（Samsung 目标或对端不支持 5GHz 时用 2.4GHz，否则自动）
    this.setStage(MtaSenderStage.GROUP_CREATING);
    let groupName = randomGroupName();
    let passphrase = randomPassphrase();
    let goBand = resolveGroupBand(device.brandId, device.is5Ghz);
    try {
      await this.p2p.createGroup(groupName, passphrase, goBand);
      this.appendLog('P2P', `建组请求已发送 groupName=${groupName} goBand=${goBand}`, LogLevels.DEBUG);
    } catch (e) {
      await this.failSend('创建 WiFi Direct 组失败: ' + String(e));
      return;
    }
    let groupInfo = await this.p2p.waitGroupReady(MtaConstants.GROUP_READY_TIMEOUT_MS);
    if (await this.checkSessionAborted()) {
      return;
    }
    if (groupInfo === null || groupInfo.ssid.length === 0) {
      await this.failSend('建组超时，未取得群组信息');
      return;
    }
    session.groupSsid = groupInfo.ssid;
    session.groupPsk = groupInfo.psk.length > 0 ? groupInfo.psk : passphrase;
    session.localMac = groupInfo.ownerMac;
    session.groupFrequency = groupInfo.frequency;
    session.goIp = groupInfo.goIp.length > 0 ? groupInfo.goIp : this.p2p.getGoIp();
    this.state.groupCreated = true;
    this.notifyState();
    this.appendLog('P2P',
      `建组完成 ssid=${session.groupSsid} mac=${session.localMac} goIp=${session.goIp}`, LogLevels.INFO);

    // 5) 文件暂存到 cacheDir（picker URI 的临时授权仅在 ArkTS 侧有效）
    let stagedFiles: Array<MtaSendFile>;
    try {
      stagedFiles = await this.stageFiles(effectiveFiles, session.taskId);
      session.files = stagedFiles;
      this.appendLog('暂存', `已暂存 ${stagedFiles.length} 个文件到 ${this.stageDir(session.taskId)}`, LogLevels.DEBUG);
    } catch (e) {
      await this.failSend('文件暂存失败: ' + String(e));
      return;
    }

    // 6) 启动 Rust TLS 服务器并取实际端口
    this.setStage(MtaSenderStage.SERVER_STARTING);
    let zipPath = `${this.stageDir(session.taskId)}/${MtaConstants.ZIP_FILE_NAME}`;
    session.zipPath = zipPath;
    try {
      session.port = await this.startServer(session, stagedFiles, zipPath, textValue);
      this.state.serverRunning = true;
      this.notifyState();
      this.appendLog('服务器', `TLS 服务器已启动 bindIp=${session.goIp} port=${session.port}`, LogLevels.INFO);
    } catch (e) {
      await this.failSend('启动服务器失败: ' + String(e));
      return;
    }
    if (await this.checkSessionAborted()) {
      return;
    }

    // 7) 写回 P2pInfo（对端提供公钥则加密，否则明文；携带群组频点 freq）
    let credentials = new DecryptedCredentials();
    credentials.ssid = session.groupSsid;
    credentials.psk = session.groupPsk;
    credentials.mac = session.localMac;
    let p2pInfo: P2pInfoJson;
    if (!forcePlain && remoteInfo.key.length > 0) {
      let encrypted: EncryptedCredentials;
      try {
        encrypted = await this.crypto.encryptCredentials(remoteInfo, credentials);
      } catch (e) {
        await this.failSend('加密凭据失败: ' + String(e));
        return;
      }
      if (await this.checkSessionAborted()) {
        return;
      }
      p2pInfo = this.buildP2pInfoJson(session, encrypted.ssid, encrypted.psk, encrypted.mac,
        session.localPublicKey, session.port);
    } else {
      p2pInfo = this.buildP2pInfoJson(session, credentials.ssid, credentials.psk, credentials.mac,
        '', session.port);
    }
    try {
      await this.ble.writeRemoteP2pInfo(JSON.stringify(p2pInfo));
    } catch (e) {
      await this.failSend('写入 P2pInfo 失败: ' + String(e));
      return;
    }
    if (await this.checkSessionAborted()) {
      return;
    }
    this.appendLog('GATT', `已写回 P2pInfo: ${JSON.stringify(p2pInfo)}`, LogLevels.DEBUG);
    this.setStage(MtaSenderStage.P2P_INFO_WRITTEN);
    this.setStage(MtaSenderStage.WAITING_WS);
    this.appendLog('服务', '等待对端建立 WS 连接...', LogLevels.DEBUG);
    this.startWaitingWsTimeout();
    // 轮询群组客户端数，判定对端是否已加入 WiFi Direct 组
    this.startGroupClientPolling();
  }

  /** 提交启动服务器请求并取回实际端口 */
  private async startServer(session: MtaSendSession, files: Array<MtaSendFile>, zipPath: string,
    text: string): Promise<number> {
    let entries: Array<NativeMtaFileEntry> = [];
    for (let i = 0; i < files.length; i++) {
      let entry: NativeMtaFileEntry = { path: files[i].stagedPath, entryName: files[i].entryName };
      entries.push(entry);
    }
    let config: NativeMtaServerConfig = {
      bindIp: session.goIp.length > 0 ? session.goIp : MtaConstants.DEFAULT_BIND_IP,
      port: MtaConstants.DEFAULT_SEND_PORT,
      taskId: session.taskId,
      senderId: session.senderIdHex,
      senderName: session.senderName,
      files: entries,
      zipPath: zipPath
    };
    // 文本发送：随 sendRequest 携带 catShareText（Rust 侧透传为 textContent）；
    // 走 WS 单帧传输，超限截断，完整文本仍经 sharedText.txt ZIP 条目送达
    if (text.length > 0) {
      config.textContent = truncateUtf8Text(text, MtaConstants.MAX_SHARE_TEXT_BYTES);
    }
    // 模拟品牌：默认第三方时不携带品牌字段，保证载荷与现状逐字节一致
    let brandId = getMtaSimulatedBrand();
    if (brandId !== MTA_BRAND_ID_THIRD_PARTY) {
      config.senderBrandId = brandId;
      config.senderBrand = resolveMtaBrandName(brandId);
    }
    // 超时兜底：ZIP 预打包耗时不可控时不永久停在 SERVER_STARTING；
    // 超时后底层 promise 可能迟到 resolve/reject，挂空 catch 防 unhandled rejection，
    // 迟到成功的服务器由 failSend → releaseSendResources 统一回收
    let startPromise = nativeMtaStartServer(config);
    startPromise.catch((_e: Object): void => {
    });
    let timeoutPromise = new Promise<number>((_resolve, reject) => {
      setTimeout(() => {
        reject(new Error(`启动服务器超时（${MtaConstants.SERVER_START_TIMEOUT_MS}ms）`));
      }, MtaConstants.SERVER_START_TIMEOUT_MS);
    });
    return await Promise.race([startPromise, timeoutPromise]);
  }

  /** 文本发送：把文本内容写入暂存目录的 sharedText.txt，返回待暂存条目 */
  private writeSharedTextFile(taskId: string, text: string): MtaSendFile {
    let dir = this.stageDir(taskId);
    this.ensureStageDir(dir);
    let path = `${dir}/${MTA_SHARED_TEXT_FILE_NAME}`;
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
    let out = new MtaSendFile();
    out.uri = path;
    out.displayName = MTA_SHARED_TEXT_FILE_NAME;
    out.sizeBytes = utf8ByteLength(text);
    out.stagedPath = path;
    return out;
  }

  /** 组装 P2pInfo（明文端口/凭据 + 群组频点 + 本机 ID；key 非空时凭据为密文） */
  private buildP2pInfoJson(session: MtaSendSession, ssid: string, psk: string, mac: string,
    key: string, port: number): P2pInfoJson {
    let info = new P2pInfoJson();
    info.id = session.senderIdHex;
    info.ssid = ssid;
    info.psk = psk;
    info.mac = mac;
    info.port = port;
    info.freq = session.groupFrequency;
    info.key = key;
    // catShare 为 CatShare 版本号（非品牌值），与接收端/P2pInfo 协议一致
    info.catShare = MtaConstants.CATSHARE_VERSION;
    return info;
  }

  // ── 文件暂存 ──

  /** 暂存目录（cacheDir/mta_send_<taskId>） */
  private stageDir(taskId: string): string {
    let base = this.context !== undefined ? this.context.cacheDir : '';
    return `${base}/${MtaConstants.STAGE_DIR_PREFIX}${taskId}`;
  }

  /**
   * 确保暂存目录存在。
   * HarmonyOS 的 mkdirSync 递归模式对已存在目录仍会抛 EEXIST，故先判断再创建，
   * 避免同一任务内多次准备目录时产生误报告警。
   */
  private ensureStageDir(dir: string): void {
    if (!fs.accessSync(dir, fs.AccessModeType.EXIST)) {
      fs.mkdirSync(dir, true);
    }
  }

  /** 复制选中文件到暂存目录，返回填充了 stagedPath/entryName/size 的清单 */
  private async stageFiles(files: Array<MtaSendFile>, taskId: string): Promise<Array<MtaSendFile>> {
    let dir = this.stageDir(taskId);
    this.ensureStageDir(dir);
    let staged: Array<MtaSendFile> = [];
    for (let i = 0; i < files.length; i++) {
      let source = files[i];
      let safeName = this.sanitizeFileName(source.displayName, i);
      let destPath = `${dir}/${i}_${safeName}`;
      try {
        await this.copyUriToPath(source.uri, destPath);
      } catch (e) {
        throw new Error(`复制文件失败 ${source.displayName}: ${String(e)}`);
      }
      let size = 0;
      try {
        size = fs.statSync(destPath).size;
      } catch (e) {
        logger.warn('读取文件大小失败: ' + String(e));
      }
      let out = new MtaSendFile();
      out.uri = source.uri;
      out.displayName = safeName;
      out.sizeBytes = size;
      out.stagedPath = destPath;
      out.entryName = buildEntryName(i, safeName);
      staged.push(out);
    }
    return staged;
  }

  /**
   * 把选择器返回的 URI 复制到沙箱路径。
   * Picker 返回的 URI 仅带临时授权，不能直接作为 copyFile 的路径参数；
   * 需先 openSync 取源文件 fd，再把 fd 复制到目标文件 fd。
   * 复制走异步 fs.copyFile，避免大文件同步 IO 阻塞 UI 线程。
   */
  private async copyUriToPath(sourceUri: string, destPath: string): Promise<void> {
    let src = fs.openSync(sourceUri, fs.OpenMode.READ_ONLY);
    try {
      let dest = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        await fs.copyFile(src.fd, dest.fd);
      } finally {
        fs.closeSync(dest);
      }
    } finally {
      fs.closeSync(src);
    }
  }

  /** 替换文件名中的路径分隔符与控制字符，避免越权写出暂存目录 */
  private sanitizeFileName(name: string, index: number): string {
    let clean = name.length > 0 ? name : `file_${index}`;
    let out = '';
    for (let i = 0; i < clean.length; i++) {
      let ch = clean.charAt(i);
      if (ch === '/' || ch === '\\' || ch === ':' || ch === '*' || ch === '?' || ch === '"' ||
        ch === '<' || ch === '>' || ch === '|') {
        out += '_';
      } else {
        out += ch;
      }
    }
    return out.length > 0 ? out : `file_${index}`;
  }

  /** 删除本次发送的暂存目录（含预打包 ZIP） */
  private deleteStageDir(taskId: string): void {
    let dir = this.stageDir(taskId);
    try {
      // 目录可能已被先前的清理路径删除；不存在时直接跳过，避免重复清理产生无意义告警
      if (fs.accessSync(dir, fs.AccessModeType.EXIST)) {
        fs.rmdirSync(dir);
      }
    } catch (e) {
      logger.warn('删除暂存目录失败: ' + String(e));
    }
  }

  // ── Rust Mta* 事件订阅与状态推进 ──

  /** 订阅全部 Mta* 桥接事件（同一回调便于退订） */
  private subscribeNativeEvents(): void {
    if (this.nativeSubscribed) {
      return;
    }
    let types: Array<string> = [
      'mtaServerStarted', 'mtaWsConnected', 'mtaVersionNegotiated', 'mtaSendRequestSent',
      'mtaDownloadStarted', 'mtaSendProgress', 'mtaSendCompleted', 'mtaSendRejected', 'mtaSendFailed'
    ];
    for (let i = 0; i < types.length; i++) {
      onBridgeEvent(types[i], this.nativeEventHandler);
    }
    this.nativeSubscribed = true;
  }

  /** 退订全部 Mta* 桥接事件 */
  private unsubscribeNativeEvents(): void {
    if (!this.nativeSubscribed) {
      return;
    }
    let types: Array<string> = [
      'mtaServerStarted', 'mtaWsConnected', 'mtaVersionNegotiated', 'mtaSendRequestSent',
      'mtaDownloadStarted', 'mtaSendProgress', 'mtaSendCompleted', 'mtaSendRejected', 'mtaSendFailed'
    ];
    for (let i = 0; i < types.length; i++) {
      offBridgeEvent(types[i], this.nativeEventHandler);
    }
    this.nativeSubscribed = false;
  }

  /** 处理 Rust Mta* 事件并推进阶段/进度 */
  private handleNativeEvent(event: NativeEvent): void {
    if (!this.sessionActive && event.type !== 'mtaServerStarted') {
      return;
    }
    switch (event.type) {
      case 'mtaServerStarted':
        this.appendLog('服务器', `服务器已启动 port=${event.port}`, LogLevels.INFO);
        break;
      case 'mtaWsConnected':
        this.clearWaitingWsTimeout();
        this.setStage(MtaSenderStage.WAITING_WS);
        this.appendLog('WS', '对端已建立 WS 连接', LogLevels.INFO);
        break;
      case 'mtaVersionNegotiated':
        this.setStage(MtaSenderStage.NEGOTIATED);
        this.appendLog('WS', `版本协商完成 version=${event.version}`, LogLevels.INFO);
        break;
      case 'mtaSendRequestSent':
        this.setStage(MtaSenderStage.REQUEST_SENT);
        this.appendLog('WS', `已发送 sendRequest（任务=${event.taskId}）`, LogLevels.INFO);
        break;
      case 'mtaDownloadStarted':
        this.setStage(MtaSenderStage.TRANSFERRING);
        this.appendLog('下载', `对端开始下载 ZIP（任务=${event.taskId}）`, LogLevels.INFO);
        break;
      case 'mtaSendProgress': {
        let progress = new MtaSendProgress();
        progress.sentBytes = event.sentBytes;
        progress.totalBytes = event.totalBytes;
        progress.percent = Math.max(0, Math.min(100, Math.floor(event.percent)));
        this.state.progress = progress;
        this.notifyState();
        break;
      }
      case 'mtaSendCompleted':
        this.onSendCompleted(event.taskId);
        break;
      case 'mtaSendRejected':
        this.failSend(`对方拒绝：${event.reason}`);
        break;
      case 'mtaSendFailed':
        this.failSend(event.reason);
        break;
      default:
        break;
    }
  }

  /** 本次发送完成：标记完成并在延迟后释放资源 */
  private onSendCompleted(taskId: string): void {
    let progress = new MtaSendProgress();
    progress.sentBytes = this.state.session !== undefined ? this.state.session.totalBytes : 0;
    progress.totalBytes = progress.sentBytes;
    progress.percent = 100;
    this.state.progress = progress;
    this.setStage(MtaSenderStage.COMPLETED);
    this.appendLog('服务', `发送完成（任务=${taskId}）`, LogLevels.INFO);
    this.endSession();
    this.scheduleCleanup();
  }

  /** 延迟清理资源：给对端收尾时间后停止服务器并删组 */
  private scheduleCleanup(): void {
    this.clearCleanupTimer();
    this.cleanupTimerId = setTimeout(() => {
      this.cleanupTimerId = -1;
      this.releaseSendResources().catch((e: Object): void => {
        this.appendLog('服务', '完成后清理异常: ' + String(e), LogLevels.ERROR);
      });
    }, MtaConstants.SEND_COMPLETE_SETTLE_DELAY_MS);
  }

  /** 清除延迟清理定时器 */
  private clearCleanupTimer(): void {
    if (this.cleanupTimerId >= 0) {
      clearTimeout(this.cleanupTimerId);
      this.cleanupTimerId = -1;
    }
  }

  /** 本次发送失败：记录原因、进入失败阶段并释放全部传输资源 */
  private async failSend(reason: string): Promise<void> {
    // 已被用户取消的会话保持 CANCELLED 终态，不再被旧链路的失败回调覆盖
    if (this.cancelledThisSession) {
      return;
    }
    this.setError(reason);
    this.setStage(MtaSenderStage.FAILED);
    this.appendLog('服务', `本次发送失败：${reason}`, LogLevels.ERROR);
    this.endSession();
    await this.releaseSendResources();
  }

  /** 释放一次发送占用的全部资源（服务器/GATT/群组/暂存文件） */
  private async releaseSendResources(): Promise<void> {
    this.clearCleanupTimer();
    this.clearWaitingWsTimeout();
    this.stopGroupClientPolling();
    try {
      await nativeMtaStopServer();
    } catch (e) {
      this.appendLog('服务器', '停止服务器失败: ' + String(e), LogLevels.ERROR);
    }
    this.state.serverRunning = false;
    try {
      await this.ble.disconnectGattClient();
    } catch (e) {
      this.appendLog('GATT', '断开 GATT 失败: ' + String(e), LogLevels.ERROR);
    }
    try {
      await this.p2p.removeGroup();
    } catch (e) {
      this.appendLog('P2P', '删除群组失败: ' + String(e), LogLevels.ERROR);
    }
    this.state.groupCreated = false;
    let session = this.state.session;
    if (session !== undefined && session.taskId.length > 0) {
      this.deleteStageDir(session.taskId);
    }
    this.notifyState();
  }

  // ── 取消与清理 ──

  /** 取消进行中的发送：停止服务器、删组、断 GATT 并清理暂存文件，复位到可再次发送 */
  async cancelSend(): Promise<void> {
    if (!this.sessionActive && this.state.stage !== MtaSenderStage.FAILED) {
      this.appendLog('服务', '当前无进行中的发送，无需取消', LogLevels.INFO);
      return;
    }
    this.appendLog('服务', '用户取消发送', LogLevels.INFO);
    this.cancelledThisSession = true;
    this.endSession();
    this.setError('已取消');
    this.setStage(MtaSenderStage.CANCELLED);
    await this.releaseSendResources();
    this.appendLog('服务', '已取消本次发送并释放资源', LogLevels.INFO);
  }

  /** 一键清理：清空会话、设备与日志以外的全部资源，复位到可再次发送 */
  async cleanupAll(): Promise<void> {
    this.cancelledThisSession = true;
    this.endSession();
    await this.stopScan();
    await this.releaseSendResources();
    this.state.selected = undefined;
    this.state.devices = [];
    this.state.session = undefined;
    this.state.progress = new MtaSendProgress();
    this.state.currentFileName = '';
    this.state.lastError = '';
    this.setStage(MtaSenderStage.IDLE);
    this.appendLog('服务', '已清理全部 MTA 发送资源', LogLevels.INFO);
  }

  // ── Rust 日志轮询（服务器/TLS/WS 侧诊断） ──

  /** 启动 Rust 日志轮询：排空日志缓冲并追加到发送页日志 */
  private startRustLogPolling(): void {
    if (this.rustLogTimerId >= 0) {
      return;
    }
    this.rustLogTimerId = setInterval(() => {
      this.drainRustLog();
    }, MtaConstants.RUST_LOG_POLL_MS);
  }

  /** 停止 Rust 日志轮询 */
  private stopRustLogPolling(): void {
    if (this.rustLogTimerId >= 0) {
      clearInterval(this.rustLogTimerId);
      this.rustLogTimerId = -1;
    }
  }

  /** 排空 Rust 日志缓冲并追加 MTA 相关行（解析 `level|message` 前缀，按原始级别展示） */
  private drainRustLog(): void {
    try {
      let lines = nativePollDebugLogWithLevels();
      for (let i = 0; i < lines.length; i++) {
        let parsed = parseRustLogLine(lines[i]);
        if (parsed.message.includes('MTA')) {
          this.appendLog('Rust', parsed.message, parsed.level);
        }
      }
    } catch (e) {
      logger.warn('轮询 Rust 日志失败: ' + String(e));
    }
  }

  // ── 群组客户端轮询（诊断对端是否加入 WiFi Direct 组） ──

  /** 启动群组客户端数轮询 */
  private startGroupClientPolling(): void {
    if (this.groupClientTimerId >= 0) {
      return;
    }
    this.lastClientCount = -1;
    this.groupClientTimerId = setInterval(() => {
      this.pollGroupClient();
    }, MtaConstants.GROUP_CLIENT_POLL_MS);
  }

  /** 停止群组客户端数轮询 */
  private stopGroupClientPolling(): void {
    if (this.groupClientTimerId >= 0) {
      clearInterval(this.groupClientTimerId);
      this.groupClientTimerId = -1;
    }
  }

  /** 启动等待对端 WS 连接的超时定时器（超时仍未回连则判定发送失败） */
  private startWaitingWsTimeout(): void {
    this.clearWaitingWsTimeout();
    this.waitingWsTimerId = setTimeout(() => {
      this.waitingWsTimerId = -1;
      // 仅在会话仍停留在等待 WS 阶段时判定失败（对端解密凭据失败/直连失败/异常退出）
      if (this.sessionActive && this.state.stage === MtaSenderStage.WAITING_WS) {
        this.failSend(`等待对端连接超时（${MtaConstants.WAITING_WS_TIMEOUT_MS}ms）`);
      }
    }, MtaConstants.WAITING_WS_TIMEOUT_MS);
  }

  /** 清除等待对端 WS 连接的超时定时器 */
  private clearWaitingWsTimeout(): void {
    if (this.waitingWsTimerId >= 0) {
      clearTimeout(this.waitingWsTimerId);
      this.waitingWsTimerId = -1;
    }
  }

  /** 查询群组客户端数，变化时记录（用于判断对端是否已加入组） */
  private pollGroupClient(): void {
    this.p2p.getCurrentGroup().then((info: MtaGroupInfo | null): void => {
      if (info === null) {
        return;
      }
      if (info.clientCount !== this.lastClientCount) {
        this.lastClientCount = info.clientCount;
        let detail = info.clientCount > 0 ? '对端已加入组' : '对端尚未加入组';
        this.appendLog('P2P', `群组客户端数=${info.clientCount}（${detail}）`, LogLevels.DEBUG);
      }
    }).catch((e: Object): void => {
      logger.warn('查询群组客户端数失败: ' + String(e));
    });
  }

  // ── 资源释放 ──

  /** 页面退出时释放资源 */
  destroy(): void {
    this.endSession();
    this.clearCleanupTimer();
    this.clearWaitingWsTimeout();
    this.stopRustLogPolling();
    this.stopGroupClientPolling();
    this.unsubscribeNativeEvents();
    nativeMtaStopServer().catch((): void => {
    });
    this.ble.destroy();
    this.p2p.destroy();
    this.crypto.reset();
    let session = this.state.session;
    if (session !== undefined && session.taskId.length > 0) {
      this.deleteStageDir(session.taskId);
    }
  }
}
