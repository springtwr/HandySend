/**
 * MtaBleClient.ets — MTA 发送端 BLE 客户端
 *
 * 发送端在 MTA 协议中承担 BLE 扫描 + GATT Client 角色：
 * - 按 MTA 主广播 serviceUuid 过滤扫描接收端广播，解析扫描响应中的发送者 ID / 设备名
 *   与品牌 UUID 中的 5GHz 标识 / 品牌 ID，按 deviceId 去重并按 RSSI 变化限流上报；
 * - 作为 GATT Client 连接对端 GATT Server，读 CHAR_STATUS 取 DeviceInfo，写 CHAR_P2P 回 P2pInfo。
 * 本服务只采集/转发数据，不持有页面状态；错误统一文本化上抛。
 */

import { ble, access, constant } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { DeviceInfoJson, formatTimeText, parseDeviceInfo } from '../../model/mta/MtaReceiveModels';
import { MtaBleClientEventHandlers, MtaDiscoveredDevice } from '../../model/mta/MtaSendModels';
import { MtaConstants } from './MtaConstants';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaBleClient');

/** 将系统同步调用异常转换为可读文本 */
function errorText(e: Object): string {
  let obj = e as Record<string, Object>;
  let codeVal = obj['code'];
  let msgVal = obj['message'];
  if (codeVal !== undefined && msgVal !== undefined) {
    return `[${codeVal}] ${msgVal}`;
  }
  if (e instanceof Error) {
    let err = e as Error;
    return err.message.length > 0 ? err.message : '未知错误';
  }
  return '未知错误';
}

/** 复制 Uint8Array 到独立 ArrayBuffer（BLE API 要求 ArrayBuffer 入参） */
function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  let buffer = new ArrayBuffer(bytes.length);
  let view = new Uint8Array(buffer);
  view.set(bytes, 0);
  return buffer;
}

/** 字节数组转十六进制字符串 */
function bytesToHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    let h = bytes[i].toString(16);
    out += h.length === 1 ? '0' + h : h;
  }
  return out;
}

/** 蓝牙开关状态枚举 → 文本 */
function bluetoothStateText(state: access.BluetoothState): string {
  switch (state) {
    case access.BluetoothState.STATE_OFF:
      return '关闭';
    case access.BluetoothState.STATE_TURNING_ON:
      return '正在开启';
    case access.BluetoothState.STATE_ON:
      return '开启';
    case access.BluetoothState.STATE_TURNING_OFF:
      return '正在关闭';
    case access.BluetoothState.STATE_BLE_TURNING_ON:
      return 'BLE 正在开启';
    case access.BluetoothState.STATE_BLE_ON:
      return 'BLE 模式';
    case access.BluetoothState.STATE_BLE_TURNING_OFF:
      return 'BLE 正在关闭';
    default:
      return '未知';
  }
}

/** GATT 连接状态枚举 → 文本 */
function profileStateText(state: constant.ProfileConnectionState): string {
  switch (state) {
    case constant.ProfileConnectionState.STATE_DISCONNECTED:
      return '已断开';
    case constant.ProfileConnectionState.STATE_CONNECTING:
      return '连接中';
    case constant.ProfileConnectionState.STATE_CONNECTED:
      return '已连接';
    case constant.ProfileConnectionState.STATE_DISCONNECTING:
      return '断开中';
    default:
      return '未知';
  }
}

/** 品牌 ID → 品牌名（映射表见 MTA 研究报告 §3.3） */
function brandNameOf(brandId: number): string {
  if (brandId >= 10 && brandId <= 19) {
    return brandId === 11 ? 'Realme' : 'OPPO';
  }
  if (brandId >= 20 && brandId <= 29) {
    return 'vivo';
  }
  if (brandId >= 30 && brandId <= 39) {
    return 'Xiaomi';
  }
  if (brandId >= 41 && brandId <= 45) {
    return 'OnePlus';
  }
  if (brandId >= 50 && brandId <= 59) {
    return 'Meizu';
  }
  if (brandId >= 70 && brandId <= 75) {
    return 'Samsung';
  }
  if (brandId >= 100 && brandId <= 109) {
    return 'Lenovo';
  }
  if (brandId === MtaConstants.BRAND_ID_THIRD_PARTY) {
    return '第三方';
  }
  return `未知(${brandId})`;
}

/** UTF-8 字节数组解码为文本（容错非法序列） */
function decodeUtf8(bytes: Uint8Array): string {
  try {
    return new util.TextDecoder().decodeToString(bytes);
  } catch (e) {
    return '';
  }
}

/** 解码扫描响应中的设备名字段：去除尾部 \t 与 0x00 填充后按 UTF-8 解码 */
function decodeNameField(bytes: Uint8Array): string {
  let end = bytes.length;
  while (end > 0 && (bytes[end - 1] === MtaConstants.NAME_FIELD_PADDING || bytes[end - 1] === 0x00)) {
    end--;
  }
  return decodeUtf8(bytes.slice(0, end));
}

/** MTA 发送端 BLE 客户端 */
export class MtaBleClient {
  /** 事件回调集合（服务注入） */
  private handlers: MtaBleClientEventHandlers | null = null;
  /** 是否注册了蓝牙开关事件 */
  private eventsRegistered: boolean = false;

  // ── 扫描 ──
  /** 是否扫描中 */
  private scanning: boolean = false;
  /** 已发现设备按 deviceId 去重（值为最近一次 RSSI） */
  private scanDeviceRssi: Map<string, number> = new Map();

  // ── GATT Client ──
  /** GATT Client 实例 */
  private gattClient: ble.GattClientDevice | null = null;
  /** GATT Client 目标设备标识 */
  private gattClientTarget: string = '';
  /** GATT Client 是否已连接 */
  private gattClientConnected: boolean = false;
  /** 协商后的 MTU（0 表示尚未协商，未协商时为默认 23 字节） */
  private negotiatedMtu: number = 0;

  // ── 事件注册 / 反注册 ──

  /** 注册蓝牙开关事件；重复注册时先反注册旧回调 */
  registerEvents(handlers: MtaBleClientEventHandlers): void {
    if (this.eventsRegistered) {
      this.unregisterEvents();
    }
    this.handlers = handlers;
    try {
      access.on('stateChange', (state: access.BluetoothState) => {
        if (this.handlers !== null) {
          this.handlers.onBluetoothStateChange(bluetoothStateText(state));
        }
      });
      this.eventsRegistered = true;
    } catch (e) {
      logger.warn('蓝牙: stateChange 注册失败: ' + errorText(e));
    }
  }

  /** 反注册蓝牙开关事件 */
  unregisterEvents(): void {
    if (!this.eventsRegistered) {
      return;
    }
    try {
      access.off('stateChange');
    } catch (e) {
      logger.warn('蓝牙: stateChange 反注册失败: ' + errorText(e));
    }
    this.eventsRegistered = false;
    this.handlers = null;
  }

  // ── 权限与蓝牙开关 ──

  /** 运行时申请 ACCESS_BLUETOOTH 权限，返回是否授予 */
  ensurePermission(context: common.Context): Promise<boolean> {
    return new Promise<boolean>((resolve, reject) => {
      try {
        let atManager = abilityAccessCtrl.createAtManager();
        let permissions: Array<Permissions> = ['ohos.permission.ACCESS_BLUETOOTH'];
        atManager.requestPermissionsFromUser(context, permissions)
          .then((result: PermissionRequestResult) => {
            let granted = result.authResults.length > 0 && result.authResults[0] === 0;
            resolve(granted);
          })
          .catch((e: BusinessError) => {
            reject(errorText(e));
          });
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 查询蓝牙开关状态文本 */
  getBluetoothStateText(): string {
    try {
      return bluetoothStateText(access.getState());
    } catch (e) {
      return '查询失败';
    }
  }

  /** 蓝牙是否已开启 */
  isBluetoothOn(): boolean {
    try {
      let state = access.getState();
      return state === access.BluetoothState.STATE_ON || state === access.BluetoothState.STATE_BLE_ON;
    } catch (e) {
      return false;
    }
  }

  /** 弹系统对话框开启蓝牙 */
  enableBluetooth(): void {
    access.enableBluetooth();
  }

  // ── 扫描 ──

  /** 是否扫描中 */
  isScanning(): boolean {
    return this.scanning;
  }

  /** 已发现设备数（按 deviceId 去重） */
  getScannedDeviceCount(): number {
    return this.scanDeviceRssi.size;
  }

  /** 启动 BLE 扫描：按 MTA 主广播 serviceUuid 过滤，低延迟 + 激进匹配 */
  startScan(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.scanning) {
        resolve();
        return;
      }
      try {
        let filter: ble.ScanFilter = { serviceUuid: MtaConstants.ADV_SERVICE_UUID };
        let filters: Array<ble.ScanFilter> = [filter];
        let options: ble.ScanOptions = {
          dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
          matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
        };
        ble.on('BLEDeviceFind', (results: Array<ble.ScanResult>) => {
          this.handleScanResults(results);
        });
        ble.startBLEScan(filters, options);
        this.scanDeviceRssi = new Map();
        this.scanning = true;
        if (this.handlers !== null) {
          this.handlers.onScanStateChange(true, '扫描已启动');
        }
        resolve();
      } catch (e) {
        // 失败回滚：反注册可能已注册的 BLEDeviceFind 监听，避免失败重试累积监听器
        this.scanning = false;
        try {
          ble.off('BLEDeviceFind');
        } catch (_e) {
          // 忽略清理异常，不覆盖原始起扫错误
        }
        reject(errorText(e));
      }
    });
  }

  /** 停止 BLE 扫描并反注册回调 */
  stopScan(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (!this.scanning) {
        resolve();
        return;
      }
      try {
        ble.stopBLEScan();
        ble.off('BLEDeviceFind');
        this.scanning = false;
        if (this.handlers !== null) {
          this.handlers.onScanStateChange(false, '扫描已停止');
        }
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 批量处理扫描结果：按 deviceId 去重、保留最新 RSSI 后上报（信号抖动不刷屏） */
  private handleScanResults(results: Array<ble.ScanResult>): void {
    for (let i = 0; i < results.length; i++) {
      let device = this.parseScanResult(results[i]);
      let prevRssi = this.scanDeviceRssi.get(device.bleAddress);
      if (prevRssi === undefined || prevRssi !== device.rssi) {
        this.scanDeviceRssi.set(device.bleAddress, device.rssi);
        if (this.handlers !== null) {
          this.handlers.onDeviceFound(device);
        }
      }
    }
  }

  /** 解析单条扫描结果：扫描响应 serviceData 解析设备名/发送者 ID，品牌 UUID 字节解析 5GHz/品牌 */
  private parseScanResult(result: ble.ScanResult): MtaDiscoveredDevice {
    let device = new MtaDiscoveredDevice();
    device.bleAddress = result.deviceId;
    device.deviceName = result.deviceName;
    device.rssi = result.rssi;
    device.lastSeenText = formatTimeText(new Date());
    device.senderIdHex = '';
    device.brandName = '未知';
    device.brandId = -1;
    device.is5Ghz = false;

    let map = result.serviceDataMap;
    if (map === undefined) {
      return device;
    }
    map.forEach((value: Uint8Array, key: string): void => {
      let compact = key.split('-').join('').toLowerCase();
      if (compact.startsWith('0000ffff')) {
        if (value.length >= MtaConstants.SCAN_RSP_LENGTH) {
          device.senderIdHex = bytesToHex(value.slice(8, 10));
          let nameField = value.slice(MtaConstants.SCAN_RSP_NAME_OFFSET,
            MtaConstants.SCAN_RSP_NAME_OFFSET + MtaConstants.SCAN_RSP_NAME_LENGTH);
          let parsedName = decodeNameField(nameField);
          if (parsedName.length > 0) {
            device.deviceName = parsedName;
          }
        }
      } else if (compact.length >= 8) {
        let flag = parseInt(compact.substring(4, 6), 16);
        let brandId = parseInt(compact.substring(6, 8), 16);
        if (!isNaN(flag)) {
          device.is5Ghz = flag === 0x01;
        }
        if (!isNaN(brandId)) {
          device.brandId = brandId;
          device.brandName = brandNameOf(brandId);
        }
      }
    });
    return device;
  }

  // ── GATT Client ──

  /** 是否已建立 GATT Client 连接 */
  isGattClientConnected(): boolean {
    return this.gattClientConnected;
  }

  /** 当前 GATT Client 目标设备标识 */
  getGattClientTarget(): string {
    return this.gattClientTarget;
  }

  /** 连接对端 GATT Server：创建 Client → 订阅连接状态事件 → connect */
  connectGattClient(deviceId: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.gattClient !== null) {
        reject('已存在 GATT Client 连接，请先断开');
        return;
      }
      try {
        let client = ble.createGattClientDevice(deviceId);
        this.gattClient = client;
        this.gattClientTarget = deviceId;
        this.gattClientConnected = false;
        this.negotiatedMtu = 0;
        client.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
          if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
            this.gattClientConnected = true;
          } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
            this.gattClientConnected = false;
          }
          if (this.handlers !== null) {
            this.handlers.onGattConnectionChange(profileStateText(state.state));
          }
        });
        client.on('BLEMtuChange', (mtu: number) => {
          this.negotiatedMtu = mtu;
          if (this.handlers !== null) {
            this.handlers.onGattConnectionChange(`MTU=${mtu}`);
          }
        });
        client.connect();
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 等待 GATT 连接就绪：先立即检查，随后轮询兜底，超时返回 false */
  async waitGattConnected(timeoutMs: number): Promise<boolean> {
    if (this.gattClientConnected) {
      return true;
    }
    let waited = 0;
    while (waited < timeoutMs) {
      await this.sleepMs(MtaConstants.GATT_CONNECT_POLL_MS);
      waited += MtaConstants.GATT_CONNECT_POLL_MS;
      if (this.gattClientConnected) {
        return true;
      }
    }
    return this.gattClientConnected;
  }

  /** 请求协商 MTU（需已连接）；协商结果经 BLEMtuChange 事件回填 */
  private requestMtu(client: ble.GattClientDevice): void {
    try {
      client.setBLEMtuSize(MtaConstants.GATT_MTU_SIZE);
    } catch (e) {
      logger.warn('GATT: setBLEMtuSize 失败: ' + errorText(e));
    }
  }

  /** 等待 MTU 协商完成，超时则返回当前值（未协商时为默认 23） */
  async waitMtuNegotiated(timeoutMs: number): Promise<number> {
    let waited = 0;
    while (waited < timeoutMs) {
      if (this.negotiatedMtu > 0) {
        return this.negotiatedMtu;
      }
      await this.sleepMs(MtaConstants.GATT_MTU_POLL_MS);
      waited += MtaConstants.GATT_MTU_POLL_MS;
    }
    return this.negotiatedMtu > 0 ? this.negotiatedMtu : MtaConstants.BLE_DEFAULT_MTU;
  }

  /**
   * 确保 MTU 已协商（幂等）。读写长特征值前调用：
   * 默认 MTU=23 时长特征值需分片读取，部分对端（如荣耀）不按 offset 返回，
   * 会导致读到重复前缀而解析失败。
   */
  async ensureMtuNegotiated(): Promise<number> {
    if (this.negotiatedMtu > 0) {
      return this.negotiatedMtu;
    }
    let client = this.gattClient;
    if (client === null) {
      throw new Error('GATT Client 未连接，无法协商 MTU');
    }
    this.requestMtu(client);
    return await this.waitMtuNegotiated(MtaConstants.GATT_MTU_TIMEOUT_MS);
  }

  /** 读取对端 CHAR_STATUS 返回的 DeviceInfo（失败抛文本错误） */
  async readRemoteDeviceInfo(): Promise<DeviceInfoJson> {
    let client = this.gattClient;
    if (client === null) {
      throw new Error('GATT Client 未连接，请先连接');
    }
    // 先协商 MTU，保证长特征值（DeviceInfo）单包读回，避免分片重复
    await this.ensureMtuNegotiated();
    let targetChar = await this.findCharacteristic(client, MtaConstants.CHAR_STATUS_UUID);
    let result: ble.BLECharacteristic = await client.readCharacteristicValue(targetChar);
    let raw = decodeUtf8(new Uint8Array(result.characteristicValue));
    if (raw.length === 0) {
      throw new Error('对端 CHAR_STATUS 返回为空');
    }
    let info = parseDeviceInfo(raw);
    if (info === undefined) {
      throw new Error('DeviceInfo 解析失败: ' + raw);
    }
    if (this.handlers !== null) {
      this.handlers.onRemoteDeviceInfo(info);
    }
    return info;
  }

  /** 向对端 CHAR_P2P 写入 P2pInfo JSON（先确保 MTU 已协商，使用带响应写） */
  async writeRemoteP2pInfo(p2pInfoJson: string): Promise<void> {
    let client = this.gattClient;
    if (client === null) {
      throw new Error('GATT Client 未连接，请先写入');
    }
    // 协商 MTU：写 P2pInfo 需 ≥ 259 字节单包能力（读路径已确保协商）
    let mtu = await this.ensureMtuNegotiated();
    let bytes = new util.TextEncoder().encodeInto(p2pInfoJson);
    if (bytes.length > mtu - 3) {
      throw new Error(`P2pInfo 长度 ${bytes.length} 超过单次可写上限 ${mtu - 3}（MTU=${mtu}）`);
    }
    let targetChar = await this.findCharacteristic(client, MtaConstants.CHAR_P2P_UUID);
    targetChar.characteristicValue = toArrayBuffer(bytes);
    try {
      await client.writeCharacteristicValue(targetChar, ble.GattWriteType.WRITE);
    } catch (e) {
      throw new Error('写入 CHAR_P2P 失败: ' + errorText(e));
    }
  }

  /** 在 GATT 服务中定位指定特征；服务发现偶发失败时重试，仍失败抛文本错误 */
  private async findCharacteristic(client: ble.GattClientDevice,
    characteristicUuid: string): Promise<ble.BLECharacteristic> {
    let lastReason = `未找到 GATT 服务或特征 ${characteristicUuid}`;
    for (let attempt = 1; attempt <= MtaConstants.GATT_DISCOVERY_MAX_ATTEMPTS; attempt++) {
      try {
        let services: Array<ble.GattService> = await client.getServices();
        let target = this.pickCharacteristic(services, characteristicUuid);
        if (target !== undefined) {
          return target;
        }
      } catch (e) {
        lastReason = '服务发现失败: ' + errorText(e);
      }
      if (attempt < MtaConstants.GATT_DISCOVERY_MAX_ATTEMPTS) {
        await this.sleepMs(MtaConstants.GATT_DISCOVERY_RETRY_DELAY_MS);
      }
    }
    throw new Error(lastReason);
  }

  /** 在服务列表中定位指定特征，缺失返回 undefined */
  private pickCharacteristic(services: Array<ble.GattService>,
    characteristicUuid: string): ble.BLECharacteristic | undefined {
    for (let i = 0; i < services.length; i++) {
      if (services[i].serviceUuid.toLowerCase() !== MtaConstants.GATT_SERVICE_UUID) {
        continue;
      }
      let characteristics = services[i].characteristics;
      for (let j = 0; j < characteristics.length; j++) {
        if (characteristics[j].characteristicUuid.toLowerCase() === characteristicUuid) {
          return characteristics[j];
        }
      }
    }
    return undefined;
  }

  /** 断开并释放 GATT Client 实例 */
  disconnectGattClient(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let client = this.gattClient;
      if (client === null) {
        resolve();
        return;
      }
      this.gattClient = null;
      this.gattClientConnected = false;
      this.gattClientTarget = '';
      this.negotiatedMtu = 0;
      try {
        client.off('BLEConnectionStateChange');
        client.off('BLEMtuChange');
        client.disconnect();
        client.close();
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 延时辅助 */
  private sleepMs(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  // ── 资源释放 ──

  /** 页面退出时释放全部资源（扫描/GATT Client/事件） */
  destroy(): void {
    this.stopScan().catch((): void => {
    });
    this.disconnectGattClient().catch((): void => {
    });
    this.unregisterEvents();
  }
}
