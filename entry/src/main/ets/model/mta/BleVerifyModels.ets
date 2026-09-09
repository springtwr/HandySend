/**
 * BleVerifyModels.ets — MTA BLE 验证页数据类型与纯函数
 *
 * 本文件仅包含数据视图类型与可单测的纯函数（无系统 API 依赖），
 * 供 BleVerifyService / MtaBleVerifyViewModel / MtaBleVerifyPage 共用。
 */

/** 扫描到的 MTA 设备（由广播 serviceData 解析出的视图投影） */
export class ScannedMtaDeviceView {
  /** 设备标识（虚拟 MAC，可用于 createGattClientDevice） */
  deviceId: string = '';
  /** 设备名（扫描响应 serviceData 解析，已去除 \t 填充） */
  deviceName: string = '';
  /** 发送者 ID（2 字节十六进制） */
  senderIdHex: string = '';
  /** 品牌名（由品牌 ID 映射） */
  brandName: string = '';
  /** 是否支持 5GHz（由 serviceData UUID 字节解析） */
  is5Ghz: boolean = false;
  /** 信号强度（dBm） */
  rssi: number = 0;
  /** 最近发现时间（HH:mm:ss.SSS） */
  foundTimeText: string = '';
}

/** GATT Client 连接状态视图 */
export class GattClientStateView {
  /** 目标设备标识 */
  targetDeviceId: string = '';
  /** 连接状态文本（未连接/连接中/已连接/断开） */
  connectionStateText: string = '未连接';
  /** 最近读取到的 DeviceInfo 文本 */
  deviceInfoText: string = '';
}

/** 验证日志条目 */
export class VerifyLogEntry {
  /** 时间戳（HH:mm:ss.SSS） */
  timeText: string = '';
  /** 来源标签（蓝牙/广播/GATT Server/GATT Client/扫描/权限） */
  source: string = '';
  /** 级别：'info' / 'error' */
  level: string = 'info';
  /** 内容 */
  content: string = '';
}

/** Service → ViewModel 事件回调集合，由 ViewModel 注入处理函数 */
export class BleEventHandlers {
  /** 蓝牙开关状态变化 */
  onBluetoothStateChange: (stateText: string) => void = (stateText: string): void => {
  };
  /** 广播状态变化 */
  onAdvertiseStateChange: (running: boolean, detail: string) => void = (running: boolean, detail: string): void => {
  };
  /** GATT Server 客户端连接状态变化 */
  onGattConnectionChange: (clientDeviceId: string, stateText: string) => void =
    (clientDeviceId: string, stateText: string): void => {
    };
  /** GATT Server 收到读请求 */
  onGattReadRequest: (clientDeviceId: string, offset: number) => void =
    (clientDeviceId: string, offset: number): void => {
    };
  /** GATT Server 写进度（prepared write 分片） */
  onGattWriteProgress: (deviceId: string, offset: number, totalLength: number, isPrepared: boolean) => void =
    (deviceId: string, offset: number, totalLength: number, isPrepared: boolean): void => {
    };
  /** GATT Server 收到完整写入 */
  onGattWriteComplete: (deviceId: string, payloadText: string) => void =
    (deviceId: string, payloadText: string): void => {
    };
  /** 扫描发现 MTA 设备 */
  onDeviceFound: (device: ScannedMtaDeviceView) => void = (device: ScannedMtaDeviceView): void => {
  };
  /** GATT Client 连接状态变化 */
  onGattClientConnectionChange: (stateText: string) => void = (stateText: string): void => {
  };
  /** GATT Client 读取到对端 DeviceInfo */
  onGattClientDeviceInfo: (deviceInfoText: string) => void = (deviceInfoText: string): void => {
  };
  /** 错误上报 */
  onError: (source: string, message: string) => void = (source: string, message: string): void => {
  };
}

// ── 时间格式化 ──

/** 将 Date 格式化为 HH:mm:ss.SSS（不足两位补零） */
export function formatTimeText(date: Date): string {
  let hh = pad2(date.getHours());
  let mm = pad2(date.getMinutes());
  let ss = pad2(date.getSeconds());
  let ms = pad3(date.getMilliseconds());
  return `${hh}:${mm}:${ss}.${ms}`;
}

function pad2(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}

function pad3(n: number): string {
  if (n < 10) {
    return '00' + n.toString();
  }
  if (n < 100) {
    return '0' + n.toString();
  }
  return n.toString();
}
