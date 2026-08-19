import { rescanDevices, getDiscoveredDevices } from '../service/AppService';

// Discovery-debug business state + commands, extracted from DiscoveryDebugPage.
// Owns the announce action (service call) + derived debug log / device count.
@ObservedV2
export class DiscoveryDebugViewModel {
  @Trace public discoveryLog: Array<string> = []
  @Trace public discoveredCount: number = 0

  loadInitial(): void {
    let devices = getDiscoveredDevices();
    this.discoveredCount = devices.length;
  }

  // Triggers a manual announce, refreshes the device count and appends a log entry.
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
