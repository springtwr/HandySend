import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { router, curves } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getDiscoveredDevices, rescanDevices, subscribe, unsubscribe,
  prepareSendFiles, createShareLink,
  getShareLink, getLocalDeviceInfo, getDeviceType, getDeviceModel,
  isSendCompletedAndReset, processSharedUris,
  setSendMode, getSendMode, getSendSessions,
  getChecksumProgress, getChecksumTotal,
  sendToDeviceMulti, startServer, isServerRunning, clearAllSendSessions } from '../service/AppService';
import { DiscoveredDevice, SendFileItem, StagedFile, SendMode } from '../model/Types';
import { addFavoriteFromDiscovered, removeFavorite, isFavorite } from '../service/FavoritesService';
import { DialogService } from '../service/DialogService';
import { DesignTokens } from '../common/DesignTokens';
import { SendModeSelector } from './SendModeSelector';
import { getMimeForExt as mimeGetMimeForExt, isImageExtension } from '../utils/MimeUtils';

@Component
export struct SendContent {
  @State stagedFiles: Array<StagedFile> = []

  @State discoveredDevices: Array<DiscoveredDevice> = []
  @State refreshAngle: number = 0
  @StorageLink('hideShareByLink') hideShareByLink: boolean = false
  @StorageLink('favoriteDevices') favoriteDevicesJson: string = '[]'
  @StorageLink('serverReady') serverReady: boolean = false
  @StorageLink('enableAnimations') enableAnimations: boolean = true
  @StorageLink('sendMode') currentSendMode: string = 'single'
  @State isCreatingShareLink: boolean = false
  @State checksumProgress: number = 0
  @State checksumTotal: number = 0
  @State sendSessionStatuses: Record<string, string> = {}  // key=IP, value=latest status string
  @State cachedTotalSizeText: string = ''
  private refreshCallback: () => void = () => {}

  aboutToAppear(): void {
    this.refreshCallback = () => {
      if (isSendCompletedAndReset()) {
        if (this.currentSendMode === 'single') {
          this.clearStagedFiles();
        }
      }
      let pendingJson: string = AppStorage.get<string>('pendingSharedUris') ?? '';
      if (pendingJson.length > 0) {
        AppStorage.setOrCreate('pendingSharedUris', '');
        let sharedFiles: Array<StagedFile> = processSharedUris(pendingJson);
        if (sharedFiles.length > 0) {
          this.stagedFiles = sharedFiles;
          this.updateTotalSizeCache();
        }
      }
      this.discoveredDevices = getDiscoveredDevices();
      this.checksumProgress = getChecksumProgress();
      this.checksumTotal = getChecksumTotal();
      let sessions = getSendSessions();
      // Build IP-keyed status map (last session wins for each IP)
      let statuses: Record<string, string> = {};
      for (let i = 0; i < sessions.length; i++) {
        statuses[sessions[i].targetIp] = sessions[i].status as string;
      }
      this.sendSessionStatuses = statuses;
    };
    subscribe(this.refreshCallback);
    this.discoveredDevices = getDiscoveredDevices();
    let savedMode = getSendMode();
    this.currentSendMode = savedMode;
  }

  aboutToDisappear(): void {
    unsubscribe(this.refreshCallback);
  }

  async pickFiles(): Promise<void> {
    let context = getContext() as common.UIAbilityContext;
    let documentPicker = new picker.DocumentViewPicker(context);
    let options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 10;
    try {
      let uris: Array<string> = await documentPicker.select(options);
      for (let i = 0; i < uris.length; i++) {
        let uri = uris[i];
        let name = this.extractFileNameFromUri(uri);
        let ext = this.getExtension(name);
        let isImg = isImageExtension(ext);
        let mime = mimeGetMimeForExt(ext);
        let staged: StagedFile = { uri: uri, fileName: name, fileType: mime, isImage: isImg };
        this.stagedFiles.push(staged);
      }
    } catch (e) {
      console.error('pickFiles error:', JSON.stringify(e));
    }
    this.updateTotalSizeCache();
  }

  async pickImages(): Promise<void> {
    let context = getContext() as common.UIAbilityContext;
    let photoPicker = new picker.PhotoViewPicker(context);
    let options = new picker.PhotoSelectOptions();
    options.maxSelectNumber = 10;
    try {
      let result = await photoPicker.select(options);
      let uris: Array<string> = result.photoUris;
      for (let i = 0; i < uris.length; i++) {
        let uri = uris[i];
        let name = this.extractFileNameFromUri(uri);
        let ext = this.getExtension(name);
        let mime = mimeGetMimeForExt(ext);
        let staged: StagedFile = { uri: uri, fileName: name, fileType: mime, isImage: true };
        this.stagedFiles.push(staged);
      }
    } catch (e) {
      console.error('pickImages error:', JSON.stringify(e));
    }
    this.updateTotalSizeCache();
  }

  async pickAudio(): Promise<void> {
    let context = getContext() as common.UIAbilityContext;
    let audioPicker = new picker.AudioViewPicker(context);
    let options = new picker.AudioSelectOptions();
    try {
      let uris: Array<string> = await audioPicker.select(options);
      for (let i = 0; i < uris.length; i++) {
        let uri = uris[i];
        let name = this.extractFileNameFromUri(uri);
        let ext = this.getExtension(name);
        let mime = mimeGetMimeForExt(ext);
        let staged: StagedFile = { uri: uri, fileName: name, fileType: mime, isImage: false };
        this.stagedFiles.push(staged);
      }
    } catch (e) {
      console.error('pickAudio error:', JSON.stringify(e));
    }
    this.updateTotalSizeCache();
  }

  handlePasteData(text: string): void {
    try {
      if (text.length === 0) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.send_clipboard_empty'), duration: 2000 });
        return;
      }
      this.stageTextFile(text, 'clipboard_');
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.send_clipboard_pasted'), duration: 2000 });
    } catch (e) {
      hilog.error(0x0001, 'SendContent', 'handlePasteData error: %{public}s', JSON.stringify(e));
    }
  }

  pickJustify(): void {
    DialogService.showTextSendDialog((text: string) => {
      if (text.trim().length === 0) {
        return;
      }
      this.stageTextFile(text, 'text_');
    });
  }

  stageTextFile(text: string, prefix: string): void {
    let context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    let sendDir: string = context.filesDir + '/send/';
    try {
      fs.mkdirSync(sendDir);
    } catch (_e) {}
    let fileName: string = prefix + Date.now() + '.txt';
    let filePath: string = sendDir + fileName;
    let file: fs.File = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    fs.writeSync(file.fd, text);
    fs.closeSync(file);
    let staged: StagedFile = { uri: filePath, fileName: fileName, fileType: 'text/plain', isImage: false, isManualText: true };
    this.stagedFiles.push(staged);
    this.updateTotalSizeCache();
  }

  removeStagedFile(index: number): void {
    let updated: Array<StagedFile> = [];
    for (let i = 0; i < this.stagedFiles.length; i++) {
      if (i !== index) {
        updated.push(this.stagedFiles[i]);
      }
    }
    this.stagedFiles = updated;
    // When all files are removed, clear session statuses
    if (updated.length === 0) {
      clearAllSendSessions();
      this.sendSessionStatuses = {};
    }
    this.updateTotalSizeCache();
  }

  clearStagedFiles(): void {
    this.stagedFiles = [];
    clearAllSendSessions();
    this.sendSessionStatuses = {};
    this.cachedTotalSizeText = '';
  }

  updateTotalSizeCache(): void {
    let totalBytes: number = 0;
    for (let i = 0; i < this.stagedFiles.length; i++) {
      try {
        let stat = fs.statSync(this.stagedFiles[i].uri);
        totalBytes = totalBytes + stat.size;
      } catch (_e) {
      }
    }
    if (totalBytes === 0) {
      this.cachedTotalSizeText = '';
    } else if (totalBytes < 1024) {
      this.cachedTotalSizeText = totalBytes + ' B';
    } else if (totalBytes < 1024 * 1024) {
      this.cachedTotalSizeText = (totalBytes / 1024).toFixed(1) + ' KB';
    } else if (totalBytes < 1024 * 1024 * 1024) {
      this.cachedTotalSizeText = (totalBytes / 1024 / 1024).toFixed(1) + ' MB';
    } else {
      this.cachedTotalSizeText = (totalBytes / 1024 / 1024 / 1024).toFixed(1) + ' GB';
    }
  }

  getTotalSizeText(): string {
    return this.cachedTotalSizeText;
  }

  extractFileNameFromUri(uri: string): string {
    let decoded = decodeURIComponent(uri);
    let idx = decoded.lastIndexOf('/');
    if (idx >= 0 && idx < decoded.length - 1) {
      return decoded.substring(idx + 1);
    }
    return 'file_' + Date.now();
  }

  getExtension(fileName: string): string {
    let dot = fileName.lastIndexOf('.');
    if (dot >= 0 && dot < fileName.length - 1) {
      return fileName.substring(dot + 1).toLowerCase();
    }
    return '';
  }

  // T081: Refresh rotation uses springMotion
  refreshDevices(): void {
    this.getUIContext().animateTo({ duration: 800, curve: curves.springMotion(DesignTokens.animation.springStiffness, DesignTokens.animation.springDamping) }, () => {
      this.refreshAngle = this.refreshAngle + 360;
    });
    if (this.serverReady) {
      rescanDevices();
    }
  }

  async shareByLink(): Promise<void> {
    if (this.isCreatingShareLink) {
      return;
    }
    if (this.stagedFiles.length === 0) {
      await this.pickFiles();
    }
    if (this.stagedFiles.length === 0) {
      return;
    }
    this.isCreatingShareLink = true;
    try {
      let uris: Array<string> = [];
      for (let i = 0; i < this.stagedFiles.length; i++) {
        uris.push(this.stagedFiles[i].uri);
      }
      let items: Array<SendFileItem> = await prepareSendFiles(uris);
      if (items.length > 0) {
        await createShareLink(items);
        let shareUrl = getShareLink();
        if (shareUrl.length > 0) {
          router.pushUrl({ url: 'pages/ShareLinkPage', params: { shareUrl: shareUrl } });
        }
      }
    } finally {
      this.isCreatingShareLink = false;
    }
  }

  sendToSelectedDevice(device: DiscoveredDevice): void {
    if (this.stagedFiles.length === 0) {
      return;
    }
    // #15: Multiple send mode — inline send without TransferPage navigation
    if (this.currentSendMode === 'multiple') {
      this.sendToMultipleDeviceInline(device);
      return;
    }
    let uris: Array<string> = [];
    for (let i = 0; i < this.stagedFiles.length; i++) {
      uris.push(this.stagedFiles[i].uri);
    }
    let allManualText: boolean = true;
    let computedTotalSize: number = 0;
    for (let i = 0; i < this.stagedFiles.length; i++) {
      if (this.stagedFiles[i].isManualText !== true) {
        allManualText = false;
      }
      try {
        let stat = fs.statSync(this.stagedFiles[i].uri);
        computedTotalSize = computedTotalSize + stat.size;
      } catch (_e) {
      }
    }
    let localInfo = getLocalDeviceInfo();
    let params: Record<string, Object | string | number | boolean | Array<string>> = {
      'mode': 'send',
      'sourceAlias': localInfo.alias,
      'sourceIp': localInfo.ip,
      'sourceDeviceType': getDeviceType(),
      'sourceDeviceModel': getDeviceModel(),
      'targetAlias': device.alias,
      'targetIp': device.ip,
      'targetDeviceType': device.deviceType,
      'targetDeviceModel': device.deviceModel,
      'fileUris': uris,
      'targetPort': device.port,
      'targetFingerprint': device.fingerprint,
      'targetProtocol': device.protocol,
      'sessionId': '',
      'autoConfirm': false,
      'fileCount': this.stagedFiles.length,
      'totalSize': computedTotalSize,
      'isTextSend': allManualText,
      'sendMode': this.currentSendMode
    };
    router.pushUrl({ url: 'pages/TransferPage', params: params });
  }

  // #15: Inline send for multiple-target mode — no TransferPage, status shown on device card
  async sendToMultipleDeviceInline(device: DiscoveredDevice): Promise<void> {
    // Immediately show "waiting" status so user sees feedback
    let newStatuses: Record<string, string> = {};
    // Preserve existing statuses
    let keys = Object.keys(this.sendSessionStatuses);
    for (let i = 0; i < keys.length; i++) {
      newStatuses[keys[i]] = this.sendSessionStatuses[keys[i]];
    }
    newStatuses[device.ip] = 'waiting';
    this.sendSessionStatuses = newStatuses;

    let uris: Array<string> = [];
    for (let i = 0; i < this.stagedFiles.length; i++) {
      uris.push(this.stagedFiles[i].uri);
    }
    let items: Array<SendFileItem> = await prepareSendFiles(uris);
    if (items.length === 0) {
      // Remove the waiting status since send failed to prepare
      let clearedStatuses: Record<string, string> = {};
      let k = Object.keys(this.sendSessionStatuses);
      for (let i = 0; i < k.length; i++) {
        if (k[i] !== device.ip) {
          clearedStatuses[k[i]] = this.sendSessionStatuses[k[i]];
        }
      }
      this.sendSessionStatuses = clearedStatuses;
      return;
    }
    // Use sendToDeviceMulti with single device — it creates session + updates status
    await sendToDeviceMulti([device], items);
    // Don't clear staged files in multiple mode — user may send to more devices
  }

  async sendToMultipleDevices(): Promise<void> {
    if (this.stagedFiles.length === 0) {
      return;
    }
    if (this.discoveredDevices.length === 0) {
      return;
    }
    let uris: Array<string> = [];
    for (let i = 0; i < this.stagedFiles.length; i++) {
      uris.push(this.stagedFiles[i].uri);
    }
    let items: Array<SendFileItem> = await prepareSendFiles(uris);
    if (items.length === 0) {
      return;
    }
    await sendToDeviceMulti(this.discoveredDevices, items);
  }

  onSendModeChange(mode: string): void {
    this.currentSendMode = mode;
    setSendMode(mode as SendMode);
  }

  toggleFavorite(fingerprint: string): void {
    let device: DiscoveredDevice | null = null;
    for (let i = 0; i < this.discoveredDevices.length; i++) {
      if (this.discoveredDevices[i].fingerprint === fingerprint) {
        device = this.discoveredDevices[i];
        break;
      }
    }
    if (isFavorite(fingerprint)) {
      removeFavorite(fingerprint);
    } else if (device !== null) {
      addFavoriteFromDiscovered(device);
    }
    // favoriteDevicesJson is auto-updated via @StorageLink + notifyChange()
    // No need to manually set it here
  }

  // Reactive favorite check — reads @StorageLink('favoriteDevices') so UI re-renders on change
  isDeviceFavorite(fingerprint: string): boolean {
    try {
      let parsed: Object = JSON.parse(this.favoriteDevicesJson);
      if (Array.isArray(parsed)) {
        for (let i = 0; i < parsed.length; i++) {
          let item = parsed[i] as Record<string, Object>;
          if (item['fingerprint'] === fingerprint) {
            return true;
          }
        }
      }
    } catch (_e) {
      // fallback to service
      return isFavorite(fingerprint);
    }
    return false;
  }

  build() {
    Scroll() {
      Column() {
        // Server offline warning banner
        if (!this.serverReady) {
          Row() {
            Text($r('app.string.server_offline_warning'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.warning_orange'))
              .layoutWeight(1)

            Button($r('app.string.start_server'))
              .fontSize(DesignTokens.font.bodyS)
              .height(28)
              .fontColor($r('app.color.text_on_color'))
              .backgroundColor($r('app.color.accent_blue'))
              .borderRadius(DesignTokens.radius.max)
              .onClick(() => {
                 startServer().then(() => {
                   this.serverReady = isServerRunning();
                 }).catch((_e: Error) => {
                   // Start failed, stay offline
                 });
              })
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.warning_bg'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.warning_orange') })
          .margin({ top: DesignTokens.space.md })
        }

        Column() {
          if (this.stagedFiles.length === 0) {
            Text($r('app.string.send_select_title'))
              .fontSize(DesignTokens.font.titleS)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            Text($r('app.string.send_select_subtitle'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 6 })

            Scroll() {
              Row({ space: 10 }) {
                Column() {
                  SymbolGlyph($r('sys.symbol.doc_text_fill'))
                    .fontSize(20)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_file'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 20, bottom: 20 })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.pickFiles();
                })

                Column() {
                  SymbolGlyph($r('sys.symbol.picture_fill'))
                    .fontSize(20)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_image'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 20, bottom: 20 })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.pickImages();
                })

                Column() {
                  PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
                    .width(66)
                    .height(66)
                    .iconSize(20)
                    .fontSize(DesignTokens.font.bodyS)
                    .borderRadius(DesignTokens.radius.md)
                    .backgroundColor($r('app.color.page_background'))
                    .iconColor($r('app.color.clipboard_button_icon'))
                    .fontColor($r('app.color.clipboard_button_icon'))
                    .layoutDirection(SecurityComponentLayoutDirection.VERTICAL)
                    .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
                      if (PasteButtonOnClickResult.SUCCESS === result) {
                        let systemPasteboard = pasteboard.getSystemPasteboard();
                        systemPasteboard.getData().then((pasteData: pasteboard.PasteData) => {
                          this.handlePasteData(pasteData.getPrimaryText());
                        }).catch((err: BusinessError) => {
                          hilog.error(0x0001, 'SendContent', 'Paste error: %{public}s', err.message);
                          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.clipboard_read_failed'), duration: 2000 });
                        });
                      }
                    })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 7, bottom: 7 })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))

                Column() {
                  SymbolGlyph($r('sys.symbol.text_aligncenter'))
                    .fontSize(20)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_justify'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 20, bottom: 20 })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.pickJustify();
                })

                Column() {
                  SymbolGlyph($r('sys.symbol.music_fill'))
                    .fontSize(20)
                    .fontColor([$r('app.color.text_primary')])
                  Text($r('app.string.send_audio'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 20, bottom: 20 })
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.page_background'))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.pickAudio();
                })
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .edgeEffect(this.enableAnimations ? EdgeEffect.Spring : EdgeEffect.None)
            .width('100%')
            .margin({ top: DesignTokens.space.md })
          } else {
            Row() {
              Column() {
                Text($r('app.string.send_select_title'))
                  .fontSize(DesignTokens.font.titleS)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))

                Text($r('app.string.send_file_count_total', this.stagedFiles.length, this.getTotalSizeText()))
                  .fontSize(DesignTokens.font.bodyS)
                  .fontColor($r('app.color.text_secondary'))
                  .margin({ top: 6 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Row({ space: DesignTokens.space.sm }) {
                Text($r('app.string.send_add_files'))
                  .fontSize(DesignTokens.font.bodyS)
                  .fontColor($r('app.color.accent_blue'))
                  .onClick(() => {
                    this.pickFiles();
                  })

                // T028: Clear icon responseRegion→48vp
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(20)
                  .fontColor([$r('app.color.text_tertiary')])
                  .responseRegion({ x: -14, y: -14, width: 48, height: 48 })
                  .onClick(() => {
                    this.clearStagedFiles();
                  })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)

            Scroll() {
              Row({ space: 10 }) {
                // T060: Staged files ForEach — transition with scale
                ForEach(this.stagedFiles, (file: StagedFile, index: number) => {
                  Stack({ alignContent: Alignment.TopEnd }) {
                    Column() {
                      if (file.isImage) {
                        Image(file.uri)
                          .width(48)
                          .height(48)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(DesignTokens.radius.md)
                      } else {
                        Image($r('app.media.ic_public_file'))
                          .width(48)
                          .height(48)
                          .fillColor($r('app.color.text_primary'))
                      }
                      Text(file.fileName)
                        .fontSize(DesignTokens.font.captionM)
                        .fontColor($r('app.color.text_tertiary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width(64)
                        .textAlign(TextAlign.Center)
                        .margin({ top: 4 })
                    }
                    .width(64)
                    .height(80)
                    .alignItems(HorizontalAlign.Center)
                    .padding(4)

                    Text('\u00D7')
                      .fontSize(DesignTokens.font.bodyM)
                      .fontColor($r('app.color.text_on_color'))
                      .textAlign(TextAlign.Center)
                      .width(16)
                      .height(16)
                      .backgroundColor($r('app.color.danger_red'))
                      .borderRadius(DesignTokens.radius.md)
                      .onClick(() => {
                        this.removeStagedFile(index);
                      })
                  }
                  .width(64)
                  .height(80)
                  .transition(
                    TransitionEffect.OPACITY
                      .combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
                      .animation({ duration: 300, curve: Curve.FastOutSlowIn, delay: index * DesignTokens.animation.listAppearDelay })
                  )
                }, (file: StagedFile) => file.uri)
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .width('100%')
            .margin({ top: DesignTokens.space.md })
          }
        }
        .padding(20)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.lg })

        Column() {
          Row() {
            Column() {
              Text($r('app.string.nearby_devices_title'))
                .fontSize(DesignTokens.font.titleS)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))

              Text($r('app.string.nearby_devices_subtitle'))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 6 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            // T028: Refresh icon responseRegion→48vp
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(24)
              .fontColor([$r('app.color.text_primary')])
              .rotate({ angle: this.refreshAngle })
              .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
              .onClick(() => {
                this.refreshDevices();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.stagedFiles.length > 0) {
            Row() {
              SendModeSelector({
                onModeChange: (mode: string) => {
                  this.currentSendMode = mode;
                  setSendMode(mode as SendMode);
                }
              })
            }
            .width('100%')
            .margin({ top: DesignTokens.space.sm })
          }

          if (this.checksumTotal > 0 && this.checksumProgress < this.checksumTotal) {
            Column() {
              Text($r('app.string.calculating_checksum'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .width('100%')

              Row() {
                Progress({ value: this.checksumProgress, total: this.checksumTotal, type: ProgressType.Linear })
                  .width('70%')
                  .color($r('app.color.accent_blue'))

                Text(this.checksumProgress + '/' + this.checksumTotal)
                  .fontSize(DesignTokens.font.bodyS)
                  .fontColor($r('app.color.text_secondary'))
                  .margin({ left: DesignTokens.space.xs })
              }
              .width('100%')
              .margin({ top: DesignTokens.space.xs })
            }
            .width('100%')
            .padding(DesignTokens.space.sm)
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.md)
            .margin({ top: DesignTokens.space.sm })
          }

          if (!this.hideShareByLink && this.stagedFiles.length > 0) {
            Row({ space: DesignTokens.space.xs }) {
              if (this.isCreatingShareLink) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color($r('app.color.text_secondary'))
              }
              Text(this.isCreatingShareLink ? $r('app.string.creating_share_link') : $r('app.string.share_via_link'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor(this.isCreatingShareLink ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding(DesignTokens.space.sm)
            .backgroundColor(this.isCreatingShareLink ? $r('app.color.border_light') : $r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.md)
            .margin({ top: DesignTokens.space.sm })
            .onClick(() => {
              this.shareByLink();
            })
          }


          // T059: Nearby devices ForEach — transition with translate
          Column({ space: 10 }) {
            ForEach(this.discoveredDevices, (device: DiscoveredDevice, index: number) => {
              Row({ space: DesignTokens.space.sm }) {
                if (device.deviceType === 'mobile') {
                  Image($r('app.media.ic_public_devices_phone'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'desktop') {
                  Image($r('app.media.ic_device_matebook'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'web') {
                  Image($r('app.media.ic_browser'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'headless') {
                  Image($r('app.media.ic_terminal'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'server') {
                  Image($r('app.media.ic_server'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else if (device.deviceType === 'tablet') {
                  Image($r('app.media.ic_device_pad'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                } else {
                  Image($r('app.media.ic_public_devices_phone'))
                    .width(40).height(40)
                    .fillColor($r('app.color.text_primary'))
                }

                Column() {
                  Text(device.alias)
                    .fontSize(DesignTokens.font.subtitleM)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))

                  Row({ space: DesignTokens.space.xs }) {
                    Text('#' + device.ip.split('.').pop())
                      .fontSize(DesignTokens.font.bodyS)
                      .fontColor($r('app.color.ip_blue_text'))
                      .backgroundColor($r('app.color.accent_blue_bg'))
                      .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
                      .borderRadius(DesignTokens.radius.sm)

                    Text(device.deviceModel)
                      .fontSize(DesignTokens.font.bodyS)
                      .fontColor($r('app.color.ip_blue_text'))
                      .backgroundColor($r('app.color.accent_blue_bg'))
                      .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
                      .borderRadius(DesignTokens.radius.sm)
                  }
                  .margin({ top: 6 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.currentSendMode === 'multiple' && this.getDeviceSendStatus(device.ip) !== '') {
                  Text(this.getDeviceSendStatus(device.ip))
                    .fontSize(DesignTokens.font.captionM)
                    .fontColor(this.getDeviceStatusColor(device.ip))
                    .backgroundColor(this.getDeviceStatusBgColor(device.ip))
                    .padding({ left: 6, right: 6, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
                    .borderRadius(DesignTokens.radius.sm)
                }

                // T028: Heart icon
                SymbolGlyph(this.isDeviceFavorite(device.fingerprint) ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
                  .fontSize(22)
                  .fontColor([this.isDeviceFavorite(device.fingerprint) ? $r('app.color.danger_red') : $r('app.color.text_secondary')])
                  .responseRegion({ x: -13, y: -13, width: 48, height: 48 })
                  .onClick(() => {
                    this.toggleFavorite(device.fingerprint);
                  })

                // T028: Info button responseRegion→48vp
                SymbolGlyph($r('sys.symbol.info_circle'))
                  .fontSize(22)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ left: 4 })
                  .responseRegion({ x: -8, y: -8, width: 48, height: 48 })
                  .onClick(() => {
                    router.pushUrl({
                      url: 'pages/DeviceDetailsPage',
                      params: {
                        alias: device.alias,
                        ip: device.ip,
                        port: device.port,
                        fingerprint: device.fingerprint,
                        version: device.version,
                        deviceModel: device.deviceModel,
                        deviceType: device.deviceType,
                        protocol: device.protocol
                      }
                    });
                  })
              }
              .width('100%')
              .padding(DesignTokens.space.md)
              .backgroundColor($r('app.color.page_background'))
              .borderRadius(DesignTokens.radius.md)
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.sendToSelectedDevice(device);
              })
              .gesture(
                LongPressGesture({ repeat: false })
                  .onAction(() => {
                    if (this.isDeviceFavorite(device.fingerprint)) {
                      DialogService.showFavoriteDeleteDialog(device, () => {
                        removeFavorite(device.fingerprint);
                        // @StorageLink auto-syncs via notifyChange()
                      });
                    } else {
                      DialogService.showFavoriteEditDialog(device, (newAlias: string) => {
                        addFavoriteFromDiscovered(device, newAlias);
                        // @StorageLink auto-syncs via notifyChange()
                      });
                    }
                  })
              )
              .transition(
                TransitionEffect.OPACITY
                  .combine(TransitionEffect.translate({ x: 40 }))
                  .animation({ duration: 300, curve: Curve.FastOutSlowIn, delay: index * DesignTokens.animation.listAppearDelay })
              )
            }, (device: DiscoveredDevice) => device.fingerprint)
          }
          .width('100%')
          .margin({ top: DesignTokens.space.md })
        }
        .padding(20)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.md })

        Row() {
          Text($r('app.string.troubleshoot_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.accent_blue'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: DesignTokens.space.md, bottom: DesignTokens.space.md })
        .onClick(() => {
          router.pushUrl({ url: 'pages/TroubleshootPage' });
        })
      }
      .width('100%')
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
  }

  getDeviceSendStatus(ip: string): string {
    let status = this.sendSessionStatuses[ip];
    if (status === undefined || status === '') {
      return '';
    }
    // Return localized status label
    if (status === 'waiting') {
      return getContext(this).resourceManager.getStringSync($r('app.string.session_status_waiting').id);
    } else if (status === 'calculatingHash') {
      return getContext(this).resourceManager.getStringSync($r('app.string.session_status_checksum').id);
    } else if (status === 'sending') {
      return getContext(this).resourceManager.getStringSync($r('app.string.session_status_sending').id);
    } else if (status === 'finished') {
      return getContext(this).resourceManager.getStringSync($r('app.string.session_status_done').id);
    } else if (status === 'finishedWithErrors') {
      return getContext(this).resourceManager.getStringSync($r('app.string.session_status_error').id);
    } else if (status === 'declined') {
      return getContext(this).resourceManager.getStringSync($r('app.string.session_status_declined').id);
    } else if (status === 'canceled' || status === 'canceledByReceiver') {
      return getContext(this).resourceManager.getStringSync($r('app.string.session_status_canceled').id);
    } else if (status === 'tooManyAttempts') {
      return getContext(this).resourceManager.getStringSync($r('app.string.session_status_locked').id);
    }
    return status;
  }

  getDeviceStatusColor(ip: string): ResourceColor {
    let status = this.sendSessionStatuses[ip];
    if (status === undefined || status === '') {
      return $r('app.color.text_tertiary');
    }
    if (status === 'sending') {
      return $r('app.color.accent_blue');
    } else if (status === 'finished') {
      return $r('app.color.success_green');
    } else if (status === 'finishedWithErrors') {
      return $r('app.color.warning_orange');
    } else if (status === 'declined' || status === 'canceled' || status === 'canceledByReceiver') {
      return $r('app.color.danger_red');
    } else if (status === 'waiting' || status === 'calculatingHash') {
      return $r('app.color.text_secondary');
    } else if (status === 'tooManyAttempts') {
      return $r('app.color.danger_red');
    }
    return $r('app.color.text_tertiary');
  }

  getDeviceStatusBgColor(ip: string): ResourceColor {
    let status = this.sendSessionStatuses[ip];
    if (status === undefined || status === '') {
      return $r('app.color.page_background');
    }
    if (status === 'sending') {
      return $r('app.color.accent_blue_bg');
    } else if (status === 'finished') {
      return $r('app.color.success_bg');
    } else if (status === 'finishedWithErrors') {
      return $r('app.color.warning_bg');
    } else if (status === 'declined' || status === 'canceled' || status === 'canceledByReceiver' || status === 'tooManyAttempts') {
      return $r('app.color.danger_bg');
    }
    return $r('app.color.page_background');
  }
}
