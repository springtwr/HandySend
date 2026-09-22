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
import { util } from '@kit.ArkTS';
import { DeviceInfoJson, parseDeviceInfo } from '../../model/mta/MtaProtocolModels';
import {
  MtaAdvParseResult,
  MtaBleClientEventHandlers,
  MtaDiscoveredDevice,
  parseMtaAdvServiceData
} from '../../model/mta/MtaSendModels';
import { MtaConstants } from './MtaConstants';
import {
  decodeUtf8,
  profileStateText,
  registerBluetoothStateEvent,
  sleepMs,
  toArrayBuffer,
  unregisterBluetoothStateEvent
} from './MtaBleCommon';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { errorText } from '../../utils/FormatUtil';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaBleClient', '互传蓝牙');

/** 扫描解析签名映射的条目上限（有界，超出即清空以限制内存与日志量） */
const SCAN_SIGNATURE_MAX_ENTRIES: number = 512;

/** 单条扫描结果的解析诊断产物：设备视图 + 原始广播 + 异常 + 去重签名 */
class ScanParseResult {
  /** 解析出的设备视图 */
  device: MtaDiscoveredDevice = new MtaDiscoveredDevice();
  /** 原始 serviceData 描述（`UUID=字节hex`，多个以逗号连接） */
  rawServiceData: string = '';
  /** 异常描述（空表示未发现异常） */
  abnormal: string = '';
  /** 解析签名（含原始字节与解析字段，不含 RSSI，用于日志去重） */
  signature: string = '';
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
  // ── 扫描 ──
  /** 是否扫描中 */
  private scanning: boolean = false;
  /** 已发现设备按 deviceId 去重（值为最近一次 RSSI） */
  private scanDeviceRssi: Map<string, number> = new Map();
  /** 已记录解析签名的设备（deviceId → 签名），用于诊断日志去重；与 scanDeviceRssi 分离 */
  private scanDeviceSignature: Map<string, string> = new Map();
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

  /**
   * 已注册的蓝牙开关回调引用：反注册时必须按引用精确移除。
   * 无参 access.off('stateChange') 会移除所有监听者（含接收端实例），
   * 导致对端再也收不到蓝牙开关事件。
   */
  private stateChangeCallback: ((state: access.BluetoothState) => void) | undefined = undefined;

  /** 注册蓝牙开关事件；重复注册时先反注册旧回调 */
  registerEvents(handlers: MtaBleClientEventHandlers): void {
    this.unregisterEvents();
    this.handlers = handlers;
    this.stateChangeCallback = registerBluetoothStateEvent((stateText: string): void => {
      if (this.handlers !== null) {
        this.handlers.onBluetoothStateChange(stateText);
      }
    });
  }

  /** 反注册蓝牙开关事件（仅移除本实例的回调） */
  unregisterEvents(): void {
    unregisterBluetoothStateEvent(this.stateChangeCallback);
    this.stateChangeCallback = undefined;
    this.handlers = null;
  }

  // ── 扫描 ──

  /** 启动 BLE 扫描：按 MTA 主广播 serviceUuid 过滤，均衡功耗（扫描期间常驻）+ 激进匹配 */
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
          dutyMode: ble.ScanDuty.SCAN_MODE_BALANCED,
          matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
        };
        ble.on('BLEDeviceFind', (results: Array<ble.ScanResult>) => {
          this.handleScanResults(results);
        });
        ble.startBLEScan(filters, options);
        this.scanDeviceRssi = new Map();
        this.scanDeviceSignature = new Map();
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

  /** 批量处理扫描结果：按 deviceId 去重，相同 RSSI 的重复结果不上报（RSSI 变化即上报） */
  private handleScanResults(results: Array<ble.ScanResult>): void {
    for (let i = 0; i < results.length; i++) {
      let parsed = this.parseScanResult(results[i]);
      let device = parsed.device;
      let prevRssi = this.scanDeviceRssi.get(device.bleAddress);
      if (prevRssi === undefined || prevRssi !== device.rssi) {
        this.scanDeviceRssi.set(device.bleAddress, device.rssi);
        if (this.handlers !== null) {
          this.handlers.onDeviceFound(device);
        }
      }
      // 日志去重独立于上报去重：仅设备首见或解析签名变化时记录，RSSI 抖动不重记
      let prevSignature = this.scanDeviceSignature.get(device.bleAddress);
      if (prevSignature === undefined || prevSignature !== parsed.signature) {
        this.recordScanSignature(device.bleAddress, parsed.signature);
        this.logScanDiagnostics(parsed);
      }
    }
  }

  /** 记录设备解析签名（有界：超出上限且为新设备时清空重记） */
  private recordScanSignature(deviceId: string, signature: string): void {
    if (this.scanDeviceSignature.size >= SCAN_SIGNATURE_MAX_ENTRIES && !this.scanDeviceSignature.has(deviceId)) {
      this.scanDeviceSignature.clear();
    }
    this.scanDeviceSignature.set(deviceId, signature);
  }

  /** 输出单条广播的诊断日志：解析结果与原始 serviceData，异常单独记录 */
  private logScanDiagnostics(parsed: ScanParseResult): void {
    let device = parsed.device;
    logger.debug(`广播解析 deviceId=${device.bleAddress} name=${device.deviceName}` +
      ` brandId=${device.brandId} brand=${device.brandName} is5Ghz=${device.is5Ghz}` +
      ` senderId=${device.senderIdHex} rssi=${device.rssi} raw=[${parsed.rawServiceData}]`);
    if (parsed.abnormal.length > 0) {
      logger.debug(`广播解析异常 deviceId=${device.bleAddress} rssi=${device.rssi} ${parsed.abnormal}`);
    }
  }

  /** 解析单条扫描结果：MTA serviceData 按值长度分类解析设备名/发送者 ID/品牌/5GHz，并采集原始广播与异常 */
  private parseScanResult(result: ble.ScanResult): ScanParseResult {
    let parsed = new ScanParseResult();
    let device = parsed.device;
    device.bleAddress = result.deviceId;
    device.deviceName = result.deviceName;
    device.rssi = result.rssi;

    let anomalies: Array<string> = [];
    let map = result.serviceDataMap;
    let adv: MtaAdvParseResult;
    if (map === undefined) {
      adv = new MtaAdvParseResult();
      anomalies.push('serviceDataMap 缺失');
    } else {
      adv = parseMtaAdvServiceData(map);
    }
    device.senderIdHex = adv.senderIdHex;
    device.brandId = adv.brandId;
    device.brandName = adv.brandName;
    device.is5Ghz = adv.is5Ghz;
    // 扫描响应携带名字字段时覆盖系统设备名；字段解析为空则保留系统名
    if (adv.nameBytes.length > 0) {
      let parsedName = decodeNameField(adv.nameBytes);
      if (parsedName.length > 0) {
        device.deviceName = parsedName;
      } else {
        anomalies.push('扫描响应设备名字段解析为空');
      }
    }

    parsed.rawServiceData = adv.rawServiceData;
    parsed.abnormal = adv.anomalies.concat(anomalies).join('; ');
    // 签名覆盖原始 serviceData 与解析字段（不含 RSSI），用于日志去重
    parsed.signature =
      `${parsed.rawServiceData}|name=${device.deviceName}` +
        `|brandId=${device.brandId}|is5Ghz=${device.is5Ghz}` +
        `|senderId=${device.senderIdHex}|abnormal=${parsed.abnormal}`;
    return parsed;
  }

  // ── GATT Client ──

  /** 连接对端 GATT Server：创建 Client → 订阅连接状态事件 → connect */
  connectGattClient(deviceId: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.gattClient !== null) {
        reject('已存在 GATT Client 连接，请先断开');
        return;
      }
      let client: ble.GattClientDevice | null = null;
      try {
        client = ble.createGattClientDevice(deviceId);
        const c: ble.GattClientDevice = client;
        this.gattClient = c;
        this.gattClientTarget = deviceId;
        this.gattClientConnected = false;
        this.negotiatedMtu = 0;
        c.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
          if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
            this.gattClientConnected = true;
          } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
            this.gattClientConnected = false;
          }
          if (this.handlers !== null) {
            this.handlers.onGattConnectionChange(profileStateText(state.state));
          }
        });
        c.on('BLEMtuChange', (mtu: number) => {
          this.negotiatedMtu = mtu;
          if (this.handlers !== null) {
            this.handlers.onMtuChange(mtu);
          }
        });
        c.connect();
        resolve();
      } catch (e) {
        // 连接中途失败时复位状态并释放 GATT Client，避免句柄泄漏后
        // 残留的 gattClient 阻断后续重连
        this.gattClient = null;
        this.gattClientTarget = '';
        this.gattClientConnected = false;
        this.negotiatedMtu = 0;
        if (client !== null) {
          try {
            client.close();
          } catch (closeErr) {
            logger.warn('GATT Client 关闭失败: ' + errorText(closeErr));
          }
        }
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
      logger.warn('setBLEMtuSize 失败: ' + errorText(e));
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

  /** 为 GATT 异步操作包装超时：超时抛文本错误，避免对端协议栈无响应时 Promise 永久挂起 */
  private withGattTimeout<T>(operation: Promise<T>, timeoutMs: number, label: string): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let settled = false;
      let timerId = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        reject(new Error(`${label}超时（${timeoutMs}ms）`));
      }, timeoutMs);
      // 挂接底层 promise：迟到的结果被忽略，迟到的异常也有接收方，不会成为 unhandled rejection
      operation.then((value: T): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timerId);
        resolve(value);
      }).catch((e: Object): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timerId);
        reject(e);
      });
    });
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
    let result: ble.BLECharacteristic = await this.withGattTimeout(
      client.readCharacteristicValue(targetChar), MtaConstants.GATT_READ_TIMEOUT_MS, '读取 DeviceInfo');
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
      throw new Error('GATT Client 未连接，请先连接');
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
      await this.withGattTimeout(client.writeCharacteristicValue(targetChar, ble.GattWriteType.WRITE),
        MtaConstants.GATT_WRITE_TIMEOUT_MS, '写入 P2pInfo');
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
        // 服务发现视作读操作，共用读超时（getServices 也可能永久挂起）
        let services: Array<ble.GattService> = await this.withGattTimeout(client.getServices(),
          MtaConstants.GATT_READ_TIMEOUT_MS, '服务发现');
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

  /** 延时辅助（共用实现见 MtaBleCommon） */
  private sleepMs(ms: number): Promise<void> {
    return sleepMs(ms);
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
