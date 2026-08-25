import { rescanDevices, getDiscoveredDevices, getMulticastError, isScanningStatus } from '../service/AppService';
import { subscribe, unsubscribe } from '../service/repository/AppCore';
import {
  subscribeDeviceResponses,
  unsubscribeDeviceResponses,
  DeviceResponseInfo
} from '../service/repository/DiscoveryRepository';

// 调试日志上限，防止对端频繁回应导致无限增长
const MAX_DEBUG_LOG_LINES = 200;

// 发现调试业务状态 + 命令，从 DiscoveryDebugPage 抽出。
// 持有广播动作（服务调用）+ 派生的调试日志 / 设备数量 / 组播错误 / 扫描状态。
// 通过订阅 AppCore.notifyChange 实时刷新，不再依赖同步读取。
@ObservedV2
export class DiscoveryDebugViewModel {
  @Trace public discoveryLog: Array<string> = []
  @Trace public discoveredCount: number = 0
  @Trace public multicastError: string = ''
  @Trace public isScanning: boolean = false
  private refreshCallback: () => void = () => {
  }
  private deviceResponseCallback: (info: DeviceResponseInfo) => void = (info: DeviceResponseInfo): void => {
  }

  loadInitial(): void {
    this.refresh();
    // 订阅 AppCore 事件总线，任何 notifyChange 都会触发刷新
    this.refreshCallback = (): void => {
      this.refresh();
    };
    subscribe(this.refreshCallback);

    // 订阅对端设备响应（device_found），每次回应追加一条日志
    this.deviceResponseCallback = (info: DeviceResponseInfo): void => {
      let timestamp = new Date().toLocaleTimeString();
      let kind = info.isNew ? 'new' : 'known';
      this.discoveryLog.push(timestamp + ' Response: ' + info.alias +
        ' (' + info.ip + ':' + info.port + ' ' + info.protocol + ') [' + kind + ']');
      if (this.discoveryLog.length > MAX_DEBUG_LOG_LINES) {
        this.discoveryLog.shift();
      }
    };
    subscribeDeviceResponses(this.deviceResponseCallback);
  }

  // 页面退出时取消订阅，防止泄漏
  destroy(): void {
    unsubscribe(this.refreshCallback);
    unsubscribeDeviceResponses(this.deviceResponseCallback);
  }

  // 从 AppService 拉取最新状态
  private refresh(): void {
    let devices = getDiscoveredDevices();
    this.discoveredCount = devices.length;
    this.multicastError = getMulticastError();
    this.isScanning = isScanningStatus();
  }

  // 触发一次手动广播并追加日志
  triggerAnnounce(): void {
    let before = this.discoveredCount;
    rescanDevices();
    let timestamp = new Date().toLocaleTimeString();
    let err = getMulticastError();
    if (err.length > 0) {
      this.discoveryLog.push(timestamp + ' Announce skipped: multicast error (' + err + ')');
    } else {
      this.discoveryLog.push(timestamp + ' Announce triggered (devices before: ' + before + ')');
    }
    // 刷新状态（扫描是异步的，设备数量会通过后续 notifyChange 回调更新）
    this.refresh();
  }

  clearLogs(): void {
    this.discoveryLog = [];
  }
}
