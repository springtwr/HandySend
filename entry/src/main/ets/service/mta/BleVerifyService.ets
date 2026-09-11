/**
 * BleVerifyService.ets — MTA BLE 验证服务
 *
 * 封装 @kit.ConnectivityKit 的 BLE 能力：广播、GATT Server、扫描、GATT Client，
 * 以及蓝牙开关状态与运行时权限申请、ECDH P-256 公钥生成。
 * 本服务只采集/转发数据，不持有页面状态；错误统一文本化（[错误码] 信息）上抛。
 */

import { ble, access, constant } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import {
  BleEventHandlers,
  ScannedMtaDeviceView,
  formatTimeText
} from '../../model/mta/BleVerifyModels';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaBleVerify', '互传蓝牙验证');

// ── MTA 协议常量 ──

/** 广播主 serviceUuid（MTA 发现标识，注意为非标准基址 ...008123456789，与 CatShare/OPPOShareReceiver 一致） */
const MTA_ADV_SERVICE_UUID = '00003331-0000-1000-8000-008123456789';
/** 主广播 serviceData UUID（6 字节：2B 发送者 ID + 4B 零） */
const MTA_ADV_DATA_UUID = '000001ff-0000-1000-8000-00805f9b34fb';
/** 扫描响应 serviceData UUID（27 字节：零填充 + 发送者 ID + 设备名 + 0x01） */
const MTA_SCAN_RSP_UUID = '0000ffff-0000-1000-8000-00805f9b34fb';
/** GATT 服务 UUID */
const MTA_GATT_SERVICE_UUID = '00009955-0000-1000-8000-00805f9b34fb';
/** CHAR_STATUS 特征 UUID（读 → DeviceInfo JSON） */
const MTA_CHAR_STATUS_UUID = '00009954-0000-1000-8000-00805f9b34fb';
/** CHAR_P2P 特征 UUID（写 → P2pInfo JSON） */
const MTA_CHAR_P2P_UUID = '00009953-0000-1000-8000-00805f9b34fb';

/** 扫描响应固定长度（字节） */
const SCAN_RSP_LENGTH = 27;
/** 扫描响应中设备名字段起始偏移 */
const SCAN_RSP_NAME_OFFSET = 10;
/** 扫描响应中设备名字段长度（字节） */
const SCAN_RSP_NAME_LENGTH = 16;
/** 设备名 UTF-8 最大字节数 */
const DEVICE_NAME_MAX_BYTES = 15;
/** 发送者 ID 长度（字节） */
const SENDER_ID_LENGTH = 2;
/** prepared write 会话缓冲上限（字节） */
const MAX_WRITE_BUFFER = 2048;
/** DeviceInfo 兜底 MAC（三方应用无法获取可靠真实蓝牙 MAC） */
const FALLBACK_MAC = '02:00:00:00:00:00';
/** DeviceInfo.catShare 版本标识（CatShare 惯例值） */
const CATSHARE_VERSION = 7;

/** DeviceInfo JSON（CHAR_STATUS 读返回） */
interface DeviceInfoJson {
  state: number;
  mac: string;
  key: string;
  catShare: number;
}

// ── 通用工具函数 ──

/**
 * 将系统同步调用的异常统一转换为可读文本。
 * 系统异常多为 BusinessError（含 code/message 字段），
 * 通过 Record 读取字段，避免 instanceof 类型值判断。
 */
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

/** 字节数组转空格分隔的十六进制字符串（便于核对广播字节） */
function bytesToHexSpaced(bytes: Uint8Array): string {
  let parts: Array<string> = [];
  for (let i = 0; i < bytes.length; i++) {
    let h = bytes[i].toString(16);
    parts.push(h.length === 1 ? '0' + h : h);
  }
  return parts.join(' ');
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

/** 品牌 ID → 品牌名（映射表见研究报告 §3.3） */
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
  if (brandId === 0xff) {
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

/** 按协议容错规则从原始文本提取 JSON：首个 `{` 到最后一个 `}`，无匹配则原样返回 */
function extractJsonText(raw: string): string {
  let start = raw.indexOf('{');
  let end = raw.lastIndexOf('}');
  if (start >= 0 && end > start) {
    return raw.substring(start, end + 1);
  }
  return raw;
}

/** 解码扫描响应中的设备名字段：去除尾部 \t 与 0x00 填充后按 UTF-8 解码 */
function decodeNameField(bytes: Uint8Array): string {
  let end = bytes.length;
  while (end > 0 && (bytes[end - 1] === 0x09 || bytes[end - 1] === 0x00)) {
    end--;
  }
  return decodeUtf8(bytes.slice(0, end));
}

/**
 * BLE 验证服务。
 * 所有 Promise 方法失败时 reject 文本描述（调用方直接记入日志）。
 */
export class BleVerifyService {
  /** 事件回调集合（ViewModel 注入） */
  private handlers: BleEventHandlers | null = null;

  // ── 广播 ──
  /** 是否正在广播 */
  private advertising: boolean = false;
  /** 2 字节随机发送者 ID */
  private senderId: Uint8Array = new Uint8Array(SENDER_ID_LENGTH);
  /** 最近一次构造的主广播字节 */
  private mainAdvBytes: Uint8Array = new Uint8Array(0);
  /** 最近一次构造的扫描响应字节 */
  private scanRspBytes: Uint8Array = new Uint8Array(0);

  // ── GATT Server ──
  /** GATT Server 实例 */
  private gattServer: ble.GattServer | null = null;
  /** 是否运行中 */
  private gattRunning: boolean = false;
  /** 本机 ECDH 公钥（Base64 SPKI DER） */
  private ecdhPublicKeyBase64: string = '';
  /** CHAR_STATUS 返回的 DeviceInfo JSON 文本 */
  private deviceInfoJson: string = '';
  /** DeviceInfo JSON 的 UTF-8 字节（读请求按 offset 切片返回） */
  private deviceInfoBytes: Uint8Array = new Uint8Array(0);
  /** 已连接客户端地址 */
  private connectedClientId: string = '';
  /** 读请求计数 */
  private readRequestCount: number = 0;
  /** prepared write 会话缓冲 */
  private writeBuffer: Uint8Array = new Uint8Array(0);

  // ── 扫描 ──
  /** 是否扫描中 */
  private scanning: boolean = false;
  /** 已发现设备按 deviceId 去重（值为最近一次 RSSI） */
  private scanDeviceMap: Map<string, number> = new Map();

  // ── GATT Client ──
  /** GATT Client 实例 */
  private gattClient: ble.GattClientDevice | null = null;
  /** GATT Client 目标设备标识 */
  private gattClientTarget: string = '';
  /** GATT Client 是否已连接 */
  private gattClientConnected: boolean = false;

  // ── 事件注册 / 反注册 ──

  /** 注册蓝牙开关事件；重复注册时先反注册旧回调 */
  registerEvents(handlers: BleEventHandlers): void {
    if (this.handlers !== null) {
      this.unregisterEvents();
    }
    this.handlers = handlers;
    try {
      access.on('stateChange', (state: access.BluetoothState) => {
        if (this.handlers !== null) {
          this.handlers.onBluetoothStateChange(bluetoothStateText(state));
        }
      });
    } catch (e) {
      logger.warn('stateChange 注册失败: ' + errorText(e));
    }
  }

  /** 反注册蓝牙开关事件 */
  unregisterEvents(): void {
    try {
      access.off('stateChange');
    } catch (e) {
      logger.warn('stateChange 反注册失败: ' + errorText(e));
    }
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

  /** 查询蓝牙开关状态 */
  getBluetoothState(): access.BluetoothState {
    return access.getState();
  }

  /** 查询蓝牙开关状态文本 */
  getBluetoothStateText(): string {
    return bluetoothStateText(access.getState());
  }

  /** 弹系统对话框开启蓝牙 */
  enableBluetooth(): void {
    access.enableBluetooth();
  }

  // ── 广播（US1） ──

  /** 生成 2 字节随机发送者 ID */
  private randomSenderId(): void {
    let id = new Uint8Array(SENDER_ID_LENGTH);
    for (let i = 0; i < SENDER_ID_LENGTH; i++) {
      id[i] = Math.floor(Math.random() * 256);
    }
    this.senderId = id;
  }

  /** 发送者 ID 的十六进制文本 */
  getSenderIdHex(): string {
    return bytesToHex(this.senderId);
  }

  /** 是否正在广播 */
  isAdvertising(): boolean {
    return this.advertising;
  }

  /**
   * 将设备名编码为扫描响应中的 16 字节字段：
   * UTF-8 超过 15 字节按字符边界截断，不足部分补 \t（0x09）。
   */
  private encodeNameField(deviceName: string): Uint8Array {
    let field = new Uint8Array(SCAN_RSP_NAME_LENGTH);
    field.fill(0x09);
    // TextEncoder.encodeInto 对空字符串返回 undefined，空名直接返回全填充字段
    if (deviceName.length === 0) {
      return field;
    }
    let encoded = new util.TextEncoder().encodeInto(deviceName);
    let take = encoded.length > DEVICE_NAME_MAX_BYTES ? DEVICE_NAME_MAX_BYTES : encoded.length;
    // 避免截断多字节字符：若截断处落在 UTF-8 续字节（0b10xxxxxx）上则回退
    while (take > 0 && take < encoded.length && (encoded[take] & 0xc0) === 0x80) {
      take--;
    }
    field.set(encoded.slice(0, take), 0);
    return field;
  }

  /** 构造主广播数据：serviceUuid + 6 字节 serviceData（2B 发送者 ID + 4B 零） */
  private buildMainAdvData(): ble.AdvertiseData {
    let bytes = new Uint8Array(6);
    bytes[0] = this.senderId[0];
    bytes[1] = this.senderId[1];
    this.mainAdvBytes = bytes;
    let sd: ble.ServiceData = {
      serviceUuid: MTA_ADV_DATA_UUID,
      serviceValue: toArrayBuffer(bytes)
    };
    let data: ble.AdvertiseData = {
      serviceUuids: [MTA_ADV_SERVICE_UUID],
      manufactureData: [],
      serviceData: [sd]
    };
    return data;
  }

  /** 构造扫描响应数据：27 字节 serviceData（零填充 + 发送者 ID + 设备名 + 0x01） */
  private buildScanRspData(deviceName: string): ble.AdvertiseData {
    let bytes = new Uint8Array(SCAN_RSP_LENGTH);
    bytes[8] = this.senderId[0];
    bytes[9] = this.senderId[1];
    bytes.set(this.encodeNameField(deviceName), SCAN_RSP_NAME_OFFSET);
    bytes[SCAN_RSP_LENGTH - 1] = 0x01;
    this.scanRspBytes = bytes;
    let sd: ble.ServiceData = {
      serviceUuid: MTA_SCAN_RSP_UUID,
      serviceValue: toArrayBuffer(bytes)
    };
    let data: ble.AdvertiseData = {
      serviceUuids: [],
      manufactureData: [],
      serviceData: [sd]
    };
    return data;
  }

  /** 启动 MTA 格式广播（主广播 + 扫描响应），返回构造出的字节预览 */
  startAdvertising(deviceName: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      try {
        this.randomSenderId();
        let setting: ble.AdvertiseSetting = {
          interval: 160,
          txPower: 1,
          connectable: true
        };
        let mainData = this.buildMainAdvData();
        let rspData = this.buildScanRspData(deviceName);
        ble.startAdvertising(setting, mainData, rspData);
        this.advertising = true;
        if (this.handlers !== null) {
          this.handlers.onAdvertiseStateChange(true, '广播已启动 interval=160 txPower=1 connectable=true');
        }
        let preview = `主广播(${this.mainAdvBytes.length}B): ${bytesToHexSpaced(this.mainAdvBytes)}\n` +
          `扫描响应(${this.scanRspBytes.length}B): ${bytesToHexSpaced(this.scanRspBytes)}`;
        resolve(preview);
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 停止广播 */
  stopAdvertising(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (!this.advertising) {
        resolve();
        return;
      }
      try {
        ble.stopAdvertising();
        this.advertising = false;
        if (this.handlers !== null) {
          this.handlers.onAdvertiseStateChange(false, '广播已停止');
        }
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  // ── ECDH 公钥（US2） ──

  /**
   * 生成 ECDH P-256 密钥对，返回 Base64(X.509 SPKI DER) 公钥。
   * getEncoded() 返回的即为标准 SPKI DER，无需格式转换。
   */
  async generateEcdhPublicKey(): Promise<string> {
    let generator = cryptoFramework.createAsyKeyGenerator('ECC256');
    let keyPair = await generator.generateKeyPair();
    let encoded = keyPair.pubKey.getEncoded();
    let base64 = new util.Base64Helper().encodeToStringSync(encoded.data, util.Type.BASIC);
    this.ecdhPublicKeyBase64 = base64;
    return base64;
  }

  /** 最近一次生成的 ECDH 公钥（Base64） */
  getEcdhPublicKey(): string {
    return this.ecdhPublicKeyBase64;
  }

  // ── GATT Server（US2） ──

  /** GATT Server 是否运行中 */
  isGattRunning(): boolean {
    return this.gattRunning;
  }

  /** 已连接客户端地址 */
  getConnectedClientId(): string {
    return this.connectedClientId;
  }

  /** 读请求计数 */
  getReadRequestCount(): number {
    return this.readRequestCount;
  }

  /** 写缓冲当前长度 */
  getWriteBufferLength(): number {
    return this.writeBuffer.length;
  }

  /** 启动 GATT Server：生成 ECDH 公钥 → 构造 DeviceInfo → 注册服务与特征值 → 订阅读写/连接事件，返回 DeviceInfo JSON */
  async startGattServer(): Promise<string> {
    if (this.gattServer !== null) {
      throw new Error('GATT Server 已在运行');
    }
    let publicKey = await this.generateEcdhPublicKey();
    let info: DeviceInfoJson = {
      state: 0,
      mac: FALLBACK_MAC,
      key: publicKey,
      catShare: CATSHARE_VERSION
    };
    this.deviceInfoJson = JSON.stringify(info);
    this.deviceInfoBytes = new util.TextEncoder().encodeInto(this.deviceInfoJson);
    this.readRequestCount = 0;
    this.writeBuffer = new Uint8Array(0);
    this.connectedClientId = '';

    let server = ble.createGattServer();
    let statusChar: ble.BLECharacteristic = {
      serviceUuid: MTA_GATT_SERVICE_UUID,
      characteristicUuid: MTA_CHAR_STATUS_UUID,
      characteristicValue: toArrayBuffer(this.deviceInfoBytes),
      descriptors: [],
      properties: { read: true }
    };
    let p2pChar: ble.BLECharacteristic = {
      serviceUuid: MTA_GATT_SERVICE_UUID,
      characteristicUuid: MTA_CHAR_P2P_UUID,
      characteristicValue: new ArrayBuffer(0),
      descriptors: [],
      properties: { write: true, writeNoResponse: true }
    };
    let service: ble.GattService = {
      serviceUuid: MTA_GATT_SERVICE_UUID,
      isPrimary: true,
      characteristics: [statusChar, p2pChar]
    };
    server.addService(service);

    server.on('characteristicRead', (req: ble.CharacteristicReadRequest) => {
      this.handleCharacteristicRead(server, req);
    });
    server.on('characteristicWrite', (req: ble.CharacteristicWriteRequest) => {
      this.handleCharacteristicWrite(server, req);
    });
    server.on('connectionStateChange', (state: ble.BLEConnectionChangeState) => {
      this.handleGattConnection(state);
    });

    this.gattServer = server;
    this.gattRunning = true;
    return this.deviceInfoJson;
  }

  /** 处理 CHAR_STATUS 读请求：按 offset 切片返回 DeviceInfo JSON */
  private handleCharacteristicRead(server: ble.GattServer, req: ble.CharacteristicReadRequest): void {
    this.readRequestCount = this.readRequestCount + 1;
    if (this.handlers !== null) {
      this.handlers.onGattReadRequest(req.deviceId, req.offset);
    }
    let start = req.offset > 0 ? req.offset : 0;
    let slice: Uint8Array = start >= this.deviceInfoBytes.length ?
      new Uint8Array(0) : this.deviceInfoBytes.slice(start);
    let resp: ble.ServerResponse = {
      deviceId: req.deviceId,
      transId: req.transId,
      status: 0,
      offset: req.offset,
      value: toArrayBuffer(slice)
    };
    try {
      server.sendResponse(resp);
    } catch (e) {
      logger.warn('sendResponse(读) 失败: ' + errorText(e));
    }
  }

  /** 处理 CHAR_P2P 写请求：prepared write 按 offset 累积，提交时提取 JSON */
  private handleCharacteristicWrite(server: ble.GattServer, req: ble.CharacteristicWriteRequest): void {
    let value = new Uint8Array(req.value);
    if (req.isPrepared) {
      this.accumulateWrite(req.offset, value);
      if (this.handlers !== null) {
        this.handlers.onGattWriteProgress(req.deviceId, req.offset, this.writeBuffer.length, true);
      }
    } else {
      // 普通写入（单包）或 prepared write 的提交请求
      if (value.length > 0) {
        this.accumulateWrite(req.offset, value);
      }
      let payload = extractJsonText(decodeUtf8(this.writeBuffer));
      if (this.handlers !== null) {
        this.handlers.onGattWriteProgress(req.deviceId, req.offset, this.writeBuffer.length, false);
        this.handlers.onGattWriteComplete(req.deviceId, payload);
      }
      this.writeBuffer = new Uint8Array(0);
    }
    if (req.needRsp) {
      let resp: ble.ServerResponse = {
        deviceId: req.deviceId,
        transId: req.transId,
        status: 0,
        offset: req.offset,
        value: toArrayBuffer(new Uint8Array(0))
      };
      try {
        server.sendResponse(resp);
      } catch (e) {
        logger.warn('sendResponse(写) 失败: ' + errorText(e));
      }
    }
  }

  /** 按 offset 累积写分片，超过缓冲上限则忽略 */
  private accumulateWrite(offset: number, value: Uint8Array): void {
    if (offset < 0) {
      return;
    }
    let needed = offset + value.length;
    if (needed > MAX_WRITE_BUFFER) {
      logger.warn(`写入超出缓冲上限 ${MAX_WRITE_BUFFER} 字节，已忽略 offset=${offset} len=${value.length}`);
      return;
    }
    let size = needed > this.writeBuffer.length ? needed : this.writeBuffer.length;
    let next = new Uint8Array(size);
    next.set(this.writeBuffer, 0);
    next.set(value, offset);
    this.writeBuffer = next;
  }

  /** 处理 GATT 连接状态变化 */
  private handleGattConnection(state: ble.BLEConnectionChangeState): void {
    if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
      this.connectedClientId = state.deviceId;
    } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
      this.connectedClientId = '';
    }
    if (this.handlers !== null) {
      this.handlers.onGattConnectionChange(state.deviceId, profileStateText(state.state));
    }
  }

  /** 停止 GATT Server：移除服务、反注册回调并清空写缓冲 */
  stopGattServer(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let server = this.gattServer;
      if (server === null) {
        resolve();
        return;
      }
      this.gattServer = null;
      this.gattRunning = false;
      try {
        server.off('characteristicRead');
        server.off('characteristicWrite');
        server.off('connectionStateChange');
        server.removeService(MTA_GATT_SERVICE_UUID);
        server.close();
        this.writeBuffer = new Uint8Array(0);
        this.connectedClientId = '';
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  // ── 扫描（US3） ──

  /** 是否扫描中 */
  isScanning(): boolean {
    return this.scanning;
  }

  /** 已发现设备数（按 deviceId 去重） */
  getScannedDeviceCount(): number {
    return this.scanDeviceMap.size;
  }

  /** 启动 BLE 扫描：按 MTA 主广播 serviceUuid 过滤，低延迟 + 激进匹配 */
  startScan(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.scanning) {
        resolve();
        return;
      }
      try {
        let filter: ble.ScanFilter = { serviceUuid: MTA_ADV_SERVICE_UUID };
        let filters: Array<ble.ScanFilter> = [filter];
        let options: ble.ScanOptions = {
          dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
          matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
        };
        ble.on('BLEDeviceFind', (results: Array<ble.ScanResult>) => {
          this.handleScanResults(results);
        });
        ble.startBLEScan(filters, options);
        this.scanDeviceMap = new Map();
        this.scanning = true;
        resolve();
      } catch (e) {
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
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 批量处理扫描结果：按 deviceId 去重、保留最新 RSSI 后上报 */
  private handleScanResults(results: Array<ble.ScanResult>): void {
    for (let i = 0; i < results.length; i++) {
      let device = this.parseScanResult(results[i]);
      let prevRssi = this.scanDeviceMap.get(device.deviceId);
      if (prevRssi === undefined || prevRssi !== device.rssi) {
        this.scanDeviceMap.set(device.deviceId, device.rssi);
        if (this.handlers !== null) {
          this.handlers.onDeviceFound(device);
        }
      }
    }
  }

  /** 解析单条扫描结果：扫描响应 serviceData 解析设备名/发送者 ID，品牌 UUID 字节解析 5GHz/品牌 */
  private parseScanResult(result: ble.ScanResult): ScannedMtaDeviceView {
    let device = new ScannedMtaDeviceView();
    device.deviceId = result.deviceId;
    device.deviceName = result.deviceName;
    device.rssi = result.rssi;
    device.foundTimeText = formatTimeText(new Date());
    device.senderIdHex = '';
    device.brandName = '未知';
    device.is5Ghz = false;

    let map = result.serviceDataMap;
    if (map === undefined) {
      return device;
    }
    map.forEach((value: Uint8Array, key: string): void => {
      let compact = key.split('-').join('').toLowerCase();
      if (compact.startsWith('0000ffff')) {
        if (value.length >= SCAN_RSP_LENGTH) {
          device.senderIdHex = bytesToHex(value.slice(8, 10));
          let nameField = value.slice(SCAN_RSP_NAME_OFFSET, SCAN_RSP_NAME_OFFSET + SCAN_RSP_NAME_LENGTH);
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
          device.brandName = brandNameOf(brandId);
        }
      }
    });
    return device;
  }

  // ── GATT Client（US4） ──

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
        client.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
          if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
            this.gattClientConnected = true;
          } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
            this.gattClientConnected = false;
          }
          if (this.handlers !== null) {
            this.handlers.onGattClientConnectionChange(profileStateText(state.state));
          }
        });
        client.connect();
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 读取对端 CHAR_STATUS 返回的 DeviceInfo 文本 */
  async readRemoteDeviceInfo(): Promise<string> {
    let client = this.gattClient;
    if (client === null) {
      throw new Error('GATT Client 未连接，请先连接');
    }
    let services: Array<ble.GattService> = await client.getServices();
    let targetService: ble.GattService | undefined = undefined;
    for (let i = 0; i < services.length; i++) {
      if (services[i].serviceUuid.toLowerCase() === MTA_GATT_SERVICE_UUID) {
        targetService = services[i];
        break;
      }
    }
    if (targetService === undefined) {
      throw new Error(`未找到 GATT 服务 ${MTA_GATT_SERVICE_UUID}`);
    }
    let targetChar: ble.BLECharacteristic | undefined = undefined;
    let characteristics = targetService.characteristics;
    for (let j = 0; j < characteristics.length; j++) {
      if (characteristics[j].characteristicUuid.toLowerCase() === MTA_CHAR_STATUS_UUID) {
        targetChar = characteristics[j];
        break;
      }
    }
    if (targetChar === undefined) {
      throw new Error(`未找到特征 ${MTA_CHAR_STATUS_UUID}`);
    }
    let result: ble.BLECharacteristic = await client.readCharacteristicValue(targetChar);
    return decodeUtf8(new Uint8Array(result.characteristicValue));
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
      try {
        client.off('BLEConnectionStateChange');
        client.disconnect();
        client.close();
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  // ── 资源释放 ──

  /** 页面退出时释放全部资源（广播/扫描/GATT Server/GATT Client/事件） */
  destroy(): void {
    this.stopAdvertising().catch(() => {
    });
    this.stopScan().catch(() => {
    });
    this.stopGattServer().catch(() => {
    });
    this.disconnectGattClient().catch(() => {
    });
    this.unregisterEvents();
  }
}
