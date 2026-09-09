/**
 * MtaBleVerifyViewModel.ets — MTA BLE 验证页视图模型
 *
 * 持有验证页面全部状态（蓝牙开关/权限/广播/GATT Server/扫描/GATT Client/日志流）
 * 与命令方法，负责调用 BleVerifyService 并将每步操作与事件写入带时间戳的日志流
 * （上限 1000 条）。
 */

import { common } from '@kit.AbilityKit';
import { BleVerifyService } from '../service/mta/BleVerifyService';
import {
  BleEventHandlers,
  ScannedMtaDeviceView,
  GattClientStateView,
  VerifyLogEntry,
  formatTimeText
} from '../model/mta/BleVerifyModels';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.NETWORK, 'HandySend:MtaBleVerifyVM');

/** 日志流上限，超出丢弃最旧 */
const MAX_LOG_ENTRIES = 1000;

@ObservedV2
export class MtaBleVerifyViewModel {
  // ── 蓝牙状态与权限 ──
  @Trace public bluetoothStateText: string = '未知'
  @Trace public permissionGranted: boolean = false
  @Trace public permissionChecked: boolean = false

  // ── 广播（US1） ──
  @Trace public advertising: boolean = false
  @Trace public deviceNameInput: string = 'HandySend'
  @Trace public senderIdHex: string = ''
  @Trace public advPreview: string = ''
  @Trace public isAdvertiseBusy: boolean = false

  // ── GATT Server（US2） ──
  @Trace public gattRunning: boolean = false
  @Trace public gattPublicKey: string = ''
  @Trace public gattClientId: string = ''
  @Trace public gattReadCount: number = 0
  @Trace public gattWriteBufferLength: number = 0
  @Trace public lastPayloadText: string = ''
  @Trace public isGattBusy: boolean = false

  // ── 扫描（US3） ──
  @Trace public scanning: boolean = false
  @Trace public scannedDevices: Array<ScannedMtaDeviceView> = []

  // ── GATT Client（US4） ──
  @Trace public gattClientState: GattClientStateView = new GattClientStateView()
  @Trace public gattClientTargetInput: string = ''
  @Trace public isGattClientBusy: boolean = false

  // ── 日志流 ──
  @Trace public logs: Array<VerifyLogEntry> = []

  private service: BleVerifyService = new BleVerifyService();
  private handlers: BleEventHandlers = new BleEventHandlers();

  // ── 生命周期 ──

  /** 页面 aboutToAppear：注册事件、刷新蓝牙状态，并在可用时申请权限 */
  loadInitial(context: common.Context | undefined): void {
    this.bindHandlers();
    this.service.registerEvents(this.handlers);
    this.refreshBluetoothState();
    this.appendLog('初始化', 'BLE 验证页面就绪，事件已注册', 'info');
    if (context !== undefined) {
      this.onRequestPermission(context);
    }
  }

  /** 页面 aboutToDisappear：释放全部 BLE 资源并反注册事件 */
  destroy(): void {
    this.service.destroy();
  }

  // ── 事件绑定 ──

  private bindHandlers(): void {
    this.handlers.onBluetoothStateChange = (stateText: string): void => {
      this.bluetoothStateText = stateText;
      this.appendLog('蓝牙', `开关状态变化: ${stateText}`, 'info');
    };
    this.handlers.onAdvertiseStateChange = (running: boolean, detail: string): void => {
      this.advertising = running;
      this.appendLog('广播', detail, 'info');
    };
    this.handlers.onGattConnectionChange = (clientDeviceId: string, stateText: string): void => {
      this.gattClientId = this.service.getConnectedClientId();
      this.appendLog('GATT Server', `客户端 ${clientDeviceId} ${stateText}`, 'info');
    };
    this.handlers.onGattReadRequest = (clientDeviceId: string, offset: number): void => {
      this.gattReadCount = this.gattReadCount + 1;
      this.appendLog('GATT Server', `读请求来自 ${clientDeviceId} offset=${offset}`, 'info');
    };
    this.handlers.onGattWriteProgress =
      (deviceId: string, offset: number, totalLength: number, isPrepared: boolean): void => {
        this.gattWriteBufferLength = totalLength;
        this.appendLog('GATT Server',
          `写入分片 ${deviceId} offset=${offset} total=${totalLength} prepared=${isPrepared}`, 'info');
      };
    this.handlers.onGattWriteComplete = (deviceId: string, payloadText: string): void => {
      this.lastPayloadText = payloadText;
      this.gattWriteBufferLength = 0;
      this.appendLog('GATT Server', `完整接收来自 ${deviceId} (${payloadText.length} 字符): ${payloadText}`, 'info');
    };
    this.handlers.onDeviceFound = (device: ScannedMtaDeviceView): void => {
      let next = this.scannedDevices.slice();
      let idx = -1;
      for (let i = 0; i < next.length; i++) {
        if (next[i].deviceId === device.deviceId) {
          idx = i;
          break;
        }
      }
      if (idx >= 0) {
        next[idx] = device;
      } else {
        next.push(device);
      }
      this.scannedDevices = next;
      this.appendLog('扫描', `发现 ${device.deviceName} id=${device.deviceId} rssi=${device.rssi} ` +
        `senderId=${device.senderIdHex} brand=${device.brandName} 5GHz=${device.is5Ghz}`, 'info');
    };
    this.handlers.onGattClientConnectionChange = (stateText: string): void => {
      this.updateGattClientState(this.gattClientState.targetDeviceId, stateText,
        this.gattClientState.deviceInfoText);
      this.appendLog('GATT Client', `连接状态: ${stateText}`, 'info');
    };
    this.handlers.onGattClientDeviceInfo = (deviceInfoText: string): void => {
      this.updateGattClientState(this.gattClientState.targetDeviceId, this.gattClientState.connectionStateText,
        deviceInfoText);
      this.appendLog('GATT Client', `读取到 DeviceInfo: ${deviceInfoText}`, 'info');
    };
    this.handlers.onError = (source: string, message: string): void => {
      this.appendLog(source, message, 'error');
    };
  }

  // ── 日志 ──

  /** 追加一条带时间戳的日志，超限丢弃最旧，同时输出 hilog */
  appendLog(source: string, content: string, level: string): void {
    let entry = new VerifyLogEntry();
    entry.timeText = formatTimeText(new Date());
    entry.source = source;
    entry.content = content;
    entry.level = level;
    this.logs.push(entry);
    if (this.logs.length > MAX_LOG_ENTRIES) {
      this.logs.shift();
    }
    if (level === 'error') {
      logger.error(`${source}: ${content}`);
    } else {
      logger.info(`${source}: ${content}`);
    }
  }

  /** 清空日志流 */
  clearLogs(): void {
    this.logs = [];
  }

  /** 拼接全部日志文本（时间/来源/级别/内容），供剪贴板复制 */
  buildLogText(): string {
    let lines: Array<string> = [];
    for (let i = 0; i < this.logs.length; i++) {
      let e = this.logs[i];
      lines.push(`${e.timeText} [${e.level}] ${e.source}: ${e.content}`);
    }
    return lines.join('\n');
  }

  // ── 蓝牙状态与权限 ──

  /** 刷新蓝牙开关状态 */
  refreshBluetoothState(): void {
    try {
      this.bluetoothStateText = this.service.getBluetoothStateText();
    } catch (e) {
      this.bluetoothStateText = '查询失败';
      this.appendLog('蓝牙', '查询开关状态失败: ' + String(e), 'error');
    }
  }

  /** 请求系统开启蓝牙 */
  onEnableBluetooth(): void {
    try {
      this.service.enableBluetooth();
      this.appendLog('蓝牙', '已请求开启蓝牙，请在系统对话框中确认', 'info');
    } catch (e) {
      this.appendLog('蓝牙', '开启蓝牙失败: ' + String(e), 'error');
    }
  }

  /** 运行时申请 ACCESS_BLUETOOTH 权限 */
  async onRequestPermission(context: common.Context): Promise<void> {
    this.appendLog('权限', '申请 ACCESS_BLUETOOTH...', 'info');
    try {
      let granted = await this.service.ensurePermission(context);
      this.permissionGranted = granted;
      this.permissionChecked = true;
      this.appendLog('权限', granted ? 'ACCESS_BLUETOOTH 已授予' : 'ACCESS_BLUETOOTH 被拒绝',
        granted ? 'info' : 'error');
    } catch (e) {
      this.permissionChecked = true;
      this.appendLog('权限', '申请失败: ' + String(e), 'error');
    }
  }

  // ── 广播（US1） ──

  /** 启动 MTA 格式广播 */
  async onStartAdvertise(): Promise<void> {
    if (this.deviceNameInput.length === 0) {
      this.appendLog('广播', '设备名不能为空', 'error');
      return;
    }
    this.isAdvertiseBusy = true;
    try {
      let preview = await this.service.startAdvertising(this.deviceNameInput);
      this.senderIdHex = this.service.getSenderIdHex();
      this.advPreview = preview;
      this.appendLog('广播', `启动成功 设备名=${this.deviceNameInput}\n${preview}`, 'info');
    } catch (e) {
      this.appendLog('广播', '启动失败: ' + String(e), 'error');
    } finally {
      this.isAdvertiseBusy = false;
    }
  }

  /** 停止广播 */
  async onStopAdvertise(): Promise<void> {
    try {
      await this.service.stopAdvertising();
    } catch (e) {
      this.appendLog('广播', '停止失败: ' + String(e), 'error');
    }
  }

  // ── GATT Server（US2） ──

  /** 启动 GATT Server（生成 ECDH 公钥并注册协议服务） */
  async onStartGatt(): Promise<void> {
    this.isGattBusy = true;
    try {
      let deviceInfo = await this.service.startGattServer();
      this.gattRunning = true;
      this.gattPublicKey = this.service.getEcdhPublicKey();
      this.gattReadCount = 0;
      this.gattWriteBufferLength = 0;
      this.lastPayloadText = '';
      this.appendLog('GATT Server', `启动成功，DeviceInfo=${deviceInfo}`, 'info');
    } catch (e) {
      this.appendLog('GATT Server', '启动失败: ' + String(e), 'error');
    } finally {
      this.isGattBusy = false;
    }
  }

  /** 停止 GATT Server */
  async onStopGatt(): Promise<void> {
    try {
      await this.service.stopGattServer();
      this.gattRunning = false;
      this.gattClientId = '';
      this.gattWriteBufferLength = 0;
      this.appendLog('GATT Server', '已停止', 'info');
    } catch (e) {
      this.appendLog('GATT Server', '停止失败: ' + String(e), 'error');
    }
  }

  // ── 扫描（US3） ──

  /** 启动 BLE 扫描 */
  async onStartScan(): Promise<void> {
    try {
      await this.service.startScan();
      this.scanning = true;
      this.scannedDevices = [];
      this.appendLog('扫描', '已启动扫描', 'info');
    } catch (e) {
      this.appendLog('扫描', '启动失败: ' + String(e), 'error');
    }
  }

  /** 停止 BLE 扫描 */
  async onStopScan(): Promise<void> {
    try {
      await this.service.stopScan();
      this.scanning = false;
      this.appendLog('扫描', '已停止扫描', 'info');
    } catch (e) {
      this.appendLog('扫描', '停止失败: ' + String(e), 'error');
    }
  }

  // ── GATT Client（US4） ──

  /** 更新 GATT Client 状态视图（整体替换以触发 V2 刷新） */
  private updateGattClientState(target: string, stateText: string, infoText: string): void {
    let next = new GattClientStateView();
    next.targetDeviceId = target;
    next.connectionStateText = stateText;
    next.deviceInfoText = infoText;
    this.gattClientState = next;
  }

  /** 扫描列表点击：填入 GATT Client 目标设备 */
  onSelectTargetDevice(deviceId: string): void {
    this.gattClientTargetInput = deviceId;
    this.updateGattClientState(deviceId, this.gattClientState.connectionStateText, this.gattClientState.deviceInfoText);
    this.appendLog('GATT Client', `目标设备已设为 ${deviceId}`, 'info');
  }

  /** 连接目标设备 */
  async onConnectGattClient(): Promise<void> {
    let target = this.gattClientTargetInput.length > 0 ? this.gattClientTargetInput : this.gattClientState.targetDeviceId;
    if (target.length === 0) {
      this.appendLog('GATT Client', '目标设备不能为空', 'error');
      return;
    }
    this.isGattClientBusy = true;
    try {
      await this.service.connectGattClient(target);
      this.updateGattClientState(target, '连接中', this.gattClientState.deviceInfoText);
      this.appendLog('GATT Client', `已发起连接 ${target}`, 'info');
    } catch (e) {
      this.appendLog('GATT Client', '连接失败: ' + String(e), 'error');
    } finally {
      this.isGattClientBusy = false;
    }
  }

  /** 读取对端 CHAR_STATUS 返回的 DeviceInfo */
  async onReadRemoteDeviceInfo(): Promise<void> {
    try {
      let text = await this.service.readRemoteDeviceInfo();
      this.updateGattClientState(this.gattClientState.targetDeviceId, this.gattClientState.connectionStateText, text);
      this.appendLog('GATT Client', `读取成功: ${text}`, 'info');
    } catch (e) {
      this.appendLog('GATT Client', '读取失败: ' + String(e), 'error');
    }
  }

  /** 断开 GATT Client */
  async onDisconnectGattClient(): Promise<void> {
    try {
      await this.service.disconnectGattClient();
      this.updateGattClientState(this.gattClientState.targetDeviceId, '未连接', this.gattClientState.deviceInfoText);
      this.appendLog('GATT Client', '已断开', 'info');
    } catch (e) {
      this.appendLog('GATT Client', '断开失败: ' + String(e), 'error');
    }
  }

  // ── 清理 ──

  /** 一键清理：停止广播/扫描、关闭 GATT Server、断开 GATT Client */
  async cleanupAll(): Promise<void> {
    await this.onStopAdvertise();
    await this.onStopScan();
    await this.onStopGatt();
    await this.onDisconnectGattClient();
    this.appendLog('清理', '已释放全部 BLE 资源', 'info');
  }
}
