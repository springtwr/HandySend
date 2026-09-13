/**
 * MtaSendService.ets — MTA 发送端编排门面
 *
 * 串联 BLE 扫描/连接、WiFi Direct 建组、Rust TLS/WS 服务器与文件传输，维护发送端状态机
 * （SenderState），并以事件回调方式向 ViewModel 推送状态快照。
 * 所有系统调用失败均转为可读文本写入日志，不向页面抛出异常。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  DecryptedCredentials,
  DeviceInfoJson,
  P2pInfoJson,
  truncateUtf8Text
} from '../../model/mta/MtaProtocolModels';
import {
  EncryptedCredentials,
  MTA_PEER_REJECTED_TEXT,
  MtaBleClientEventHandlers,
  MtaDiscoveredDevice,
  MtaGroupBandCandidate,
  MtaGroupInfo,
  MtaP2pGroupEventHandlers,
  MtaSendEventHandlers,
  MtaSendFile,
  MtaSendProgress,
  MtaSendSession,
  MtaSenderStage,
  SenderState,
  bandLabelFromFrequency,
  buildEntryName,
  mtaDeviceIdentityKey,
  mtaRejectReasonText,
  parseRustLogLine,
  randomGroupName,
  randomPassphrase,
  randomTaskId,
  resolvePreferredGroupBands,
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
import { resolveSendCompletedProgress } from '../../utils/MtaProgressUtil';
import { LogDomains } from '../../common/LogDomains';
import { LogLevels } from '../../common/LogLevels';

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
  /** 等待对端开始接收的超时定时器（-1 表示未运行） */
  private peerAcceptTimerId: number = -1;
  /** 传输阶段无进展看门狗定时器（-1 表示未运行） */
  private transferStallTimerId: number = -1;
  /** 上次群组客户端数（-1 表示未知） */
  private lastClientCount: number = -1;
  /** 建链计时起点（sendToDevice 进入时刻） */
  private linkStartMs: number = 0;
  /** P2pInfo 写回完成时刻（用于计算等待对端 WS 连接耗时） */
  private p2pInfoWrittenMs: number = 0;
  /** sendRequest 发出时刻（用于计算请求→开始下载耗时） */
  private requestSentMs: number = 0;

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
    // 会话终结即撤销"等待对端开始接收"窗口，避免终态后再次触发
    this.clearPeerAcceptTimeout();
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

  /** 追加一条 MTA 日志：正文前置子系统（`子系统: 内容`），经统一分级出口输出到 hilog */
  private appendLog(source: string, content: string, level: string): void {
    logger.log(level, `${source}: ${content}`);
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
    this.linkStartMs = Date.now();
    this.p2pInfoWrittenMs = 0;
    this.requestSentMs = 0;
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
    let gattConnectStartMs = Date.now();
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
    this.appendLog('计时', `GATT 连接耗时=${Date.now() - gattConnectStartMs}ms`, LogLevels.DEBUG);

    // 3) 读对端 DeviceInfo（含公钥）
    let remoteInfo: DeviceInfoJson;
    let readInfoStartMs = Date.now();
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
    this.appendLog('计时',
      `读取对端 DeviceInfo 耗时=${Date.now() - readInfoStartMs}ms（含 MTU 协商与服务发现）`, LogLevels.DEBUG);

    // 4) 创建 WiFi Direct 组：按候选逐个尝试「清理旧组 → 建组（频段 + 频点）→ 等待群组就绪」，
    //    非 Samsung 且对端支持 5GHz 时显式优先请求 5GHz（3s 有界就绪探测），
    //    超时/请求抛错即快速回退 2.4GHz；Samsung 或对端不支持 5GHz 时仅有 2.4GHz 候选；
    //    全部失败才判定建组失败。就绪后以实际群点为准，请求 5GHz 而实际落 2.4GHz 时按实际接受、不重复建组
    this.setStage(MtaSenderStage.GROUP_CREATING);
    let groupName = randomGroupName();
    let passphrase = randomPassphrase();
    let candidateBands = resolvePreferredGroupBands(device.brandId, device.is5Ghz);
    // 建组前记录本机并发 STA 频段快照：用于区分“并发 STA 频段约束”与“建组参数问题”
    this.appendLog('P2P', `本机 STA 频段快照：${this.p2p.getStaBandText()}`, LogLevels.DEBUG);
    let groupInfo: MtaGroupInfo | null = null;
    let groupTotalStartMs = Date.now();
    for (let i = 0; i < candidateBands.length; i++) {
      let candidate: MtaGroupBandCandidate = candidateBands[i];
      let goBand = candidate.band;
      let goFreq = candidate.freqMhz;
      let is5Ghz = goBand === MtaConstants.GROUP_OWNER_BAND_5GHZ;
      let bandText = is5Ghz ? '5GHz' : '2.4GHz';
      let freqText = goFreq > 0 ? `${goFreq}MHz` : '未限定';
      // 5GHz 候选施加受限的短就绪探测；2.4GHz 候选沿用既有较宽超时
      let readyTimeoutMs =
        is5Ghz ? MtaConstants.GROUP_READY_TIMEOUT_5GHZ_MS : MtaConstants.GROUP_READY_TIMEOUT_MS;
      // 每个候选开建前清理旧组：5GHz 超时/请求抛错后经此快速转入 2.4GHz 候选
      try {
        await this.p2p.removeGroup();
      } catch (e) {
        this.appendLog('P2P', '建组前清理旧组失败: ' + String(e), LogLevels.DEBUG);
      }
      if (await this.checkSessionAborted()) {
        return;
      }
      try {
        await this.p2p.createGroup(groupName, passphrase, goBand, goFreq);
        this.appendLog('P2P',
          `建组请求已发送 groupName=${groupName} goBand=${goBand}(${bandText}) goFreq=${freqText}` +
            `（候选 ${i + 1}/${candidateBands.length}）`,
          LogLevels.DEBUG);
      } catch (e) {
        this.appendLog('P2P',
          `建组请求失败 goBand=${goBand}(${bandText}) goFreq=${freqText}` +
            `（候选 ${i + 1}/${candidateBands.length}）: ${String(e)}`,
          LogLevels.WARN);
        continue;
      }
      let readyStartMs = Date.now();
      let info = await this.p2p.waitGroupReady(readyTimeoutMs);
      let readyCostMs = Date.now() - readyStartMs;
      if (await this.checkSessionAborted()) {
        return;
      }
      if (info !== null && info.ssid.length > 0) {
        groupInfo = info;
        // waitGroupReady 返回的 groupInfo 即 getCurrentGroup() 的当前结果，其 frequency 为实际群点；
        // 请求 5GHz 而平台实际落在 2.4GHz 时按实际频段接受，不重复建组
        this.appendLog('P2P',
          `候选建组就绪 goBand=${goBand}(${bandText}) goFreq=${freqText}` +
            `（候选 ${i + 1}/${candidateBands.length}）` +
            ` 耗时=${readyCostMs}ms 实际群点=${info.frequency}MHz(${bandLabelFromFrequency(info.frequency)})`,
          LogLevels.DEBUG);
        break;
      }
      let failureFreqText = info !== null && info.frequency > 0
        ? `${info.frequency}MHz(${bandLabelFromFrequency(info.frequency)})` : '未知';
      this.appendLog('P2P',
        `建组超时，未取得群组信息 goBand=${goBand}(${bandText}) goFreq=${freqText}` +
          `（候选 ${i + 1}/${candidateBands.length}）` +
          ` 耗时=${readyCostMs}ms 实际群点=${failureFreqText}`,
        LogLevels.WARN);
    }
    if (groupInfo === null) {
      await this.failSend('建组失败，未取得群组信息');
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
      `建组完成 ssid=${session.groupSsid} mac=${session.localMac} goIp=${session.goIp} ` +
        `频点=${session.groupFrequency}MHz(${bandLabelFromFrequency(session.groupFrequency)})`, LogLevels.INFO);
    this.appendLog('计时',
      `P2P 建组总耗时=${Date.now() - groupTotalStartMs}ms（候选数=${candidateBands.length}）`, LogLevels.DEBUG);

    // 5) 文件暂存到 cacheDir（picker URI 的临时授权仅在 ArkTS 侧有效）
    let stagedFiles: Array<MtaSendFile>;
    let stageStartMs = Date.now();
    try {
      stagedFiles = await this.stageFiles(effectiveFiles, session.taskId);
      session.files = stagedFiles;
      this.appendLog('暂存', `已暂存 ${stagedFiles.length} 个文件到 ${this.stageDir(session.taskId)}`, LogLevels.DEBUG);
      this.appendLog('计时',
        `文件暂存耗时=${Date.now() - stageStartMs}ms 文件数=${stagedFiles.length} 总字节=${session.totalBytes}`,
        LogLevels.DEBUG);
    } catch (e) {
      await this.failSend('文件暂存失败: ' + String(e));
      return;
    }

    // 6) 启动 Rust TLS 服务器并取实际端口（ZIP 由下载响应体流式生成）
    let serverStartMs = Date.now();
    this.setStage(MtaSenderStage.SERVER_STARTING);
    try {
      session.port = await this.startServer(session, stagedFiles, textValue);
      this.state.serverRunning = true;
      this.notifyState();
      this.appendLog('服务器', `TLS 服务器已启动 bindIp=${session.goIp} port=${session.port}`, LogLevels.INFO);
      this.appendLog('计时', `启动服务器耗时=${Date.now() - serverStartMs}ms`, LogLevels.DEBUG);
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
    let writeStartMs = Date.now();
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
    this.p2pInfoWrittenMs = Date.now();
    this.appendLog('计时', `写回 P2pInfo 耗时=${Date.now() - writeStartMs}ms`, LogLevels.DEBUG);
    this.setStage(MtaSenderStage.P2P_INFO_WRITTEN);
    this.setStage(MtaSenderStage.WAITING_WS);
    this.appendLog('服务', '等待对端建立 WS 连接...', LogLevels.DEBUG);
    this.startWaitingWsTimeout();
    // 轮询群组客户端数，判定对端是否已加入 WiFi Direct 组
    this.startGroupClientPolling();
  }

  /** 提交启动服务器请求并取回实际端口 */
  private async startServer(session: MtaSendSession, files: Array<MtaSendFile>,
    text: string): Promise<number> {
    let entries: Array<NativeMtaFileEntry> = [];
    for (let i = 0; i < files.length; i++) {
      let entry: NativeMtaFileEntry = {
        path: files[i].stagedPath,
        entryName: files[i].entryName,
        lastModifiedMs: files[i].lastModified
      };
      entries.push(entry);
    }
    let config: NativeMtaServerConfig = {
      bindIp: session.goIp.length > 0 ? session.goIp : MtaConstants.DEFAULT_BIND_IP,
      port: MtaConstants.DEFAULT_SEND_PORT,
      taskId: session.taskId,
      senderId: session.senderIdHex,
      senderName: session.senderName,
      files: entries
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
    // 超时兜底：服务器启动仅覆盖端口绑定与 TLS 初始化，正常为快操作；
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
      // 暂存复制前捕获源文件修改时间：复制会把副本时间置为当前时刻，
      // 必须先取原值，才能在打包时写入 ZIP 条目时间。fs.Stat.mtime 为距 1970 的秒数，
      // 统一转为 Unix 毫秒
      let lastModified: number | undefined = undefined;
      try {
        lastModified = Math.floor(fs.statSync(source.uri).mtime * 1000);
      } catch (_e) {
        lastModified = undefined;
      }
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
      out.lastModified = lastModified;
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

  /** 删除本次发送的暂存目录 */
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
        if (this.p2pInfoWrittenMs > 0) {
          this.appendLog('计时',
            `等待对端 WS 连接耗时=${Date.now() - this.p2pInfoWrittenMs}ms（写回 P2pInfo→WS 建连）`, LogLevels.DEBUG);
        }
        break;
      case 'mtaVersionNegotiated':
        this.setStage(MtaSenderStage.NEGOTIATED);
        this.appendLog('WS', `版本协商完成 version=${event.version}`, LogLevels.INFO);
        break;
      case 'mtaSendRequestSent':
        this.setStage(MtaSenderStage.REQUEST_SENT);
        this.requestSentMs = Date.now();
        // 请求已送达：武装"等待对端开始接收"的有界窗口，对端既未开始下载也未回送状态时给出可读结果
        this.startPeerAcceptTimeout();
        this.appendLog('WS', `已发送 sendRequest（任务=${event.taskId}）`, LogLevels.INFO);
        break;
      case 'mtaDownloadStarted':
        // 对端已开始下载即视为接受，撤销"等待对端开始接收"窗口，避免误伤后续传输
        this.clearPeerAcceptTimeout();
        this.setStage(MtaSenderStage.TRANSFERRING);
        // 进入传输阶段即武装无进展看门狗，覆盖对端静默消失（不关连接也不发状态）的情形
        this.resetTransferStallWatchdog();
        this.appendLog('下载', `对端开始下载 ZIP（任务=${event.taskId}）`, LogLevels.INFO);
        if (this.requestSentMs > 0) {
          this.appendLog('计时',
            `sendRequest→对端开始下载耗时=${Date.now() - this.requestSentMs}ms`, LogLevels.DEBUG);
        }
        if (this.linkStartMs > 0) {
          this.appendLog('计时',
            `发送建链总耗时=${Date.now() - this.linkStartMs}ms（开始发送→对端开始下载）`, LogLevels.DEBUG);
        }
        break;
      case 'mtaSendProgress': {
        let progress = new MtaSendProgress();
        progress.sentBytes = event.sentBytes;
        progress.totalBytes = event.totalBytes;
        progress.percent = Math.max(0, Math.min(100, Math.floor(event.percent)));
        this.state.progress = progress;
        // 每次进度到达即刷新看门狗：正常传输不会触发，只有真正停滞才判失败
        this.resetTransferStallWatchdog();
        this.notifyState();
        break;
      }
      case 'mtaSendCompleted':
        this.onSendCompleted(event.taskId);
        break;
      case 'mtaSendRejected':
        this.failSend(mtaRejectReasonText(event.reason));
        break;
      case 'mtaSendFailed':
        // 对端关闭 WS / 关闭下载连接 / 服务端下载被中止，均由 Rust 归一为发送失败事件，
        // 此处以可读原因结束本次发送并释放资源
        this.failSend(event.reason);
        break;
      default:
        break;
    }
  }

  /** 本次发送完成：保留传输中的源总字节并置 100%，随后标记完成并在延迟后释放资源 */
  private onSendCompleted(taskId: string): void {
    let declaredTotal = this.state.session !== undefined ? this.state.session.totalBytes : 0;
    this.state.progress = resolveSendCompletedProgress(this.state.progress, declaredTotal);
    // 终态已达成：清除传输看门狗，已完成结果不被迟到的失败/取消信号覆盖
    this.clearTransferStallWatchdog();
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
    this.clearPeerAcceptTimeout();
    this.clearTransferStallWatchdog();
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
      // 仅在会话仍停留在等待 WS 阶段时判定失败（对端解密凭据失败/P2P 连接失败/异常退出）
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

  // ── 等待对端开始接收窗口（对端拒绝但静默时兜底） ──

  /**
   * 武装"等待对端开始接收"窗口：在已发出 sendRequest 且对端尚未开始下载时生效。
   * 对端既未开始下载、也未回送状态、也未断开时，窗口到期即判定对方未接收并结束本次发送，
   * 避免一直停留在「已发送传输请求」干等到 Rust 侧 180s 状态等待超时（届时用户毫无反馈）。
   */
  private startPeerAcceptTimeout(): void {
    this.clearPeerAcceptTimeout();
    this.peerAcceptTimerId = setTimeout(() => {
      this.peerAcceptTimerId = -1;
      // 仅在仍停留在"已发请求、对端尚未开始下载"阶段时判定未被接收
      if (this.sessionActive && this.state.stage === MtaSenderStage.REQUEST_SENT) {
        this.appendLog('服务',
          `等待对端开始接收超时（${MtaConstants.PEER_ACCEPT_TIMEOUT_MS}ms），判定对方未接收`, LogLevels.WARN);
        this.failSend(MTA_PEER_REJECTED_TEXT);
      }
    }, MtaConstants.PEER_ACCEPT_TIMEOUT_MS);
  }

  /** 清除"等待对端开始接收"窗口定时器 */
  private clearPeerAcceptTimeout(): void {
    if (this.peerAcceptTimerId >= 0) {
      clearTimeout(this.peerAcceptTimerId);
      this.peerAcceptTimerId = -1;
    }
  }

  // ── 传输阶段看门狗（对端静默消失兜底） ──

  /**
   * 武装/重置传输阶段看门狗：进入传输后持续无进展超过阈值即判定对端静默中止。
   * 正常传输会持续上报进度（每次进度都会重置），故不会误伤慢速大文件；
   * 仅作为下载连接断开（Rust 立即终止）之外的静默情形兜底，不缩短全局状态等待超时。
   */
  private resetTransferStallWatchdog(): void {
    this.clearTransferStallWatchdog();
    this.transferStallTimerId = setTimeout(() => {
      this.transferStallTimerId = -1;
      // 仅在仍处于传输中且会话未终结时判定失败（已完成/已取消不被迟到信号覆盖）
      if (this.sessionActive && this.state.stage === MtaSenderStage.TRANSFERRING) {
        this.failSend(`传输长时间无进展（${MtaConstants.TRANSFER_STALL_TIMEOUT_MS}ms），判定对端已中止`);
      }
    }, MtaConstants.TRANSFER_STALL_TIMEOUT_MS);
  }

  /** 清除传输阶段看门狗 */
  private clearTransferStallWatchdog(): void {
    if (this.transferStallTimerId >= 0) {
      clearTimeout(this.transferStallTimerId);
      this.transferStallTimerId = -1;
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
    this.clearPeerAcceptTimeout();
    this.clearTransferStallWatchdog();
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
