/**
 * MtaBleReceiver.ets — MTA 接收端 BLE 服务
 *
 * 改编自 BleVerifyService，仅保留接收端所需能力：MTA 格式广播（主广播 + 扫描响应）、
 * GATT Server（服务 00009955 + CHAR_STATUS 读 / CHAR_P2P 写）、蓝牙开关与权限检查。
 * 与 BleVerifyService 完全独立，互不影响；本服务只采集/转发数据，不持有页面状态。
 */

import { ble, access, constant } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { MtaBleEventHandlers, bytesToHex, extractJsonText } from '../../model/mta/MtaReceiveModels';
import { MtaConstants } from './MtaConstants';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.NETWORK, 'HandySend:MtaBleReceiver');

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

/** UTF-8 字节数组解码为文本（容错非法序列） */
function decodeUtf8(bytes: Uint8Array): string {
  try {
    return new util.TextDecoder().decodeToString(bytes);
  } catch (e) {
    return '';
  }
}

/** 将设备名编码为扫描响应中的 16 字节字段（UTF-8 截断到 15 字节，不足补 \t） */
function encodeNameField(deviceName: string): Uint8Array {
  let field = new Uint8Array(MtaConstants.SCAN_RSP_NAME_LENGTH);
  field.fill(MtaConstants.NAME_FIELD_PADDING);
  // TextEncoder.encodeInto 对空字符串返回 undefined，空名直接返回全填充字段
  if (deviceName.length === 0) {
    return field;
  }
  let encoded = new util.TextEncoder().encodeInto(deviceName);
  let take = encoded.length > MtaConstants.DEVICE_NAME_MAX_BYTES ?
    MtaConstants.DEVICE_NAME_MAX_BYTES : encoded.length;
  // 避免截断多字节字符：若截断处落在 UTF-8 续字节（0b10xxxxxx）上则回退
  while (take > 0 && take < encoded.length && (encoded[take] & 0xc0) === 0x80) {
    take--;
  }
  field.set(encoded.slice(0, take), 0);
  return field;
}

/**
 * MTA 接收端 BLE 服务。
 * 所有 Promise 方法失败时 reject 文本描述（调用方直接记入日志）。
 */
export class MtaBleReceiver {
  /** 事件回调集合（服务注入） */
  private handlers: MtaBleEventHandlers | null = null;

  // ── 广播 ──
  /** 是否正在广播 */
  private advertising: boolean = false;
  /** 2 字节随机发送者 ID */
  private senderId: Uint8Array = new Uint8Array(MtaConstants.SENDER_ID_LENGTH);
  /** 发送者 ID 是否已生成（广播重启时复用，避免对端识别为新设备） */
  private senderIdInitialized: boolean = false;
  /** 最近一次构造的主广播字节 */
  private mainAdvBytes: Uint8Array = new Uint8Array(0);
  /** 最近一次构造的扫描响应字节 */
  private scanRspBytes: Uint8Array = new Uint8Array(0);

  // ── GATT Server ──
  /** GATT Server 实例 */
  private gattServer: ble.GattServer | null = null;
  /** 是否运行中 */
  private gattRunning: boolean = false;
  /** DeviceInfo JSON 文本 */
  private deviceInfoJson: string = '';
  /** DeviceInfo JSON 的 UTF-8 字节（读请求按 offset 切片返回） */
  private deviceInfoBytes: Uint8Array = new Uint8Array(0);
  /** 已连接客户端地址 */
  private connectedClientId: string = '';
  /** prepared write 会话缓冲 */
  private writeBuffer: Uint8Array = new Uint8Array(0);

  // ── 事件注册 / 反注册 ──

  /** 注册蓝牙开关事件；重复注册时先反注册旧回调 */
  registerEvents(handlers: MtaBleEventHandlers): void {
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

  /** 查询蓝牙开关状态文本 */
  getBluetoothStateText(): string {    try {
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

  // ── 广播 ──

  /** 是否正在广播 */
  isAdvertising(): boolean {
    return this.advertising;
  }

  /** 发送者 ID 的十六进制文本 */
  getSenderIdHex(): string {
    return bytesToHex(this.senderId);
  }

  /** 生成 2 字节随机发送者 ID */
  private randomSenderId(): void {
    let id = new Uint8Array(MtaConstants.SENDER_ID_LENGTH);
    for (let i = 0; i < MtaConstants.SENDER_ID_LENGTH; i++) {
      id[i] = Math.floor(Math.random() * 256);
    }
    this.senderId = id;
  }

  /** 构造主广播数据：serviceUuid + 6 字节 serviceData（2B 发送者 ID + 4B 零） */
  private buildMainAdvData(): ble.AdvertiseData {
    let bytes = new Uint8Array(MtaConstants.ADV_DATA_LENGTH);
    bytes[0] = this.senderId[0];
    bytes[1] = this.senderId[1];
    this.mainAdvBytes = bytes;
    let serviceData: ble.ServiceData = {
      serviceUuid: MtaConstants.ADV_DATA_UUID,
      serviceValue: toArrayBuffer(bytes)
    };
    let data: ble.AdvertiseData = {
      serviceUuids: [MtaConstants.ADV_SERVICE_UUID],
      manufactureData: [],
      serviceData: [serviceData]
    };
    return data;
  }

  /** 构造扫描响应数据：27 字节 serviceData（零填充 + 发送者 ID + 设备名 + 0x01） */
  private buildScanRspData(deviceName: string): ble.AdvertiseData {
    let bytes = new Uint8Array(MtaConstants.SCAN_RSP_LENGTH);
    bytes[8] = this.senderId[0];
    bytes[9] = this.senderId[1];
    bytes.set(encodeNameField(deviceName), MtaConstants.SCAN_RSP_NAME_OFFSET);
    bytes[MtaConstants.SCAN_RSP_LENGTH - 1] = MtaConstants.SCAN_RSP_TAIL_FLAG;
    this.scanRspBytes = bytes;
    let serviceData: ble.ServiceData = {
      serviceUuid: MtaConstants.SCAN_RSP_UUID,
      serviceValue: toArrayBuffer(bytes)
    };
    let data: ble.AdvertiseData = {
      serviceUuids: [],
      manufactureData: [],
      serviceData: [serviceData]
    };
    return data;
  }

  /** 启动 MTA 格式广播（主广播 + 扫描响应），返回构造出的字节预览 */
  startAdvertising(deviceName: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      if (this.advertising) {
        resolve('广播已在运行');
        return;
      }
      try {
        // 发送者 ID 仅首次生成，后续广播重启复用，保持对端设备标识稳定
        if (!this.senderIdInitialized) {
          this.randomSenderId();
          this.senderIdInitialized = true;
        }
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
        let preview = `主广播(${this.mainAdvBytes.length}B) 发送者ID=${this.getSenderIdHex()}\n` +
          `扫描响应(${this.scanRspBytes.length}B) 设备名=${deviceName}`;
        resolve(preview);
      } catch (e) {
        // 异常路径清理可能已建立的广播句柄，避免残留导致后续无法重新广播
        try {
          ble.stopAdvertising();
        } catch (_e) {
        }
        this.advertising = false;
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
      // 无论系统调用是否抛错都复位标志，避免异常后卡在「广播中」而无法重播
      this.advertising = false;
      let failure = '';
      try {
        ble.stopAdvertising();
      } catch (e) {
        failure = errorText(e);
      }
      if (this.handlers !== null) {
        this.handlers.onAdvertiseStateChange(false, failure.length > 0 ? '广播已停止(异常)' : '广播已停止');
      }
      if (failure.length > 0) {
        reject(failure);
      } else {
        resolve();
      }
    });
  }

  // ── GATT Server ──

  /** GATT Server 是否运行中 */
  isGattRunning(): boolean {
    return this.gattRunning;
  }

  /** 已连接客户端地址 */
  getConnectedClientId(): string {
    return this.connectedClientId;
  }

  /** 启动 GATT Server：注册服务与两个特征值，订阅读写/连接事件 */
  startGattServer(deviceInfoJson: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.gattServer !== null) {
        reject('GATT Server 已在运行');
        return;
      }
      try {
        this.deviceInfoJson = deviceInfoJson;
        this.deviceInfoBytes = new util.TextEncoder().encodeInto(deviceInfoJson);
        this.writeBuffer = new Uint8Array(0);
        this.connectedClientId = '';

        let server = ble.createGattServer();
        let statusChar: ble.BLECharacteristic = {
          serviceUuid: MtaConstants.GATT_SERVICE_UUID,
          characteristicUuid: MtaConstants.CHAR_STATUS_UUID,
          characteristicValue: toArrayBuffer(this.deviceInfoBytes),
          descriptors: [],
          properties: { read: true }
        };
        let p2pChar: ble.BLECharacteristic = {
          serviceUuid: MtaConstants.GATT_SERVICE_UUID,
          characteristicUuid: MtaConstants.CHAR_P2P_UUID,
          characteristicValue: new ArrayBuffer(0),
          descriptors: [],
          properties: { write: true, writeNoResponse: true }
        };
        let service: ble.GattService = {
          serviceUuid: MtaConstants.GATT_SERVICE_UUID,
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
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 处理 CHAR_STATUS 读请求：按 offset 切片返回 DeviceInfo JSON */
  private handleCharacteristicRead(server: ble.GattServer, req: ble.CharacteristicReadRequest): void {
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

  /** 处理 CHAR_P2P 写请求：prepared write 按 offset 累积，提交时提取 JSON 并上报 */
  private handleCharacteristicWrite(server: ble.GattServer, req: ble.CharacteristicWriteRequest): void {
    let value = new Uint8Array(req.value);
    if (req.isPrepared) {
      // 分片写入：按 offset 累积到会话缓冲
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
        this.handlers.onP2pInfoReceived(req.deviceId, payload);
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

  /** 按 offset 累积写分片，超过缓冲上限则忽略该分片 */
  private accumulateWrite(offset: number, value: Uint8Array): void {
    if (offset < 0) {
      return;
    }
    let needed = offset + value.length;
    if (needed > MtaConstants.MAX_WRITE_BUFFER) {
      logger.warn(`写入超出缓冲上限 ${MtaConstants.MAX_WRITE_BUFFER} 字节，已忽略 offset=${offset} len=${value.length}`);
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
        server.removeService(MtaConstants.GATT_SERVICE_UUID);
        server.close();
        this.writeBuffer = new Uint8Array(0);
        this.connectedClientId = '';
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  // ── 资源释放 ──

  /** 页面退出时释放全部资源 */
  destroy(): void {
    this.stopAdvertising().catch((): void => {
    });
    this.stopGattServer().catch((): void => {
    });
    this.unregisterEvents();
  }
}
