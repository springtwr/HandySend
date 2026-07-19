import { initAppService, getDeviceAlias, getServerFingerprint,
  isServerRunning, startLocalServer, stopLocalServer,
  getDiscoveredDevices, getPendingRequests, getActiveProgress,
  getLogs, subscribe, unsubscribe, respondToRequest,
  sendToDevice, prepareSendFiles, rescanDevices }
  from '../service/AppService';
import { DiscoveredDevice, PendingRequest, SendFileItem } from '../model/Types';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';

@Entry
@Component
struct Index {
  @State statusText: string = 'Initializing...'
  @State serverBtnText: string = 'Start Server'
  @State deviceCount: number = 0
  @State devices: Array<DiscoveredDevice> = []
  @State pendingCount: number = 0
  @State logText: string = ''
  @State scanBtnDisabled: boolean = true

  private dismissedSessions: Record<string, boolean> = {}
  private refreshCallback: () => void = () => {}

  aboutToAppear(): void {
    let context = getContext() as common.UIAbilityContext;
    initAppService(context);
    this.refreshCallback = () => {
      this.statusText = isServerRunning() ? 'Running: ' + getServerFingerprint().substring(0, 10) + '...' : 'Stopped';
      this.serverBtnText = isServerRunning() ? 'Stop Server' : 'Start Server';
      let newDevices = getDiscoveredDevices();
      this.devices = newDevices;
      this.deviceCount = newDevices.length;
      this.pendingCount = getPendingRequests().length;
      this.scanBtnDisabled = !isServerRunning();
      let allLogs = getLogs();
      let lines: Array<string> = [];
      let start = allLogs.length > 30 ? allLogs.length - 30 : 0;
      for (let i = start; i < allLogs.length; i++) {
        lines.push(allLogs[i].message);
      }
      this.logText = lines.join('\n');
      let requests = getPendingRequests();
      if (requests.length > 0) {
        let latest = requests[requests.length - 1];
        let alreadyShown = this.dismissedSessions[latest.sessionId];
        if (alreadyShown === undefined || !alreadyShown) {
          this.dismissedSessions[latest.sessionId] = true;
          setTimeout(() => {
            this.showReceiveDialog(latest);
          }, 100);
        }
      }
    };
    subscribe(this.refreshCallback);
    this.refreshCallback();
  }

  aboutToDisappear(): void {
    unsubscribe(this.refreshCallback);
  }

  build() {
    Column() {
      Text('LocalSend')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .margin(12)
      Button(this.serverBtnText)
        .width('90%')
        .margin(6)
        .onClick(() => {
          this.toggleServer();
        })
      Button('Scan')
        .width('90%')
        .margin(6)
        .enabled(!this.scanBtnDisabled)
        .onClick(() => {
          rescanDevices();
        })
      Text('Devices (' + this.deviceCount + ')')
        .fontSize(16)
        .margin({ top: 8, bottom: 4 })
      List() {
        ForEach(this.devices, (device: DiscoveredDevice) => {
          ListItem() {
            Column() {
              Text(device.alias)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
              Text(device.ip + ':' + device.port)
                .fontSize(12)
                .fontColor('#888888')
            }
            .padding(8)
            .width('100%')
          }
          .width('100%')
          .onClick(() => {
            this.sendToDevicePicked(device);
          })
        }, (device: DiscoveredDevice) => device.fingerprint)
      }
      .width('100%')
      .layoutWeight(1)
      .border({ width: 1, color: '#cccccc' })
      .margin(8)
      Text('Log')
        .fontSize(14)
        .margin({ top: 4, bottom: 2 })
      Text(this.logText)
        .fontSize(10)
        .fontColor('#666666')
        .width('100%')
        .height(80)
        .padding(4)
        .border({ width: 1, color: '#dddddd' })
        .margin(8)
    }
    .width('100%')
    .height('100%')
  }

  async toggleServer(): Promise<void> {
    try {
      if (isServerRunning()) {
        await stopLocalServer();
      } else {
        await startLocalServer();
      }
    } catch (e) {
      this.statusText = 'Error: ' + e;
    }
    this.refreshCallback();
  }

  async sendToDevicePicked(device: DiscoveredDevice): Promise<void> {
    let context = getContext() as common.UIAbilityContext;
    let documentPicker = new picker.DocumentViewPicker(context);
    let options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 10;
    let uris: Array<string> = [];
    try {
      uris = await documentPicker.select(options);
    } catch (_e) {
      return;
    }
    if (uris.length === 0) {
      return;
    }
    let items: Array<SendFileItem> = await prepareSendFiles(uris);
    if (items.length > 0) {
      await sendToDevice(device, items);
    }
  }

  showReceiveDialog(request: PendingRequest): void {
    let fileList = '';
    for (let i = 0; i < request.files.length; i++) {
      let f = request.files[i];
      fileList += '\n  ' + f.fileName + ' (' + f.size + ' bytes)';
    }
    AlertDialog.show({
      title: 'Transfer from ' + request.senderAlias,
      message: request.files.length + ' file(s):' + fileList,
      primaryButton: {
        value: 'Accept',
        action: () => {
          respondToRequest(request.sessionId, true);
        }
      },
      secondaryButton: {
        value: 'Decline',
        action: () => {
          respondToRequest(request.sessionId, false);
        }
      }
    });
  }
}
