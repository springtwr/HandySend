/**
 * MtaBleCommon.ets — MTA 收发两端共用辅助
 *
 * 集中接收端与发送端重复的逻辑：字节/文本转换纯函数、延时辅助、
 * Rust 日志排空，以及蓝牙权限、开关查询，避免两份实现漂移。
 */

import { access, constant } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { errorText } from '../../utils/FormatUtil';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { parseRustLogLine } from '../../model/mta/MtaSendModels';
import { nativePollDebugLogWithLevels } from '../NativeBridge';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaBleCommon', '互传BLE');

/**
 * 注册蓝牙开关事件并返回回调引用（反注册时必须按引用精确移除：
 * 无参 access.off('stateChange') 会移除所有监听者，误伤收发另一端）。
 * 注册失败返回 undefined。
 */
export function registerBluetoothStateEvent(
  onStateChange: (stateText: string) => void
): ((state: access.BluetoothState) => void) | undefined {
  try {
    let callback = (state: access.BluetoothState): void => {
      onStateChange(bluetoothStateText(state));
    };
    access.on('stateChange', callback);
    return callback;
  } catch (e) {
    logger.warn('stateChange 注册失败: ' + errorText(e));
    return undefined;
  }
}

/** 按引用反注册蓝牙开关事件（仅移除传入的回调；未注册时无操作） */
export function unregisterBluetoothStateEvent(
  callback: ((state: access.BluetoothState) => void) | undefined
): void {
  if (callback === undefined) {
    return;
  }
  try {
    access.off('stateChange', callback);
  } catch (e) {
    logger.warn('stateChange 反注册失败: ' + errorText(e));
  }
}

/** 复制 Uint8Array 到独立 ArrayBuffer（BLE API 要求 ArrayBuffer 入参） */
export function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  let buffer = new ArrayBuffer(bytes.length);
  let view = new Uint8Array(buffer);
  view.set(bytes, 0);
  return buffer;
}

/** 计算 UTF-8 文本字节数（代理对按 4 字节计） */
export function utf8ByteLength(text: string): number {
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

/** 延时辅助（Promise 定时） */
export function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * 排空 Rust 日志缓冲并追加 MTA 相关行（解析 `level|message` 前缀，按原始级别展示）。
 * appendLog 为服务侧日志追加入口，onWarn 在轮询失败时上报。
 */
export function drainRustLog(appendLog: (source: string, message: string, level: string) => void,
  onWarn: (message: string) => void): void {
  try {
    let lines = nativePollDebugLogWithLevels();
    for (let i = 0; i < lines.length; i++) {
      let parsed = parseRustLogLine(lines[i]);
      if (parsed.message.includes('MTA')) {
        appendLog('Rust', parsed.message, parsed.level);
      }
    }
  } catch (e) {
    onWarn('轮询 Rust 日志失败: ' + String(e));
  }
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
