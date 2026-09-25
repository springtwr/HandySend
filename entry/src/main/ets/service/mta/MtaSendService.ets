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
  MTA_CANCEL_NOTIFY_FAILED_TEXT,
  MTA_CANCELLED_TEXT,
  MTA_PARTIAL_COMPLETED_TEXT,
  MTA_PEER_ABANDONED_TEXT,
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
  randomGroupName,
  randomPassphrase,
  randomTaskId,
  resolvePreferredGroupBands,
  totalFileBytes
} from '../../model/mta/MtaSendModels';
import { NativeEvent, NativeMtaFileEntry, NativeMtaServerConfig } from '../../model/NativeTypes';
import { MTA_SHARED_TEXT_FILE_NAME } from '../../model/mta/MtaMainModels';
import {
  nativeMtaRejectPeer,
  nativeMtaStartServer,
  nativeMtaStopServer,
  offBridgeEvent,
  onBridgeEvent
} from '../NativeBridge';
import { MtaConstants } from './MtaConstants';
import { MtaBleClient } from './MtaBleClient';
import {
  drainRustLog, utf8ByteLength
} from './MtaBleCommon';
import { MtaCrypto } from './MtaCrypto';
import { MtaP2pGroup } from './MtaP2pGroup';
import { MTA_BRAND_ID_THIRD_PARTY, resolveMtaBrandName } from '../../model/mta/MtaBrandRegistry';
import { getDeviceAlias } from '../repository/DeviceRepository';
import { getMtaSimulatedBrand } from '../repository/SettingsRepository';
import { sendTextDir } from '../repository/SendRepository';
import { getLogger } from '../../utils/Logger';
import { formatSpeed } from '../../utils/FormatUtil';
import { resolveSendCompletedProgress } from '../../utils/MtaProgressUtil';
import { LogDomains } from '../../common/LogDomains';
import { LogLevels } from '../../common/LogLevels';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaSend', '互传发送');

// ── 对端退出 P2P 组判定（纯函数：无副作用、不依赖系统 API，可导出单测） ──

/** 「对端是否已退出本次 P2P 组」的判定结果（纯数据契约）。 */
export class MtaPeerGroupAbandonDecision {
  /** 新的连续归零次数（0 表示客户端数正常，或当前不在等待确认阶段） */
  zeroStreak: number = 0;
  /** 是否判定对端已放弃（连续归零次数达到阈值） */
  abandoned: boolean = false;
}

/**
 * 判定「对端是否已退出本次 P2P 组」（纯函数，无副作用、不依赖系统 API）。
 *
 * 仅在等待确认阶段生效：该阶段对端本应稳定留在组内，客户端数归零是最早可观测的
 * 「对端已放弃」信号。客户端数用 `-1` 表示群组信息不可得，同样计入归零。
 * 连续归零次数达到 `GROUP_CLIENT_ZERO_STREAK_LIMIT` 才判放弃，避免瞬时重连/读数抖动误判；
 * 非等待确认阶段、以及客户端数回升时计数清零。
 */
export function decidePeerGroupAbandon(stage: MtaSenderStage, lastClientCount: number,
  clientCount: number, zeroStreak: number): MtaPeerGroupAbandonDecision {
  let decision = new MtaPeerGroupAbandonDecision();
  // 仅等待确认阶段生效：其余阶段对端是否在组内不构成「放弃」信号
  if (stage !== MtaSenderStage.WAITING_PEER_CONFIRM) {
    return decision;
  }
  // 客户端数回升（>=1）：对端仍在组内，计数清零
  if (clientCount >= 1) {
    return decision;
  }
  // 累计归零的触发条件：上次已观测到对端在组内（由 >=1 降为 0）、已在防抖累计中（上次已归零），
  // 或本次群组信息不可得（-1，视为对端已离组的强信号）
  let startCounting = lastClientCount >= 1 || zeroStreak > 0 || clientCount < 0;
  if (!startCounting) {
    return decision;
  }
  decision.zeroStreak = zeroStreak + 1;
  decision.abandoned = decision.zeroStreak >= MtaConstants.GROUP_CLIENT_ZERO_STREAK_LIMIT;
  return decision;
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
  /** 等待确认阶段连续观测到「群组客户端数归零 / 群组不可得」的次数（用于退组防抖判定） */
  private groupClientZeroStreak: number = 0;
  /** 建链计时起点（sendToDevice 进入时刻） */
  private linkStartMs: number = 0;
  /** P2pInfo 写回完成时刻（用于计算等待对端 WS 连接耗时） */
  private p2pInfoWrittenMs: number = 0;
  /** sendRequest 发出时刻（用于计算请求→开始下载耗时） */
  private requestSentMs: number = 0;
  /** 本次会话是否已输出过「请求→结果」耗时日志（保证每会话至多一条） */
  private peerResultLogged: boolean = false;
  /** 对端开始下载时刻（用于计算传输阶段耗时；0 表示尚未开始下载） */
  private downloadStartedMs: number = 0;
  /** 已打开、尚未移交 Rust 的发送直读 fd（移交点见 startServer；移交前失败/取消由 closePendingSendFds 关闭） */
  private pendingSendFileHandles: Array<fs.File> = [];
  /** 资源释放一次性守卫：同一会话只真正释放一次（随会话起始复位） */
  private resourcesReleased: boolean = false;
  /** 取消通知等待的结算器（非 null 表示正在等待对端被通知） */
  private cancelWaitResolve: ((notified: boolean) => void) | null = null;
  /** 取消通知等待上限定时器（-1 表示未运行） */
  private cancelWaitTimerId: number = -1;
  /** 取消通知等待起始时刻（毫秒，用于输出等待耗时） */
  private cancelWaitStartMs: number = 0;

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
    this.appendLog('服务', `MTA 发送页就绪，发送者 ID=${this.senderIdHex} 发送者名称=${this.senderName}`,
      LogLevels.INFO);
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
    // 会话终结（完成/失败/取消）时清零下载开始时刻，避免跨会话残留
    this.downloadStartedMs = 0;
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
    // 取消流程已启动：仅允许取消阶段/终态，避免迟到的链路阶段推进覆盖取消呈现
    if (this.cancelledThisSession && stage !== MtaSenderStage.CANCEL_NOTIFYING
      && stage !== MtaSenderStage.CANCELLED) {
      return;
    }
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
  }

  // ── 发送流程 ──

  /**
   * 建立发送链路并启动传输：GATT 连接 → 读对端 DeviceInfo（含公钥）→ 建 WiFi Direct 组
   * → 打开直读 fd（文件直读源 URI，不复制；文本条目走落盘文本文件）→ 启动 Rust TLS
   * 服务器取真实端口 → 加密凭据并写回 P2pInfo → 等待对端协商/下载。
   */
  async sendToDevice(device: MtaDiscoveredDevice, files: Array<MtaSendFile>,
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
    this.peerResultLogged = false;
    this.downloadStartedMs = 0;
    this.sessionActive = true;
    this.cancelledThisSession = false;
    this.resourcesReleased = false;
    this.groupClientZeroStreak = 0;
    this.state.selected = device;
    let session = new MtaSendSession();
    session.taskId = randomTaskId();
    session.senderIdHex = this.senderIdHex;
    session.senderName = this.senderName;
    this.state.session = session;
    this.state.lastError = '';
    this.state.groupCreated = false;
    this.state.serverRunning = false;
    this.state.progress = new MtaSendProgress();
    // 文本发送：把文本写入发送文本目录（filesDir/text_send/）的 sharedText.txt，作为唯一 ZIP 条目（1/sharedText.txt）
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
    // 打包前依序校验条目数 → 总大小 → 单文件，各档独立提示，超限快速失败，
    // 避免传输完成后才被接收端解压校验拒绝
    if (effectiveFiles.length > MtaConstants.MAX_SEND_ENTRY_COUNT) {
      await this.failSend(`文件数超过上限 ${MtaConstants.MAX_SEND_ENTRY_COUNT}`);
      return;
    }
    if (session.totalBytes > MtaConstants.MAX_SEND_TOTAL_BYTES) {
      await this.failSend(`总大小超过上限 ${MtaConstants.MAX_SEND_TOTAL_BYTES} 字节`);
      return;
    }
    for (let i = 0; i < effectiveFiles.length; i++) {
      if (effectiveFiles[i].sizeBytes > MtaConstants.MAX_SEND_FILE_BYTES) {
        await this.failSend(
          `文件 ${effectiveFiles[i].displayName} 超过单文件上限 ${MtaConstants.MAX_SEND_FILE_BYTES} 字节`);
        return;
      }
    }
    this.appendLog('服务', `开始发送到 ${device.deviceName} (${device.bleAddress})，任务=${session.taskId}`,
      LogLevels.INFO);

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
      // 5GHz 候选施加受限的短就绪探测；2.4GHz 候选使用较宽超时
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

    // 5) 打开发送直读 fd（picker URI 的临时授权仅在 ArkTS 侧有效；直读源文件不复制，
    //    文本会话的落盘文本文件仍走路径，不在此打开 fd）
    let sendFiles: Array<MtaSendFile>;
    let stageStartMs = Date.now();
    try {
      sendFiles = this.openSendFds(effectiveFiles);
      // 实际大小/修改时间以源 URI stat 结果为准，重算会话总字节（进度分母与 Rust 一致）
      session.totalBytes = totalFileBytes(sendFiles);
      session.files = sendFiles;
      this.appendLog('直读', `已打开 ${sendFiles.length} 个文件的直读 fd（源 URI 直读，无暂存复制）`, LogLevels.DEBUG);
      this.appendLog('计时',
        `打开直读 fd 耗时=${Date.now() - stageStartMs}ms 文件数=${sendFiles.length} 总字节=${session.totalBytes}`,
        LogLevels.DEBUG);
    } catch (e) {
      await this.failSend('打开发送直读 fd 失败: ' + String(e));
      return;
    }
    // 移交点检查：fd 尚未移交 Rust，会话若已终止则在此统一关闭全部已开 fd
    if (await this.checkSessionAborted()) {
      return;
    }

    // 6) 启动 Rust TLS 服务器并取实际端口（ZIP 由下载响应体流式生成；startServer 内
    //    nativeMtaStartServer 调用即 fd 移交点，之后 ArkTS 不再触碰任何 fd）
    let serverStartMs = Date.now();
    this.setStage(MtaSenderStage.SERVER_STARTING);
    try {
      session.port = await this.startServer(session, sendFiles, textValue);
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
    if (remoteInfo.key.length > 0) {
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
        // 文件条目透传下载直读 fd（fdSend >= 0 时 Rust 直读源文件，path 仅作容错回退）；
        // 文本条目 fd 缺省 -1，走 path 指向的落盘文本文件
        path: files[i].uri,
        entryName: files[i].entryName,
        lastModifiedMs: files[i].lastModified,
        sizeBytes: files[i].sizeBytes,
        fdSend: files[i].fdSend
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
    // 移交点：config 移交即 fd 所有权移交——无论启动成败，全部 fd 均由 Rust 收尾。
    // 自此之后的任何失败/取消路径 ArkTS 不再关闭这些 fd，避免与 Rust 侧重复关闭
    // （双关会触发进程 abort）。
    let startPromise = nativeMtaStartServer(config);
    this.pendingSendFileHandles = [];
    startPromise.catch((_e: Object): void => {
    });
    let timeoutPromise = new Promise<number>((_resolve, reject) => {
      setTimeout(() => {
        reject(new Error(`启动服务器超时（${MtaConstants.SERVER_START_TIMEOUT_MS}ms）`));
      }, MtaConstants.SERVER_START_TIMEOUT_MS);
    });
    return await Promise.race([startPromise, timeoutPromise]);
  }

  /** 文本发送：把文本内容写入落盘目录的文本文件，返回待暂存条目 */
  private writeSharedTextFile(taskId: string, text: string): MtaSendFile {
    // 文本即文件：写入应用私有持久目录下的发送文本目录（filesDir/text_send/），
    // 由「清除任务历史」统一清理；对端可见的条目名保持 MTA_SHARED_TEXT_FILE_NAME 不变（协议行为不变）
    let dir = this.textSendDir();
    this.ensureStageDir(dir);
    let path = `${dir}sharedText_${taskId}.txt`;
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
    return out;
  }

  /** 发送文本的落盘目录：应用私有持久目录下的发送文本目录（写入与清空共用同一路径来源） */
  private textSendDir(): string {
    return sendTextDir();
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

  // ── 文本发送持久目录辅助 ──

  /**
   * 确保目录存在。
   * HarmonyOS 的 mkdirSync 递归模式对已存在目录仍会抛 EEXIST，故先判断再创建，
   * 避免同一任务内多次准备目录时产生误报告警。
   */
  private ensureStageDir(dir: string): void {
    if (!fs.accessSync(dir, fs.AccessModeType.EXIST)) {
      fs.mkdirSync(dir, true);
    }
  }

  /**
   * 打开发送直读 fd：逐文件以 `fs.openSync(uri, READ_ONLY)` 打开读取入口（fdSend），
   * 并以 `fs.statSync(uri)` 取源文件大小与修改时间。任一文件任一步骤失败都会关闭本次
   * 已打开的全部 fd 并抛可读错误；成功时 fd 暂存于 `pendingSendFileHandles`，
   * 由 `startServer` 在移交点转交 Rust。
   * 不向 cacheDir 复制所选文件（文本会话的临时文件由 writeSharedTextFile 单独处理）。
   */
  private openSendFds(files: Array<MtaSendFile>): Array<MtaSendFile> {
    let opened: Array<fs.File> = [];
    let out: Array<MtaSendFile> = [];
    try {
      for (let i = 0; i < files.length; i++) {
        let source = files[i];
        let fdSendFile = fs.openSync(source.uri, fs.OpenMode.READ_ONLY);
        opened.push(fdSendFile);
        let stat = fs.statSync(source.uri);
        let item = new MtaSendFile();
        item.uri = source.uri;
        item.displayName = source.displayName;
        item.sizeBytes = stat.size;
        item.entryName = buildEntryName(i, source.displayName);
        // fs.Stat.mtime 为距 1970 的秒数，统一转为 Unix 毫秒
        item.lastModified = Math.floor(stat.mtime * 1000);
        item.fdSend = fdSendFile.fd;
        out.push(item);
      }
    } catch (e) {
      // 任一步骤失败：关闭本次已打开的全部 fd（含当前文件已打开的部分），上抛时不泄漏
      this.closeOpenedFiles(opened);
      let failedName = out.length < files.length ? files[out.length].displayName : '';
      throw new Error(`打开文件直读 fd 失败 ${failedName}: ${String(e)}`);
    }
    this.pendingSendFileHandles = opened;
    return out;
  }

  /** 关闭一批已打开的发送直读 fd（幂等；供 openSendFds 局部失败与移交前收尾使用） */
  private closeOpenedFiles(files: Array<fs.File>): void {
    for (let i = 0; i < files.length; i++) {
      try {
        fs.closeSync(files[i]);
      } catch (e) {
        logger.warn('关闭发送直读 fd 失败: ' + String(e));
      }
    }
  }

  /**
   * 关闭尚未移交 Rust 的发送直读 fd（幂等）。仅在 fd 所有权仍属 ArkTS 侧时调用
   * （即 `startServer` 中 `nativeMtaStartServer` 调用之前）；该调用点已把
   * `pendingSendFileHandles` 清空，移交后的收尾由 Rust 负责，本方法不触碰任何 fd。
   */
  private closePendingSendFds(): void {
    this.closeOpenedFiles(this.pendingSendFileHandles);
    this.pendingSendFileHandles = [];
  }

  // ── Rust Mta* 事件订阅与状态推进 ──

  /** 订阅全部 Mta* 桥接事件（同一回调便于退订） */
  private subscribeNativeEvents(): void {
    if (this.nativeSubscribed) {
      return;
    }
    let types: Array<string> = [
      'mtaServerStarted', 'mtaWsConnected', 'mtaVersionNegotiated', 'mtaSendRequestSent',
      'mtaRejectSent', 'mtaDownloadStarted', 'mtaSendProgress', 'mtaSendCompleted',
      'mtaSendPartial', 'mtaSendRejected', 'mtaSendFailed'
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
      'mtaRejectSent', 'mtaDownloadStarted', 'mtaSendProgress', 'mtaSendCompleted',
      'mtaSendPartial', 'mtaSendRejected', 'mtaSendFailed'
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
    // 取消流程已启动：等待期内只有"取消状态已回送"可结算等待，其余迟到事件
    // 一律不推进状态机，保证已取消终态不被迟到的完成/失败信号覆盖
    if (this.cancelledThisSession && event.type !== 'mtaRejectSent') {
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
        this.setStage(MtaSenderStage.WAITING_PEER_CONFIRM);
        this.requestSentMs = Date.now();
        // 请求已送达：武装"等待对端开始接收"的有界窗口，对端既未开始下载也未回送状态时给出可读结果
        this.startPeerAcceptTimeout();
        this.appendLog('WS', `已发送 sendRequest（任务=${event.taskId}）`, LogLevels.INFO);
        break;
      case 'mtaRejectSent':
        // 取消状态已写入对端连接：结算取消通知等待（记为已通知对端）
        this.settleCancelWait(true, '已回送取消状态');
        break;
      case 'mtaDownloadStarted':
        // 对端已开始下载即视为接受，撤销"等待对端开始接收"窗口，避免误伤后续传输
        this.clearPeerAcceptTimeout();
        this.setStage(MtaSenderStage.TRANSFERRING);
        // 进入传输阶段即武装无进展看门狗，覆盖对端静默消失（不关连接也不发状态）的情形
        this.resetTransferStallWatchdog();
        // 记录下载开始时刻，供发送完成时输出传输阶段耗时
        this.downloadStartedMs = Date.now();
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
        // 网络字节口径：压缩生效时出网字节少于已读源字节，速率以此为准
        progress.networkBytes = event.networkBytes;
        this.state.progress = progress;
        // 每次进度到达即刷新看门狗：正常传输不会触发，只有真正停滞才判失败
        this.resetTransferStallWatchdog();
        this.notifyState();
        break;
      }
      case 'mtaSendCompleted':
        this.onSendCompleted(event.taskId);
        break;
      case 'mtaSendPartial':
        this.onSendPartial(event.reason);
        break;
      case 'mtaSendRejected':
        this.failSend(mtaRejectReasonText(event.reason));
        break;
      case 'mtaSendFailed':
        // 对端关闭 WS / 关闭下载连接 / 服务端下载被中止，均由 Rust 归一为发送失败事件，
        // 此处以可读原因结束本次发送并释放资源。
        // 等待确认阶段的「对端关闭连接 / 读取失败 / 状态等待超时」统一呈现为「对方已放弃接收」，
        // 原始原因完整保留在日志中；更早链路阶段与传输阶段保持既有文案
        if (this.state.stage === MtaSenderStage.WAITING_PEER_CONFIRM) {
          this.appendLog('服务', `等待确认阶段收到失败：${event.reason}`, LogLevels.WARN);
          this.failSend(MTA_PEER_ABANDONED_TEXT);
        } else {
          this.failSend(event.reason);
        }
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
    this.logPeerResultOnce('完成');
    this.logTransferDuration();
    this.endSession();
    this.scheduleCleanup();
  }

  /**
   * 本次发送仅部分完成：对端回送成功类型 + 部分接收原因（只收了部分文件）。
   * 不得走发送成功路径（不置 COMPLETED、不按成功收敛进度），结果与资源收尾语义
   * 与失败路径一致：记录原因、进入部分完成阶段、结束会话并释放资源。
   */
  private async onSendPartial(reason: string): Promise<void> {
    // 已被用户取消的会话保持 CANCELLED 终态，不再被旧链路的迟到状态覆盖
    if (this.cancelledThisSession) {
      return;
    }
    this.clearTransferStallWatchdog();
    this.setError(MTA_PARTIAL_COMPLETED_TEXT);
    this.setStage(MtaSenderStage.PARTIAL);
    this.appendLog('服务',
      `本次发送仅部分完成（对端未收全）原因=${reason.length > 0 ? reason : '未提供'}`, LogLevels.WARN);
    this.logPeerResultOnce('部分完成');
    this.endSession();
    await this.releaseSendResources();
  }

  /** 输出传输阶段耗时日志：下载开始→发送完成的耗时、源总字节与平均速率 */
  private logTransferDuration(): void {
    if (this.downloadStartedMs <= 0) {
      return;
    }
    let transferCostMs = Date.now() - this.downloadStartedMs;
    let totalBytes = this.state.progress.totalBytes;
    let seconds = transferCostMs / 1000;
    let avgSpeed = seconds > 0 ? totalBytes / seconds : 0;
    this.appendLog('计时',
      `传输耗时=${transferCostMs}ms（下载开始→发送完成） 总字节=${totalBytes} 平均速率=${formatSpeed(avgSpeed)}`,
      LogLevels.DEBUG);
  }

  /**
   * 输出一次「请求→结果」耗时日志：仅在已记录 sendRequest 发出时刻且本会话尚未输出过时生效，
   * 保证每会话至多一条，用于核对对端响应是否符合其确认窗口预期。
   */
  private logPeerResultOnce(outcome: string): void {
    if (this.requestSentMs <= 0 || this.peerResultLogged) {
      return;
    }
    this.peerResultLogged = true;
    this.appendLog('计时',
      `请求→结果耗时=${Date.now() - this.requestSentMs}ms（结果=${outcome}）`, LogLevels.DEBUG);
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
    this.logPeerResultOnce('失败');
    this.endSession();
    await this.releaseSendResources();
  }

  /** 释放一次发送占用的全部资源（服务器/GATT/群组/暂存文件/未移交直读 fd） */
  private async releaseSendResources(): Promise<void> {
    // 一次性守卫：等待结算与页面销毁两条路径并发时只真正释放一次
    //（`ble.destroy()` 与 `disconnectGattClient()` 叠加调用存在风险）
    if (this.resourcesReleased) {
      return;
    }
    this.resourcesReleased = true;
    this.clearCleanupTimer();
    this.clearWaitingWsTimeout();
    this.clearPeerAcceptTimeout();
    this.clearTransferStallWatchdog();
    this.stopGroupClientPolling();
    // 尚未移交 Rust 的发送直读 fd 在此关闭；已移交的（pendingSendFileHandles 已清空）
    // 由 Rust 侧负责收尾，本处不会重复关闭
    this.closePendingSendFds();
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
    this.notifyState();
  }

  // ── 取消与清理 ──

  /**
   * 取消进行中的发送：登记"向对端回送取消"意图，在有界窗口内等待对端被通知
   * （对端回送取消状态 / 等待上限到期 / 用户直接返回，先到者结算），
   * 随后结束会话、置取消终态并释放资源。
   *
   * 等待期内不结束会话：接收服务保持暂停、收发互斥保持占用，与"会话终态才恢复接收"
   * 的既有语义一致；等待有界（不超过取消通知等待上限），资源占用可预期。
   */
  async cancelSend(): Promise<void> {
    // 会话进行中才可取消：已终结的会话（完成/部分成功/失败）保持原终态，
    // 不得把 FAILED 等终态覆盖为「已取消」
    if (!this.sessionActive) {
      this.appendLog('服务', '当前无进行中的发送，无需取消', LogLevels.INFO);
      return;
    }
    if (this.cancelWaitResolve !== null) {
      this.appendLog('服务', '已在等待通知对方取消，忽略重复取消', LogLevels.INFO);
      return;
    }
    let cancelStartMs = Date.now();
    this.appendLog('服务', '用户取消发送', LogLevels.INFO);
    this.cancelledThisSession = true;
    this.setStage(MtaSenderStage.CANCEL_NOTIFYING);
    // 服务器运行中即对端仍可能接入（已写回 P2pInfo）：保留链路并等待对端被通知；
    // 更早阶段（GATT/建组/起服前）对端尚未取得凭据、无法接入，按未通知直接收尾
    let notified = false;
    if (this.state.serverRunning) {
      let registered = true;
      try {
        nativeMtaRejectPeer();
      } catch (e) {
        // 登记意图失败即无法回送取消状态：按未通知直接收尾，不进入等待
        registered = false;
        this.appendLog('服务', '登记回送取消意图失败: ' + String(e), LogLevels.ERROR);
      }
      if (registered) {
        notified = await this.waitCancelNotify();
      }
    } else {
      this.appendLog('服务', '对端尚未取得连接凭据，无法通知取消，直接收尾', LogLevels.WARN);
    }
    this.endSession();
    this.setError(notified ? MTA_CANCELLED_TEXT : MTA_CANCEL_NOTIFY_FAILED_TEXT);
    this.setStage(MtaSenderStage.CANCELLED);
    await this.releaseSendResources();
    this.appendLog('服务', `已取消本次发送并释放资源 耗时=${Date.now() - cancelStartMs}ms`, LogLevels.INFO);
  }

  /**
   * 等待对端被通知取消：由"已回送取消状态"事件、等待上限定时器、用户直接返回
   * 三者中先到者结算，返回是否已通知到对端。
   */
  private waitCancelNotify(): Promise<boolean> {
    return new Promise<boolean>((resolve: (notified: boolean) => void): void => {
      this.cancelWaitStartMs = Date.now();
      this.cancelWaitResolve = resolve;
      this.cancelWaitTimerId = setTimeout((): void => {
        this.cancelWaitTimerId = -1;
        this.settleCancelWait(false, '等待上限到期');
      }, MtaConstants.CANCEL_NOTIFY_WAIT_TIMEOUT_MS);
    });
  }

  /**
   * 一次性结算取消通知等待：记录"已通知/未能通知"与等待耗时，并唤醒等待方。
   * 重复调用或非等待期调用为空操作。
   */
  private settleCancelWait(notified: boolean, source: string): void {
    let resolve = this.cancelWaitResolve;
    if (resolve === null) {
      return;
    }
    this.cancelWaitResolve = null;
    if (this.cancelWaitTimerId >= 0) {
      clearTimeout(this.cancelWaitTimerId);
      this.cancelWaitTimerId = -1;
    }
    let costMs = this.cancelWaitStartMs > 0 ? Date.now() - this.cancelWaitStartMs : 0;
    let outcome = notified ? '已通知对端取消' : '未能通知对端取消';
    this.appendLog('服务', `${outcome}（${source}，等待=${costMs}ms）`, notified ? LogLevels.INFO : LogLevels.WARN);
    resolve(notified);
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

  /** 排空 Rust 日志缓冲并追加 MTA 相关行（共用实现见 MtaBleCommon） */
  private drainRustLog(): void {
    drainRustLog((source: string, message: string, level: string): void => {
      this.appendLog(source, message, level);
    }, (message: string): void => {
      logger.warn(message);
    });
  }

  // ── 群组客户端轮询（诊断对端是否加入 WiFi Direct 组） ──

  /** 启动群组客户端数轮询 */
  private startGroupClientPolling(): void {
    if (this.groupClientTimerId >= 0) {
      return;
    }
    this.lastClientCount = -1;
    this.groupClientZeroStreak = 0;
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
   * 避免一直停留在「等待对方确认」干等到 Rust 侧 180s 状态等待超时（届时用户毫无反馈）。
   */
  private startPeerAcceptTimeout(): void {
    this.clearPeerAcceptTimeout();
    this.peerAcceptTimerId = setTimeout(() => {
      this.peerAcceptTimerId = -1;
      // 仅在仍停留在"已发请求、对端尚未开始下载"阶段时判定未被接收
      if (this.sessionActive && this.state.stage === MtaSenderStage.WAITING_PEER_CONFIRM) {
        // 可归因判定：有界窗口内未收到对端任何结果（无 status、未开始下载），
        // 与 Rust 侧会话收尾统计（收到对端报文数）配对，即可区分「对端未发送」与「本端漏收」
        this.appendLog('服务',
          `等待对端开始接收窗口到期（${MtaConstants.PEER_ACCEPT_TIMEOUT_MS}ms）：窗口期内未收到对端任何结果，判定对方未接收`,
          LogLevels.WARN);
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

  /** 查询群组客户端数：变化时记录（判断对端是否已加入组），并在等待确认阶段判定对端是否已退组 */
  private pollGroupClient(): void {
    this.p2p.getCurrentGroup().then((info: MtaGroupInfo | null): void => {
      // 群组信息不可得以 -1 参与判定：等待确认阶段该信号同样表示对端可能已离组
      let clientCount = info !== null ? info.clientCount : -1;
      let decision = decidePeerGroupAbandon(this.state.stage, this.lastClientCount, clientCount,
        this.groupClientZeroStreak);
      this.groupClientZeroStreak = decision.zeroStreak;
      if (info !== null && info.clientCount !== this.lastClientCount) {
        this.lastClientCount = info.clientCount;
        let detail = info.clientCount > 0 ? '对端已加入组' : '对端尚未加入组';
        this.appendLog('P2P', `群组客户端数=${info.clientCount}（${detail}）`, LogLevels.DEBUG);
      }
      if (decision.abandoned) {
        // 等待确认阶段对端已退出本次 P2P 组：立即以「对方已放弃接收」终结，不空等窗口到期
        this.appendLog('服务',
          `等待确认阶段对端已退出本次 P2P 组（连续 ${decision.zeroStreak} 次观测客户端数归零/群组不可得）`,
          LogLevels.WARN);
        this.failSend(MTA_PEER_ABANDONED_TEXT);
      }
    }).catch((e: Object): void => {
      logger.warn('查询群组客户端数失败: ' + String(e));
    });
  }

  // ── 资源释放 ──

  /** 页面退出时释放资源 */
  destroy(): void {
    // 释放入口置空事件回调：实例被释放后不再向适配器投递任何状态事件
    // （在途的异步收尾仍会执行到 notifyState，此时因回调已置空而静默）
    this.handlers = null;
    // 页面销毁（系统返回/标题返回）等价于"直接返回"：先结算取消通知等待，避免取消流程悬挂；
    // 随后由本方法完成释放并置一次性守卫，使取消流程不再重复释放
    this.settleCancelWait(false, '页面销毁');
    this.endSession();
    this.resourcesReleased = true;
    this.clearCleanupTimer();
    this.clearWaitingWsTimeout();
    this.clearPeerAcceptTimeout();
    this.clearTransferStallWatchdog();
    this.stopRustLogPolling();
    this.stopGroupClientPolling();
    this.unsubscribeNativeEvents();
    // 页面退出兜底：关闭尚未移交 Rust 的发送直读 fd（已移交的由 Rust 收尾）
    this.closePendingSendFds();
    nativeMtaStopServer().catch((): void => {
    });
    this.ble.destroy();
    this.p2p.destroy();
    this.crypto.reset();
  }
}
