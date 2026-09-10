/**
 * MtaReceiveService.ets — MTA 接收端编排门面
 *
 * 串联 BLE 凭据通道、P2P 凭据直连、WS 协商与 HTTPS 下载解压，维护接收端状态机
 * （ReceiverState）与日志流（ReceiverLogEntry），并以事件回调方式向 ViewModel 推送
 * 状态快照与新增日志。所有系统调用失败均转为可读文本写入日志，不向页面抛出异常。
 */

import { common, bundleManager } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import {
  DecryptedCredentials,
  DeviceInfoJson,
  DownloadProgress,
  MtaBleEventHandlers,
  MtaP2pEventHandlers,
  MtaReceiveEventHandlers,
  MtaTransferEventHandlers,
  P2pInfoJson,
  ReceiverLogEntry,
  ReceiverStage,
  ReceiverState,
  ReceiveRequest,
  formatTimeText,
  parseP2pInfo
} from '../../model/mta/MtaReceiveModels';
import { MtaConstants } from './MtaConstants';
import { MtaCrypto } from './MtaCrypto';
import { MtaBleReceiver } from './MtaBleReceiver';
import { MtaP2pConnector, P2pConnectResult } from './MtaP2pConnector';
import { MtaTransferClient, DownloadResult } from './MtaTransferClient';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { ReceiveHistoryEntry } from '../../model/Types';
import { MTA_SHARED_TEXT_FILE_NAME } from '../../model/mta/MtaMainModels';
import { isSaveToHistory } from '../repository/SettingsRepository';
import { addEntry } from '../repository/ReceiveHistoryService';

const logger = getLogger(LogDomains.NETWORK, 'HandySend:MtaReceive');

/** 文本 UTF-8 字节长度（避免引入额外编码依赖） */
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

/** 接收端服务编排门面 */
export class MtaReceiveService {
  /** 当前状态（对外仅暴露快照） */
  private state: ReceiverState = new ReceiverState();
  /** 日志流（上限 MtaConstants.MAX_LOG_ENTRIES） */
  private logs: Array<ReceiverLogEntry> = [];
  /** 事件回调（ViewModel 注入） */
  private handlers: MtaReceiveEventHandlers | null = null;
  /** 应用上下文（权限申请用） */
  private context: common.Context | undefined = undefined;
  /** 加解密模块 */
  private crypto: MtaCrypto = new MtaCrypto();
  /** BLE 接收模块（广播 + GATT Server） */
  private ble: MtaBleReceiver = new MtaBleReceiver();
  /** BLE 事件回调 */
  private bleHandlers: MtaBleEventHandlers = new MtaBleEventHandlers();
  /** P2P 凭据直连模块 */
  private p2p: MtaP2pConnector = new MtaP2pConnector();
  /** P2P 事件回调 */
  private p2pHandlers: MtaP2pEventHandlers = new MtaP2pEventHandlers();
  /** 传输客户端（WS + 下载解压） */
  private transfer: MtaTransferClient = new MtaTransferClient();
  /** 传输客户端事件回调 */
  private transferHandlers: MtaTransferEventHandlers = new MtaTransferEventHandlers();
  /** 当前广播设备名（自动恢复时复用；取自设备昵称） */
  private deviceName: string = '';
  /** 是否有会话正在处理（防止重复触发直连） */
  private sessionActive: boolean = false;
  /** 是否正在启动（并发闸门：避免同一异步窗口内重复触发启动） */
  private startingUp: boolean = false;
  /** 接收文件落盘目录（Download/<bundleName>/） */
  private downloadDir: string = '';

  // ── 生命周期与订阅 ──

  /** 注入事件回调 */
  setEventHandlers(handlers: MtaReceiveEventHandlers): void {
    this.handlers = handlers;
  }

  /** 注入应用上下文（启动服务前调用） */
  init(context: common.Context): void {
    this.context = context;
    this.downloadDir = this.resolveDownloadDir(context);
    this.transfer.setCacheDir(context.cacheDir);
    this.bindBleHandlers();
    this.bindP2pHandlers();
    this.bindTransferHandlers();
    this.ble.registerEvents(this.bleHandlers);
    this.p2p.registerEvents(this.p2pHandlers);
    this.appendLog('服务', `MTA 接收页就绪，保存目录=${this.downloadDir}`, '信息');
  }

  /**
   * 解析接收文件落盘目录：DOWNLOAD 模式 Download/<bundleName>/。
   * 通过 DOWNLOAD 模式 URI 取沙箱路径，失败时回退应用 filesDir。
   */
  private resolveDownloadDir(context: common.Context): string {
    try {
      let bundleFlags = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
      let info = bundleManager.getBundleInfoForSelfSync(bundleFlags);
      let uri = `file://docs/storage/Users/currentUser/Download/${info.name}`;
      return new fileUri.FileUri(uri).path;
    } catch (e) {
      logger.warn('解析 DOWNLOAD 目录失败，回退应用目录: ' + String(e));
      return `${context.filesDir}/mta_received`;
    }
  }

  /** 当前状态快照 */
  getState(): ReceiverState {
    return this.state.snapshot();
  }

  /** 本机接收广播的发送者 ID 十六进制（供扫描侧过滤本机自身广播） */
  getLocalSenderIdHex(): string {
    return this.ble.getSenderIdHex();
  }

  /**
   * 以新昵称重广播并重建 GATT（供重启流程调用，使昵称变更经重启生效）。
   * 仅在接收服务运行中且无进行中会话时执行；否则保守跳过，待下次前台或重启再生效。
   */
  async refreshIdentity(deviceName: string): Promise<void> {
    if (!this.state.serviceRunning) {
      this.appendLog('服务', '接收服务未运行，跳过对外身份刷新', '信息');
      return;
    }
    if (this.sessionActive || this.startingUp) {
      this.appendLog('服务', '存在进行中会话或正在启动，跳过对外身份刷新', '信息');
      return;
    }
    if (this.deviceName === deviceName) {
      return;
    }
    this.deviceName = deviceName;
    this.appendLog('服务', `对外身份刷新为 ${deviceName}，重新广播并重建 GATT`, '信息');
    await this.restartBleService();
  }

  /** 清空日志流 */
  clearLogs(): void {
    this.logs = [];
  }

  // ── 状态与日志辅助 ──

  /** 切换阶段并推送状态快照 */
  private setStage(stage: ReceiverStage): void {
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

  /** 追加一条带时间戳的日志，超限丢弃最旧，同时输出 hilog */
  private appendLog(source: string, content: string, level: string): void {
    let entry = new ReceiverLogEntry();
    entry.timeText = formatTimeText(new Date());
    entry.source = source;
    entry.level = level;
    entry.content = content;
    this.logs.push(entry);
    if (this.logs.length > MtaConstants.MAX_LOG_ENTRIES) {
      this.logs.shift();
    }
    if (this.handlers !== null) {
      this.handlers.onLog(entry);
    }
    if (level === '错误') {
      logger.error(`${source}: ${content}`);
    } else {
      logger.info(`${source}: ${content}`);
    }
  }

  /** 清空本次会话的传输相关状态（保留服务运行与已保存文件） */
  private resetSessionState(): void {
    this.sessionActive = false;
    this.state.credentials = undefined;
    this.state.goIpAddress = '';
    this.state.transferPort = 0;
    this.state.receiveRequest = undefined;
    this.state.progress = new DownloadProgress();
    this.state.lastError = '';
    this.notifyState();
  }

  // ── BLE 事件绑定 ──

  /** 绑定 BLE 事件回调：全部转日志并同步广播/GATT/连接子状态 */
  private bindBleHandlers(): void {
    this.bleHandlers.onBluetoothStateChange = (stateText: string): void => {
      this.appendLog('蓝牙', `开关状态变化: ${stateText}`, '信息');
    };
    this.bleHandlers.onAdvertiseStateChange = (running: boolean, detail: string): void => {
      this.state.advertisingRunning = running;
      this.notifyState();
      this.appendLog('广播', detail, '信息');
    };
    this.bleHandlers.onGattConnectionChange = (deviceId: string, stateText: string): void => {
      this.state.connectedPeerId = this.ble.getConnectedClientId();
      this.notifyState();
      this.appendLog('GATT', `客户端 ${deviceId} ${stateText}`, '信息');
    };
    this.bleHandlers.onGattReadRequest = (deviceId: string, offset: number): void => {
      this.appendLog('GATT', `读请求来自 ${deviceId} offset=${offset}`, '信息');
    };
    this.bleHandlers.onGattWriteProgress =
      (deviceId: string, offset: number, totalLength: number, isPrepared: boolean): void => {
        this.appendLog('GATT', `写入分片 offset=${offset} len=${totalLength} prepared=${isPrepared}`, '信息');
      };
    this.bleHandlers.onP2pInfoReceived = (deviceId: string, payloadText: string): void => {
      this.handleP2pInfoReceived(deviceId, payloadText);
    };
    this.bleHandlers.onError = (source: string, message: string): void => {
      this.appendLog(source, message, '错误');
    };
  }

  /** 绑定 P2P 事件回调 */
  private bindP2pHandlers(): void {
    this.p2pHandlers.onP2pConnectionChange = (summary: string): void => {
      this.appendLog('P2P', summary, '信息');
    };
    this.p2pHandlers.onGoIp = (goIp: string): void => {
      this.state.goIpAddress = goIp;
      this.notifyState();
    };
    this.p2pHandlers.onError = (source: string, message: string): void => {
      this.appendLog(source, message, '错误');
    };
  }

  /** 绑定传输客户端事件回调 */
  private bindTransferHandlers(): void {
    this.transfer.setEventHandlers(this.transferHandlers);
    this.transferHandlers.onWsOpen = (): void => {
      this.appendLog('WS', '连接已建立，等待版本协商', '信息');
    };
    this.transferHandlers.onVersionNegotiated = (version: number): void => {
      this.setStage(ReceiverStage.NEGOTIATED);
      this.appendLog('WS', `版本协商完成 version=${version} threadLimit=${MtaConstants.THREAD_LIMIT}`, '信息');
    };
    this.transferHandlers.onReceiveRequest = (request: ReceiveRequest): void => {
      this.state.receiveRequest = request;
      this.setStage(ReceiverStage.REQUEST_RECEIVED);
      this.notifyState();
      this.appendLog('WS', `收到接收请求：发送方=${request.senderName} 文件=${request.fileName} ` +
        `数量=${request.fileCount} 大小=${request.totalSize} 任务=${request.taskId}`, '信息');
    };
    this.transferHandlers.onWsClosed = (reason: string): void => {
      this.appendLog('WS', `连接关闭: ${reason}`, '信息');
      this.handleWsClosed();
    };
    this.transferHandlers.onProgress = (progress: DownloadProgress): void => {
      this.state.progress = progress;
      this.notifyState();
    };
    this.transferHandlers.onError = (source: string, message: string): void => {
      this.appendLog(source, message, '错误');
    };
  }

  /** WS 非预期关闭时复位（下载中由下载流程自行处理） */
  private handleWsClosed(): void {
    if (!this.sessionActive) {
      return;
    }
    let stage = this.state.stage;
    if (stage === ReceiverStage.WS_CONNECTING || stage === ReceiverStage.NEGOTIATED ||
      stage === ReceiverStage.REQUEST_RECEIVED) {
      this.setError('WS 连接被对方关闭');
      this.failAndReset('WS 连接被对方关闭');
    }
  }

  /**
   * 建立 WS 连接并等待版本协商。
   * P2P 网络在链路建立后还需数秒才能路由，故先等待再重试，避免过早连接失败。
   */
  private async connectWs(): Promise<void> {
    let goIp = this.state.goIpAddress;
    let port = this.state.transferPort;
    if (goIp.length === 0 || port <= 0) {
      this.setError('GO IP 或端口缺失，无法建立 WS');
      this.failAndReset('GO IP 或端口缺失');
      return;
    }
    let url = `wss://${goIp}:${port}${MtaConstants.WS_PATH}`;
    this.setStage(ReceiverStage.WS_CONNECTING);
    let bindResult = await this.p2p.bindP2pNetwork(goIp);
    this.appendLog('WS', `网络绑定: ${bindResult}`, '信息');
    this.appendLog('WS', `等待网络就绪 ${MtaConstants.WS_SETTLE_DELAY_MS}ms`, '信息');
    await this.sleep(MtaConstants.WS_SETTLE_DELAY_MS);
    for (let attempt = 1; attempt <= MtaConstants.WS_CONNECT_MAX_ATTEMPTS; attempt++) {
      this.appendLog('WS', `连接 ${url}（第 ${attempt} 次）网络状态: ${this.p2p.getNetworkInfoText()}`, '信息');
      try {
        await this.transfer.connect(url);
        return;
      } catch (e) {
        this.appendLog('WS', `连接失败: ${String(e)}`, '错误');
        try {
          await this.transfer.close();
        } catch (e2) {
          this.appendLog('WS', '复位 WS 失败: ' + String(e2), '错误');
        }
        if (attempt < MtaConstants.WS_CONNECT_MAX_ATTEMPTS) {
          await this.sleep(MtaConstants.WS_RETRY_DELAY_MS);
        }
      }
    }
    this.setError('WS 连接失败');
    this.failAndReset('WS 连接失败');
  }

  /** 延时辅助 */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 收到完整 P2pInfo：解析 → 解密凭据 → 凭据直连 → 取得 GO IP */
  private handleP2pInfoReceived(deviceId: string, payloadText: string): void {
    this.appendLog('GATT', `完整接收 P2pInfo 来自 ${deviceId}: ${payloadText}`, '信息');
    if (this.sessionActive) {
      this.appendLog('GATT', '已有会话在处理，忽略重复 P2pInfo', '错误');
      return;
    }
    let info = parseP2pInfo(payloadText);
    if (info === undefined) {
      this.appendLog('GATT', 'P2pInfo JSON 解析失败', '错误');
      this.setError('P2pInfo 解析失败');
      return;
    }
    this.sessionActive = true;
    this.state.transferPort = info.port > 0 ? info.port : MtaConstants.DEFAULT_TRANSFER_PORT;
    this.setStage(ReceiverStage.P2P_INFO_RECEIVED);
    this.decryptAndConnect(info).catch((e: Object): void => {
      this.appendLog('服务', '解密/直连编排异常: ' + String(e), '错误');
      this.failAndReset('解密/直连编排异常');
    });
  }

  /** 解密凭据并凭据直连，成功后建立 WS 并完成版本协商 */
  private async decryptAndConnect(info: P2pInfoJson): Promise<void> {
    // 1) 解密凭据（key 存在走 ECDH+AES-CTR，缺失按明文）
    let credentials: DecryptedCredentials;
    if (info.key.length > 0) {
      this.appendLog('P2P', `收到发送端公钥（${info.key.length} 字符），开始 ECDH 协商 + AES-CTR 解密`, '信息');
    } else {
      this.appendLog('P2P', 'P2pInfo 未携带 key，按明文处理凭据', '信息');
    }
    try {
      credentials = await this.crypto.decryptCredentials(info);
    } catch (e) {
      this.appendLog('P2P', '凭据解密失败: ' + String(e), '错误');
      this.setError('凭据解密失败: ' + String(e));
      this.failAndReset('凭据解密失败');
      return;
    }
    this.state.credentials = credentials;
    this.notifyState();
    this.appendLog('P2P', `凭据解密成功 ssid=${credentials.ssid} psk=${credentials.psk} mac=${credentials.mac}`, '信息');

    // 2) 凭据直连发送方 WiFi Direct 组
    this.setStage(ReceiverStage.P2P_CONNECTING);
    let result: P2pConnectResult = await this.connectP2p(credentials);
    this.state.goIpAddress = result.goIp;
    this.notifyState();
    if (!result.connected) {
      this.setError(result.detail);
      this.failAndReset(result.detail);
      return;
    }
    this.setStage(ReceiverStage.P2P_CONNECTED);
    this.appendLog('P2P', `连接完成，GO IP=${result.goIp} 端口=${this.state.transferPort}`, '信息');

    // 3) 建立 WS 并完成版本协商
    await this.connectWs();
  }

  /**
   * 连接发送方 WiFi Direct 组：统一走凭据直连（把组当普通 WPA2 热点接入）。
   * 注：p2pConnect 在本平台无法为应用提供可用网络（P2P 接口无 IP/路由），故不使用。
   */
  private async connectP2p(credentials: DecryptedCredentials): Promise<P2pConnectResult> {
    this.appendLog('P2P', `开始凭据直连 ssid=${credentials.ssid}`, '信息');
    let result: P2pConnectResult =
      await this.p2p.connectAndWait(credentials.ssid, credentials.psk, MtaConstants.P2P_CONNECT_TIMEOUT_MS);
    this.appendLog('P2P', result.detail, result.connected ? '信息' : '错误');
    return result;
  }

  /** 本次会话失败：记录阶段并复位到等待状态 */
  private failAndReset(reason: string): void {
    this.setStage(ReceiverStage.FAILED);
    this.appendLog('服务', `本次接收失败：${reason}，正在复位到等待状态`, '错误');
    this.resetToWaiting().catch((e: Object): void => {
      this.appendLog('服务', '复位异常: ' + String(e), '错误');
    });
  }

  /** 复位到可再次接收的等待状态（关 WS、断开 P2P、确保 BLE 服务在运行） */
  private async resetToWaiting(): Promise<void> {
    this.sessionActive = false;
    try {
      await this.transfer.close();
    } catch (e) {
      this.appendLog('WS', '关闭 WS 失败: ' + String(e), '错误');
    }
    try {
      let detail = await this.p2p.disconnect();
      this.appendLog('P2P', detail, '信息');
    } catch (e) {
      this.appendLog('P2P', '断开 P2P 失败: ' + String(e), '错误');
    }
    this.resetSessionState();
    if (this.state.serviceRunning) {
      await this.ensureBleRunning();
      this.setStage(ReceiverStage.SERVICE_RUNNING);
      this.appendLog('服务', '已回到等待连接状态', '信息');
    } else {
      this.setStage(ReceiverStage.IDLE);
    }
  }

  /** 一次接收完成后清理会话资源并重启广播，支持连续接收 */
  private async completeAndRestart(): Promise<void> {
    this.sessionActive = false;
    try {
      await this.transfer.close();
    } catch (e) {
      this.appendLog('WS', '关闭 WS 失败: ' + String(e), '错误');
    }
    try {
      let detail = await this.p2p.disconnect();
      this.appendLog('P2P', detail, '信息');
    } catch (e) {
      this.appendLog('P2P', '断开 P2P 失败: ' + String(e), '错误');
    }
    this.resetSessionState();
    if (this.state.serviceRunning) {
      await this.restartBleService();
      this.setStage(ReceiverStage.SERVICE_RUNNING);
      this.appendLog('服务', '接收服务已自动恢复，可继续接收', '信息');
    } else {
      this.setStage(ReceiverStage.IDLE);
    }
  }

  /** 确保广播与 GATT Server 在运行（缺密钥时补生成，已运行则复用） */
  private async ensureBleRunning(): Promise<void> {
    try {
      if (!this.crypto.hasKeyPair()) {
        let publicKey = await this.crypto.generateKeyPair();
        this.state.ecdhPublicKey = publicKey;
      }
      let deviceInfoJson = this.buildDeviceInfoJson(this.crypto.getPublicKeyBase64());
      if (!this.ble.isAdvertising()) {
        await this.ble.startAdvertising(this.deviceName);
      }
      if (!this.ble.isGattRunning()) {
        await this.ble.startGattServer(deviceInfoJson);
      }
      this.state.advertisingRunning = this.ble.isAdvertising();
      this.state.gattRunning = this.ble.isGattRunning();
      this.notifyState();
    } catch (e) {
      this.appendLog('服务', '恢复 BLE 服务失败: ' + String(e), '错误');
      this.setError('恢复 BLE 服务失败: ' + String(e));
    }
  }

  /** 强制重启广播与 GATT Server（生成新的会话密钥对） */
  private async restartBleService(): Promise<void> {
    try {
      await this.ble.stopGattServer();
      await this.ble.stopAdvertising();
      let publicKey = await this.crypto.generateKeyPair();
      this.state.ecdhPublicKey = publicKey;
      await this.ble.startAdvertising(this.deviceName);
      await this.ble.startGattServer(this.buildDeviceInfoJson(publicKey));
      this.state.advertisingRunning = this.ble.isAdvertising();
      this.state.gattRunning = this.ble.isGattRunning();
      this.notifyState();
      this.appendLog('服务', '已重新启动广播与 GATT Server，可继续接收', '信息');
    } catch (e) {
      this.appendLog('服务', '自动恢复失败: ' + String(e), '错误');
      this.setError('自动恢复失败: ' + String(e));
    }
  }

  /** 构造本会话 DeviceInfo（CHAR_STATUS 读返回值） */
  private buildDeviceInfoJson(publicKey: string): string {
    let info = new DeviceInfoJson();
    info.state = MtaConstants.DEVICE_INFO_STATE;
    info.mac = MtaConstants.FALLBACK_MAC;
    info.key = publicKey;
    info.catShare = MtaConstants.CATSHARE_VERSION;
    return JSON.stringify(info);
  }

  // ── 服务启停 ──

  /** 启动接收服务：经「启动中」并发闸门后委派给实现体 */
  async startService(deviceName: string): Promise<void> {
    if (this.state.serviceRunning) {
      this.appendLog('服务', '接收服务已在运行', '信息');
      return;
    }
    if (this.startingUp) {
      this.appendLog('服务', '接收服务正在启动，忽略重复请求', '信息');
      return;
    }
    this.startingUp = true;
    try {
      await this.startServiceInternal(deviceName);
    } finally {
      this.startingUp = false;
    }
  }

  /** 启动接收服务实现体：权限/蓝牙检查 → 生成密钥对 → 广播 + GATT Server */
  private async startServiceInternal(deviceName: string): Promise<void> {
    this.deviceName = deviceName;
    this.appendLog('服务', `启动接收服务，设备名=${this.deviceName}`, '信息');

    // 1) 权限检查
    let context = this.context;
    if (context === undefined) {
      this.appendLog('权限', '缺少应用上下文，无法申请蓝牙权限', '错误');
      this.setError('缺少应用上下文');
      return;
    }
    let granted = false;
    try {
      granted = await this.ble.ensurePermission(context);
    } catch (e) {
      this.appendLog('权限', '申请 ACCESS_BLUETOOTH 失败: ' + String(e), '错误');
    }
    if (!granted) {
      this.appendLog('权限', 'ACCESS_BLUETOOTH 被拒绝，无法启动接收服务', '错误');
      this.setError('蓝牙权限被拒绝');
      return;
    }

    // 2) 蓝牙开关检查（未开启时请求系统开启并终止本次启动）
    if (!this.ble.isBluetoothOn()) {
      this.appendLog('蓝牙', `蓝牙未开启（当前 ${this.ble.getBluetoothStateText()}），请先开启后重试`, '错误');
      this.setError('蓝牙未开启');
      try {
        this.ble.enableBluetooth();
        this.appendLog('蓝牙', '已请求系统开启蓝牙', '信息');
      } catch (e) {
        this.appendLog('蓝牙', '请求开启蓝牙失败: ' + String(e), '错误');
      }
      return;
    }

    // 3) 生成密钥对并启动广播 + GATT Server
    try {
      let publicKey = await this.crypto.generateKeyPair();
      this.state.ecdhPublicKey = publicKey;
      let deviceInfoJson = this.buildDeviceInfoJson(publicKey);
      let preview = await this.ble.startAdvertising(this.deviceName);
      this.appendLog('广播', `广播已启动\n${preview}`, '信息');
      await this.ble.startGattServer(deviceInfoJson);
      this.appendLog('GATT', `GATT Server 已启动，DeviceInfo=${deviceInfoJson}`, '信息');
      this.state.serviceRunning = true;
      this.state.advertisingRunning = this.ble.isAdvertising();
      this.state.gattRunning = this.ble.isGattRunning();
      this.state.lastError = '';
      this.setStage(ReceiverStage.SERVICE_RUNNING);
      this.appendLog('服务', '接收服务已启动，等待 CatShare 连接', '信息');
    } catch (e) {
      this.appendLog('服务', '启动接收服务失败: ' + String(e), '错误');
      this.setError('启动失败: ' + String(e));
      await this.stopService();
    }
  }

  /** 停止接收服务并释放会话资源 */
  async stopService(): Promise<void> {
    this.appendLog('服务', '停止接收服务', '信息');
    this.sessionActive = false;
    try {
      await this.ble.stopAdvertising();
    } catch (e) {
      this.appendLog('广播', '停止广播失败: ' + String(e), '错误');
    }
    try {
      await this.ble.stopGattServer();
    } catch (e) {
      this.appendLog('GATT', '停止 GATT Server 失败: ' + String(e), '错误');
    }
    try {
      await this.transfer.close();
    } catch (e) {
      this.appendLog('WS', '关闭 WS 失败: ' + String(e), '错误');
    }
    try {
      let detail = await this.p2p.disconnect();
      this.appendLog('P2P', detail, '信息');
    } catch (e) {
      this.appendLog('P2P', '断开 P2P 失败: ' + String(e), '错误');
    }
    this.resetSessionState();
    this.state.serviceRunning = false;
    this.state.advertisingRunning = false;
    this.state.gattRunning = false;
    this.state.connectedPeerId = '';
    this.setStage(ReceiverStage.IDLE);
  }

  /** 用户接受接收请求：回 ack 并进入下载流程 */
  async acceptRequest(): Promise<void> {
    if (this.state.stage !== ReceiverStage.REQUEST_RECEIVED || this.state.receiveRequest === undefined) {
      this.appendLog('服务', '当前无待确认的接收请求', '错误');
      return;
    }
    let request = this.state.receiveRequest;
    this.appendLog('服务', `用户已接受接收请求，开始下载任务 ${request.taskId}`, '信息');
    await this.transfer.acceptRequest();
    this.downloadAndSave(request).catch((e: Object): void => {
      this.appendLog('下载', '下载编排异常: ' + String(e), '错误');
      this.failAndReset('下载编排异常');
    });
  }

  /** 下载 ZIP → 解压 → 落盘到 Download/<bundleName>/ */
  private async downloadAndSave(request: ReceiveRequest): Promise<void> {
    this.setStage(ReceiverStage.DOWNLOADING);
    let goIp = this.state.goIpAddress;
    let port = this.state.transferPort;
    try {
      let tempZip = await this.transfer.downloadZip(goIp, port, request.taskId, request.totalSize);
      this.appendLog('下载', 'ZIP 下载完成，开始解压保存', '信息');
      this.setStage(ReceiverStage.SAVING);
      let result = await this.transfer.extractAndSave(tempZip, request.taskId, this.downloadDir);
      this.state.savedFiles = result.savedFiles;
      // 透传逐文件展示元数据（文件名 + 大小），供页面完成后渲染文件列表
      this.state.receivedFiles = result.files;
      // 落盘完成后按设置写入接收历史（文本消息以单一 text/plain 条目记录）
      this.recordReceiveHistory(request, result);
      let done = new DownloadProgress();
      done.receivedBytes = result.totalBytes;
      done.totalBytes = result.totalBytes;
      done.percent = 100;
      this.state.progress = done;
      this.notifyState();
      this.appendLog('下载', `保存完成，共 ${result.entryCount} 个文件，合计 ${result.totalBytes} 字节`, '信息');
      this.setStage(ReceiverStage.COMPLETED);
      // 传输完成回执（发送方收到后延迟删组停服），等待写入完成
      await this.transfer.sendStatus(MtaConstants.STATUS_TYPE_OK, MtaConstants.STATUS_REASON_OK);
      this.appendLog('WS', '已回送成功状态，本次接收完成', '信息');
      // 等待发送方收到回执并完成收尾，避免过早断开导致发送方判定为中断
      await this.sleep(MtaConstants.STATUS_SETTLE_DELAY_MS);
      // 断开 P2P、关闭 WS 并自动重启广播，支持连续接收
      await this.completeAndRestart();
    } catch (e) {
      this.transfer.cleanupTemp(request.taskId);
      this.appendLog('下载', '下载/保存失败: ' + String(e), '错误');
      this.setError('下载/保存失败: ' + String(e));
      this.failAndReset('下载/保存失败');
    }
  }

  /** 落盘完成后按设置写入接收历史；文本消息以 isMessage 标记并记录文本内容 */
  private recordReceiveHistory(request: ReceiveRequest, result: DownloadResult): void {
    if (!isSaveToHistory()) {
      return;
    }
    let timestamp = Date.now();
    // 文本消息：单一 text/plain 条目（无对应磁盘文件路径）
    if (request.textContent.length > 0) {
      let textEntry: ReceiveHistoryEntry = {
        id: `${request.taskId}_0`,
        fileName: MTA_SHARED_TEXT_FILE_NAME,
        fileType: 'text/plain',
        path: '',
        savedToGallery: false,
        isMessage: true,
        fileSize: utf8ByteLength(request.textContent),
        senderAlias: request.senderName,
        timestamp: timestamp,
        textContent: request.textContent
      };
      addEntry(textEntry);
      return;
    }
    // 文件条目：每个落盘文件记录一条历史
    for (let i = 0; i < result.savedFiles.length; i++) {
      let savedPath = result.savedFiles[i];
      let entry: ReceiveHistoryEntry = {
        id: `${request.taskId}_${i}`,
        fileName: this.baseNameOf(savedPath),
        fileType: 'application/octet-stream',
        path: savedPath,
        savedToGallery: false,
        isMessage: false,
        fileSize: this.fileSizeOf(savedPath),
        senderAlias: request.senderName,
        timestamp: timestamp + i
      };
      addEntry(entry);
    }
  }

  /** 取路径末段文件名 */
  private baseNameOf(path: string): string {
    let index = path.lastIndexOf('/');
    return index >= 0 ? path.substring(index + 1) : path;
  }

  /** 读取文件大小（失败返回 0） */
  private fileSizeOf(path: string): number {
    try {
      return fs.statSync(path).size;
    } catch (e) {
      return 0;
    }
  }

  /** 用户拒绝接收请求：回送拒绝状态 → 有界收尾等待 → 复位 */
  async rejectRequest(): Promise<void> {
    if (this.state.stage !== ReceiverStage.REQUEST_RECEIVED) {
      this.appendLog('服务', '当前无待确认的接收请求', '错误');
      return;
    }
    this.appendLog('服务', '用户已拒绝接收请求，回送拒绝状态', '信息');
    try {
      await this.transfer.rejectRequest();
      // 回送后等待对端收尾，确保在途拒绝帧送达后再关闭连接（与成功路径一致）
      await this.sleep(MtaConstants.STATUS_SETTLE_DELAY_MS);
    } catch (e) {
      this.appendLog('WS', '回送拒绝状态异常: ' + String(e), '错误');
    }
    await this.resetToWaiting();
  }

  /** 取消当前下载 */
  cancelDownload(): void {
    if (this.state.stage !== ReceiverStage.DOWNLOADING && this.state.stage !== ReceiverStage.SAVING) {
      this.appendLog('下载', '当前无进行中的下载', '信息');
      return;
    }
    this.appendLog('下载', '用户取消下载', '信息');
    this.transfer.cancelDownload();
  }

  /** 一键清理：停止服务并释放全部资源 */
  async cleanupAll(): Promise<void> {
    await this.stopService();
    this.ble.destroy();
    this.p2p.destroy();
    this.transfer.close().catch((): void => {
    });
    this.crypto.reset();
    this.appendLog('服务', '已清理全部 MTA 接收资源', '信息');
  }

  /** 页面退出时释放资源 */
  destroy(): void {
    this.stopService().catch((): void => {
    });
    this.ble.destroy();
    this.p2p.destroy();
    this.transfer.close().catch((): void => {
    });
    this.crypto.reset();
  }
}
