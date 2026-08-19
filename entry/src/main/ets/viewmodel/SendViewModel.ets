import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { getDiscoveredDevices, rescanDevices, prepareSendFiles, createShareLink,
  getShareLink, getLocalDeviceInfo, getDeviceType, getDeviceModel,
  isSendCompletedAndReset, processSharedUris,
  setSendMode, getSendMode, getSendSessions,
  getChecksumProgress, getChecksumTotal,
  getHideShareByLink, isServerRunning, doesServerNeedRestart, isEnableAnimations,
  consumePendingSharedUris,
  sendToDeviceMulti, startServer, restartServer, clearAllSendSessions } from '../service/AppService';
import { DiscoveredDevice, SendFileItem, StagedFile, SendMode, FavoriteDevice } from '../model/Types';
import { addFavoriteFromDiscovered, removeFavorite, isFavorite, getFavorites as getFavoritesService,
  subscribeFavorites, unsubscribeFavorites } from '../service/FavoritesService';
import { getMimeForExt as mimeGetMimeForExt, isImageExtension } from '../utils/MimeUtils';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendViewModel');

// Send-tab business state + commands, extracted from SendContent.
// Owns server-state mirrors + favorites snapshot for reactive rendering without AppStorage.
@ObservedV2
export class SendViewModel {
  @Trace public stagedFiles: Array<StagedFile> = []
  @Trace public discoveredDevices: Array<DiscoveredDevice> = []
  @Trace public checksumProgress: number = 0
  @Trace public checksumTotal: number = 0
  @Trace public sendSessionStatuses: Record<string, string> = {} // key=IP, value=latest status string
  @Trace public cachedTotalSizeText: string = ''
  @Trace public isCreatingShareLink: boolean = false
  // Server-state + settings mirrors
  @Trace public hideShareByLink: boolean = false
  @Trace public serverReady: boolean = false
  @Trace public serverNeedsRestart: boolean = false
  @Trace public enableAnimations: boolean = true
  @Trace public sendMode: string = 'single'
  @Trace public favoriteDevices: Array<FavoriteDevice> = []
  private context: common.UIAbilityContext | undefined = undefined
  private favoritesCallback: () => void = () => {}

  init(context: common.UIAbilityContext): void {
    this.context = context;
    this.sendMode = getSendMode() as string;
  }

  // Subscribes to favorite-device changes (called from the view's aboutToAppear).
  subscribeFavorites(): void {
    this.favoritesCallback = () => {
      this.favoriteDevices = getFavoritesService().slice();
    };
    subscribeFavorites(this.favoritesCallback);
  }

  // Unsubscribes favorite-device changes (called from the view's aboutToDisappear).
  unsubscribeFavorites(): void {
    unsubscribeFavorites(this.favoritesCallback);
  }

  refresh(): void {
    if (isSendCompletedAndReset()) {
      if (this.sendMode === 'single') {
        this.clearStagedFiles();
      }
    }
    let pendingJson: string = consumePendingSharedUris();
    if (pendingJson.length > 0) {
      let sharedFiles: Array<StagedFile> = processSharedUris(pendingJson);
      if (sharedFiles.length > 0) {
        this.stagedFiles = sharedFiles;
        this.updateTotalSizeCache();
      }
    }
    this.discoveredDevices = getDiscoveredDevices();
    this.checksumProgress = getChecksumProgress();
    this.checksumTotal = getChecksumTotal();
    this.hideShareByLink = getHideShareByLink();
    this.serverReady = isServerRunning();
    this.serverNeedsRestart = doesServerNeedRestart();
    this.enableAnimations = isEnableAnimations();
    this.sendMode = getSendMode() as string;
    this.favoriteDevices = getFavoritesService().slice();
    let sessions = getSendSessions();
    // Build IP-keyed status map (last session wins for each IP)
    let statuses: Record<string, string> = {};
    for (let i = 0; i < sessions.length; i++) {
      statuses[sessions[i].targetIp] = sessions[i].status as string;
    }
    this.sendSessionStatuses = statuses;
  }

  setSendModeValue(mode: string): void {
    this.sendMode = mode;
    setSendMode(mode as SendMode);
  }

  async pickFiles(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    let documentPicker = new picker.DocumentViewPicker(this.context);
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
      logger.error('pickFiles error: ' + JSON.stringify(e));
    }
    this.updateTotalSizeCache();
  }

  async pickImages(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    let photoPicker = new picker.PhotoViewPicker(this.context);
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
      logger.error('pickImages error: ' + JSON.stringify(e));
    }
    this.updateTotalSizeCache();
  }

  async pickAudio(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    let audioPicker = new picker.AudioViewPicker(this.context);
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
      logger.error('pickAudio error: ' + JSON.stringify(e));
    }
    this.updateTotalSizeCache();
  }

  // Returns false when the text is empty (caller shows the empty toast).
  handlePasteData(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    this.stageTextFile(text, 'clipboard_');
    return true;
  }

  stageTextFile(text: string, prefix: string): void {
    if (this.context === undefined) {
      return;
    }
    let sendDir: string = this.context.filesDir + '/send/';
    try {
      fs.mkdirSync(sendDir);
    } catch (_e) {}
    let fileName: string = prefix + Date.now() + '.txt';
    let filePath: string = sendDir + fileName;
    let file: fs.File = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
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

  rescanDevices(): void {
    rescanDevices();
  }

  // Returns the share-link URL to navigate to, or '' when no link was created
  // (cancelled picker or failure — caller falls back to the previous mode).
  async shareByLink(previousMode: string): Promise<string> {
    if (this.isCreatingShareLink) {
      return '';
    }
    if (this.stagedFiles.length === 0) {
      await this.pickFiles();
    }
    if (this.stagedFiles.length === 0) {
      // No files selected or picker cancelled — fall back to previous mode
      this.setSendModeValue(previousMode);
      return '';
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
          // Reset mode to single before navigating — avoids "link" highlight
          // on return, which would mislead users about device list behavior
          this.setSendModeValue(SendMode.single);
          return shareUrl;
        }
      }
    } catch (_e) {
      // Link creation failed — fall back to previous mode
      this.setSendModeValue(previousMode);
      return '';
    } finally {
      this.isCreatingShareLink = false;
    }
    return '';
  }

  // Builds TransferPage params for a single-target send, or undefined when no
  // files are staged.
  buildSendParams(device: DiscoveredDevice): Record<string, Object | string | number | boolean | Array<string>> | undefined {
    if (this.stagedFiles.length === 0) {
      return undefined;
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
      'sendMode': this.sendMode
    };
    return params;
  }

  // Inline send for multiple-target mode — no TransferPage, status shown on device card
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
  }

  isFavoriteDevice(fingerprint: string): boolean {
    return isFavorite(fingerprint);
  }

  removeFavorite(fingerprint: string): void {
    removeFavorite(fingerprint);
  }

  addFavorite(device: DiscoveredDevice, newAlias: string | undefined): void {
    addFavoriteFromDiscovered(device, newAlias);
  }

  startServer(): Promise<string | void> {
    return startServer();
  }

  isServerRunning(): boolean {
    return isServerRunning();
  }

  restartServer(): Promise<string | void> {
    return restartServer();
  }

  private extractFileNameFromUri(uri: string): string {
    let decoded = decodeURIComponent(uri);
    let idx = decoded.lastIndexOf('/');
    if (idx >= 0 && idx < decoded.length - 1) {
      return decoded.substring(idx + 1);
    }
    return 'file_' + Date.now();
  }

  private getExtension(fileName: string): string {
    let dot = fileName.lastIndexOf('.');
    if (dot >= 0 && dot < fileName.length - 1) {
      return fileName.substring(dot + 1).toLowerCase();
    }
    return '';
  }
}
