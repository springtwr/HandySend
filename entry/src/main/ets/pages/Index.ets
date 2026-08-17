import { initAppService,
  getServerFingerprint,
  isServerRunning, startLocalServer, stopLocalServer,
  getDiscoveredDevices, getPendingRequests, getActiveProgress,
  getLogs, subscribe, unsubscribe, respondToRequest,
  sendToDevice, prepareSendFiles, rescanDevices,
  setHttpsEnabled, getHttpsEnabled,
  createShareLink, stopShareLink, getShareLink, getSharePort }
  from '../service/AppService';
import { DiscoveredDevice, PendingRequest, PendingRequestFile, SendFileItem, TransferProgress } from '../model/Types';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { PromptAction } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';

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
  @State currentRequest: PendingRequest | undefined = undefined

  private dismissedSessions: Record<string, boolean> = {}
  private pageActive: boolean = true
  private refreshCallback: () => void = () => {}
  private promptAction: PromptAction | undefined = undefined
  private receiveDialogId: number = -1

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
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
            if (this.pageActive) {
              this.showReceiveDialog(latest);
            }
          }, 100);
        }
      }
    };
    subscribe(this.refreshCallback);
    this.refreshCallback();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    unsubscribe(this.refreshCallback);
  }

  build() {
    Column() {
      Text('LocalSend')
        .fontSize(DesignTokens.font.titleM)
        .fontWeight(FontWeight.Bold)
        .margin(DesignTokens.space.sm)
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
          .fontSize(DesignTokens.font.bodyM)
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
          .fontSize(DesignTokens.font.bodyM)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 6 })
        QRCode(this.shareUrl)
          .width(160)
          .height(160)
          .margin(6)
        Text(this.shareUrl)
          .fontSize(DesignTokens.font.bodyS)
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
          Text((p.sessionId.startsWith('share-') ? '\uD83D\uDCE5 ' : '\uD83D\uDCE4 ') +
            p.fileId.substring(0, 8) + '... ' +
            (p.bytesSent * 100 / (p.totalBytes > 0 ? p.totalBytes : 1)).toFixed(0) + '%')
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.success_green'))
            .width('90%')
        }, (p: TransferProgress) => p.fileId + p.bytesSent)
      }
      Text('Devices (' + this.deviceCount + ')')
        .fontSize(DesignTokens.font.subtitleM)
        .margin({ top: DesignTokens.space.xs, bottom: DesignTokens.space.mini })
      List() {
        ForEach(this.devices, (device: DiscoveredDevice) => {
          ListItem() {
            Column() {
              Text(device.alias)
                .fontSize(DesignTokens.font.subtitleM)
                .fontWeight(FontWeight.Medium)
              Text(device.ip + ':' + device.port)
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
            }
            .padding(DesignTokens.space.xs)
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
      .margin(DesignTokens.space.xs)
      Text('Log')
        .fontSize(DesignTokens.font.bodyM)
        .margin({ top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
      Text(this.logText)
        .fontSize(DesignTokens.font.captionM)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .height(80)
        .padding(4)
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin(DesignTokens.space.xs)
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
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
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
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
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
    this.getUIContext().showAlertDialog({
      title: 'Send to ' + device.alias,
      message: items.length + ' file(s) selected',
      primaryButton: {
        value: 'Send Direct',
        action: async () => {
          let result = await sendToDevice(device, items);
          if (!result.success) {
            this.getUIContext().showAlertDialog({
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

  @Builder
  receiveConfirmDialog() {
    Column() {
      // Title
      Text($r('app.string.receive_confirm_title'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: DesignTokens.space.md })

      // Sender info
      if (this.currentRequest !== undefined) {
        Row({ space: DesignTokens.space.sm }) {
          Text($r('app.string.receive_from_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
          Text(this.currentRequest.senderAlias)
            .fontSize(DesignTokens.font.bodyM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ bottom: DesignTokens.space.xs })

        // File count
        Row({ space: DesignTokens.space.sm }) {
          Text($r('app.string.receive_file_count'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
          Text(String(this.currentRequest.files.length))
            .fontSize(DesignTokens.font.bodyM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
        }
        .width('100%')
        .margin({ bottom: DesignTokens.space.sm })

        // File list (scrollable, max 3 shown)
        Column() {
          ForEach(this.currentRequest.files, (file: PendingRequestFile, index: number) => {
            if (index < 3) {
              Text(file.fileName)
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
          }, (file: PendingRequestFile, index: number) => index.toString())
          if (this.currentRequest.files.length > 3) {
            Text('...' + (this.currentRequest.files.length - 3) + ' more')
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
        }
        .width('100%')
        .padding(DesignTokens.space.sm)
        .backgroundColor($r('app.color.page_background'))
        .borderRadius(DesignTokens.radius.md)
        .margin({ bottom: DesignTokens.space.md })
      }

      // Action buttons row
      Row({ space: DesignTokens.space.sm }) {
        // Decline button
        Button($r('app.string.decline_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.page_background'))
          .border({ width: 1, color: $r('app.color.border_light') })
          .borderRadius(DesignTokens.radius.md)
          .layoutWeight(1)
          .onClick(() => {
            if (this.currentRequest !== undefined) {
              respondToRequest(this.currentRequest.sessionId, false);
            }
            this.closeReceiveDialog();
          })

        // Accept button
        Button($r('app.string.accept_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_on_color'))
          .backgroundColor($r('app.color.accent_blue'))
          .borderRadius(DesignTokens.radius.md)
          .layoutWeight(1)
          .onClick(() => {
            if (this.currentRequest !== undefined) {
              let allFileIds: Array<string> = [];
              for (let i = 0; i < this.currentRequest.files.length; i++) {
                allFileIds.push(this.currentRequest.files[i].fileId);
              }
              respondToRequest(this.currentRequest.sessionId, true, allFileIds);
            }
            this.closeReceiveDialog();
          })
      }
      .width('100%')
      .margin({ bottom: DesignTokens.space.sm })

      // Verify button (only enabled for HTTPS sender)
      if (this.currentRequest !== undefined && this.currentRequest.senderProtocol === 'https') {
        Button($r('app.string.verify_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.accent_blue'))
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: $r('app.color.accent_blue') })
          .borderRadius(DesignTokens.radius.md)
          .width('100%')
          .onClick(() => {
            let localFp: string = getServerFingerprint();
            let remoteFp: string = this.currentRequest !== undefined ? this.currentRequest.senderFingerprint : '';
            this.closeReceiveDialog();
            this.getUIContext().getRouter().pushUrl({
              url: 'pages/VerifyPage',
              params: {
                localFingerprint: localFp,
                remoteFingerprint: remoteFp
              }
            });
          })
      } else {
        // Disabled verify button for HTTP sender
        Button($r('app.string.verify_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_tertiary'))
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: $r('app.color.border_light') })
          .borderRadius(DesignTokens.radius.md)
          .width('100%')
          .enabled(false)
          .accessibilityText($r('app.string.verify_button_disabled_hint'))
      }
    }
    .padding(DesignTokens.space.lg)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
  }

  showReceiveDialog(request: PendingRequest): void {
    this.currentRequest = request;
    if (this.promptAction === undefined) {
      this.promptAction = this.getUIContext().getPromptAction();
    }
    this.promptAction.openCustomDialog({
      builder: () => {
        this.receiveConfirmDialog();
      },
      autoCancel: true,
      maskColor: 0x33000000,
      alignment: DialogAlignment.Center
    }).then((dialogId: number) => {
      this.receiveDialogId = dialogId;
    });
  }

  closeReceiveDialog(): void {
    if (this.promptAction !== undefined && this.receiveDialogId >= 0) {
      this.promptAction.closeCustomDialog(this.receiveDialogId);
      this.receiveDialogId = -1;
    }
  }
}
