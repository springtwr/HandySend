import { initAppService, getDeviceAlias, getServerFingerprint,
  isServerRunning, startLocalServer, stopLocalServer,
  getDiscoveredDevices, getPendingRequests, getActiveProgress,
  getLogs, subscribe, unsubscribe, respondToRequest,
  sendToDevice, prepareSendFiles, rescanDevices,
  setHttpsEnabled, getHttpsEnabled,
  createShareLink, stopShareLink, getShareLink, getSharePort }
  from '../service/AppService';
import { DiscoveredDevice, PendingRequest, SendFileItem, TransferProgress } from '../model/Types';
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
  @State httpsOn: boolean = true
  @State transfers: Array<TransferProgress> = []
  @State shareUrl: string = ''
  @State sharePortNum: number = 0

  private dismissedSessions: Record<string, boolean> = {}
  private refreshCallback: () => void = () => {}

  aboutToAppear(): void {
    let context = getContext() as common.UIAbilityContext;
    initAppService(context);
    this.httpsOn = getHttpsEnabled();
    this.refreshCallback = () => {
      this.statusText = isServerRunning() ? 'Running: ' + getServerFingerprint().substring(0, 10) + '...' : 'Stopped';
      this.serverBtnText = isServerRunning() ? 'Stop Server' : 'Start Server';
      this.httpsOn = getHttpsEnabled();
      this.transfers = getActiveProgress();
      this.shareUrl = getShareLink();
      this.sharePortNum = getSharePort();
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
      Row() {
        Text('Encrypted Transfer')
          .fontSize(14)
        Toggle({ type: ToggleType.Switch, isOn: this.httpsOn })
          .onChange((isOn: boolean) => {
            setHttpsEnabled(isOn);
            this.httpsOn = isOn;
          })
      }
      .width('90%')
      .justifyContent(FlexAlign.SpaceBetween)
      .padding(6)
      Button('Share Files')
        .width('90%')
        .margin(6)
        .onClick(() => {
          this.shareFilesViaLink();
        })
      if (this.shareUrl.length > 0) {
        Text('Share Link')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 6 })
        QRCode(this.shareUrl)
          .width(160)
          .height(160)
          .margin(6)
        Text(this.shareUrl)
          .fontSize(12)
          .fontColor($r('app.color.purple_text'))
          .width('90%')
        Button('Stop Share')
          .width('90%')
          .margin(6)
          .onClick(() => {
            stopShareLink();
          })
      }
      if (this.transfers.length > 0) {
        ForEach(this.transfers, (p: TransferProgress) => {
          Text((p.sessionId.startsWith('share-') ? '📥 ' : '📤 ') +
            p.fileId.substring(0, 8) + '... ' +
            (p.bytesSent * 100 / (p.totalBytes > 0 ? p.totalBytes : 1)).toFixed(0) + '%')
            .fontSize(12)
            .fontColor($r('app.color.success_green'))
            .width('90%')
        }, (p: TransferProgress) => p.fileId + p.bytesSent)
      }
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
                .fontColor($r('app.color.text_secondary'))
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
      .border({ width: 1, color: $r('app.color.border_medium') })
      .margin(8)
      Text('Log')
        .fontSize(14)
        .margin({ top: 4, bottom: 2 })
      Text(this.logText)
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .height(80)
        .padding(4)
        .border({ width: 1, color: $r('app.color.border_light') })
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

  async shareFilesViaLink(): Promise<void> {
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
      await createShareLink(items);
    }
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
    if (items.length === 0) {
      return;
    }
    AlertDialog.show({
      title: 'Send to ' + device.alias,
      message: items.length + ' file(s) selected',
      primaryButton: {
        value: 'Send Direct',
        action: async () => {
          let result = await sendToDevice(device, items);
          if (!result.success) {
            AlertDialog.show({
              title: $r('app.string.send_failed_title'),
              message: result.error || $r('app.string.unknown_error'),
              primaryButton: { value: $r('app.string.dialog_confirm'), action: () => {} }
            });
          }
        }
      },
      secondaryButton: {
        value: $r('app.string.share_via_link'),
        action: () => {
          createShareLink(items);
        }
      }
    });
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
