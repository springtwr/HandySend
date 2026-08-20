import { rescanDevices, getDiscoveredDevices } from '../service/AppService';

// 发现调试业务状态 + 命令，从 DiscoveryDebugPage 抽出。
// 持有广播动作（服务调用）+ 派生的调试日志 / 设备数量。
@ObservedV2
export class DiscoveryDebugViewModel {
  @Trace public discoveryLog: Array<string> = []
  @Trace public discoveredCount: number = 0

  loadInitial(): void {
    let devices = getDiscoveredDevices();
    this.discoveredCount = devices.length;
  }

  // 触发一次手动广播，刷新设备数量并追加一条日志。
  triggerAnnounce(): void {
    rescanDevices();
    let devices = getDiscoveredDevices();
    this.discoveredCount = devices.length;
    this.discoveryLog.push(new Date().toLocaleTimeString() + ' Manual announce triggered');
  }

  clearLogs(): void {
    this.discoveryLog = [];
  }
}
