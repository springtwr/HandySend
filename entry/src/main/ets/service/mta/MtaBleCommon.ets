/**
 * MtaBleCommon.ets — MTA BLE 收发两端共用辅助
 *
 * 集中接收端（MtaBleReceiver）与发送端（MtaBleClient）重复的
 * 字节/文本转换纯函数与蓝牙权限、开关查询逻辑，避免两份实现漂移。
 */

import { access, constant } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { errorText } from '../../utils/FormatUtil';

/** 复制 Uint8Array 到独立 ArrayBuffer（BLE API 要求 ArrayBuffer 入参） */
export function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  let buffer = new ArrayBuffer(bytes.length);
  let view = new Uint8Array(buffer);
  view.set(bytes, 0);
  return buffer;
}

/** 蓝牙开关状态枚举 → 文本 */
export function bluetoothStateText(state: access.BluetoothState): string {
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
export function profileStateText(state: constant.ProfileConnectionState): string {
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
export function decodeUtf8(bytes: Uint8Array): string {
  try {
    return new util.TextDecoder().decodeToString(bytes);
  } catch (e) {
    return '';
  }
}

/** 运行时申请 ACCESS_BLUETOOTH 权限，返回是否授予；失败 reject 文本描述 */
export function ensureBluetoothPermission(context: common.Context): Promise<boolean> {
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
export function queryBluetoothStateText(): string {
  try {
    return bluetoothStateText(access.getState());
  } catch (e) {
    return '查询失败';
  }
}

/** 蓝牙是否已开启 */
export function isBluetoothEnabled(): boolean {
  try {
    let state = access.getState();
    return state === access.BluetoothState.STATE_ON || state === access.BluetoothState.STATE_BLE_ON;
  } catch (e) {
    return false;
  }
}

/** 弹系统对话框开启蓝牙 */
export function enableBluetoothSystem(): void {
  access.enableBluetooth();
}
