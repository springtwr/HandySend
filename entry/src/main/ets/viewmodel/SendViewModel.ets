import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import {
  getDiscoveredDevices,
  rescanDevices,
  isScanningStatus,
  prepareSendFiles,
  createShareLink,
  getShareLink,
  getLocalDeviceInfo,
  getDeviceType,
  getDeviceModel,
  isSendCompletedAndReset,
  processSharedUris,
  setSendMode,
  getSendMode,
  getSendSessions,
  getChecksumProgress,
  getChecksumTotal,
  calculateChecksumsForFiles,
  isServerRunning,
  doesServerNeedRestart,
  isEnableAnimations,
  getNoWifiWarning,
  getAllInterfacesDisabled,
  consumePendingSharedUris,
  sendToDeviceMulti,
  startServer,
  restartServer,
  clearAllSendSessions,
  setPrePreparedItems,
  peekPrePreparedItems,
  invalidatePrePreparedItems
} from '../service/AppService';
import { DiscoveredDevice, SendFileItem, StagedFile, SendMode, FavoriteDevice } from '../model/Types';
import {
  addFavoriteFromDiscovered,
  removeFavorite,
  isFavorite,
  getFavorites as getFavoritesService,
  subscribeFavorites,
  unsubscribeFavorites
} from '../service/FavoritesService';
import { getMimeForExt as mimeGetMimeForExt, isImageExtension } from '../utils/MimeUtils';
import { generateVideoThumbnail } from '../utils/VideoThumbnailUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendViewModel');

// 发送页签业务状态 + 命令，从 SendContent 抽出。
// 持有服务器状态镜像 + 收藏快照，无需 AppStorage 即可响应式渲染。
@ObservedV2
export class SendViewModel {
  @Trace public stagedFiles: Array<StagedFile> = []
  @Trace public discoveredDevices: Array<DiscoveredDevice> = []
  @Trace public checksumProgress: number = 0
  @Trace public checksumTotal: number = 0
  @Trace public sendSessionStatuses: Record<string, string> = {} // key=IP，value=最新状态字符串
  @Trace public cachedTotalSizeText: string = ''
  @Trace public isCreatingShareLink: boolean = false
  // 服务器状态 + 设置镜像
  @Trace public serverReady: boolean = false
  @Trace public serverNeedsRestart: boolean = false
  @Trace public enableAnimations: boolean = true
  @Trace public sendMode: string = 'single'
  @Trace public favoriteDevices: Array<FavoriteDevice> = []
  @Trace public isScanning: boolean = false
  @Trace public noWifiWarning: boolean = false
  @Trace public allInterfacesDisabled: boolean = false
  private context: common.UIAbilityContext | undefined = undefined
  private favoritesCallback: () => void = () => {
  }
  // 已触发视频缩略图生成的 uri 集合（防重复加载）
  private videoPreviewRequestedUris: Set<string> = new Set()

  init(context: common.UIAbilityContext): void {
    this.context = context;
    this.sendMode = getSendMode() as string;
  }

  // 订阅收藏设备变化（从视图的 aboutToAppear 调用）。
  subscribeFavorites(): void {
    this.favoritesCallback = () => {
      this.favoriteDevices = getFavoritesService().slice();
    };
    subscribeFavorites(this.favoritesCallback);
  }

  // 取消订阅收藏设备变化（从视图的 aboutToDisappear 调用）。
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
        invalidatePrePreparedItems();
        this.updateTotalSizeCache();
      }
    }
    this.discoveredDevices = getDiscoveredDevices();
    this.isScanning = isScanningStatus();
    this.checksumProgress = getChecksumProgress();
    this.checksumTotal = getChecksumTotal();
    this.serverReady = isServerRunning();
    this.serverNeedsRestart = doesServerNeedRestart();
    this.noWifiWarning = getNoWifiWarning();
    this.allInterfacesDisabled = getAllInterfacesDisabled();
    this.enableAnimations = isEnableAnimations();
    this.sendMode = getSendMode() as string;
    this.favoriteDevices = getFavoritesService().slice();
    let sessions = getSendSessions();
    // 构建以 IP 为键的状态映射（每个 IP 取最后一个会话）
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
        let staged: StagedFile = {
          uri: uri,
          fileName: name,
          fileType: mime,
          isImage: isImg
        };
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
    // 使用 Media Library Kit 的 photoAccessHelper（@ohos.file.picker 的 PhotoViewPicker 自 API 12 起废弃）
    let photoPicker = new photoAccessHelper.PhotoViewPicker();
    let options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 10;
    try {
      let result = await photoPicker.select(options);
      let uris: Array<string> = result.photoUris;
      for (let i = 0; i < uris.length; i++) {
        let uri = uris[i];
        let name = this.extractFileNameFromUri(uri);
        let ext = this.getExtension(name);
        let mime = mimeGetMimeForExt(ext);
        let staged: StagedFile = {
          uri: uri,
          fileName: name,
          fileType: mime,
          isImage: true
        };
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
        let staged: StagedFile = {
          uri: uri,
          fileName: name,
          fileType: mime,
          isImage: false
        };
        this.stagedFiles.push(staged);
      }
    } catch (e) {
      logger.error('pickAudio error: ' + JSON.stringify(e));
    }
    this.updateTotalSizeCache();
  }

  // 文本为空时返回 false（调用方显示空内容 Toast）。
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
    } catch (_e) {
    }
    let fileName: string = prefix + Date.now() + '.txt';
    let filePath: string = sendDir + fileName;
    let file: fs.File = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
    let staged: StagedFile = {
      uri: filePath,
      fileName: fileName,
      fileType: 'text/plain',
      isImage: false,
      isManualText: true
    };
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
    // 文件列表变化，清空预准备缓存
    invalidatePrePreparedItems();
    // 当所有文件被移除时，清除会话状态
    if (updated.length === 0) {
      clearAllSendSessions();
      this.sendSessionStatuses = {};
    }
    this.updateTotalSizeCache();
  }

  // 视频暂存项的缩略图懒加载（发送页文件选择列表行出现时调用，fire-and-forget）。
  // 生成成功后重建数组携带新的 item（含缩略图），配合列表 key 含就绪标记实现界面刷新；
  // 文件不可用/解码失败时静默回退类型图标。
  async loadVideoPreview(index: number): Promise<void> {
    let src = this.stagedFiles[index];
    if (src === undefined) {
      return;
    }
    if (!src.fileType.startsWith('video/')) {
      return;
    }
    if (src.previewPixelMap !== undefined || this.videoPreviewRequestedUris.has(src.uri)) {
      return;
    }
    this.videoPreviewRequestedUris.add(src.uri);
    let pixelMap = await generateVideoThumbnail(src.uri, 96, 96);
    if (pixelMap === undefined) {
      logger.warn('loadVideoPreview: 生成失败，回退类型图标 idx=' + index);
      return;
    }
    let updated: Array<StagedFile> = this.stagedFiles.slice();
    let copy: StagedFile = {
      uri: src.uri,
      fileName: src.fileName,
      fileType: src.fileType,
      isImage: src.isImage,
      isManualText: src.isManualText,
      previewPixelMap: pixelMap
    };
    updated[index] = copy;
    this.stagedFiles = updated;
  }

  clearStagedFiles(): void {
    this.stagedFiles = [];
    invalidatePrePreparedItems();
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

  // 返回要导航到的分享链接 URL；未创建链接时返回 ''
  // （选择器被取消或失败——调用方回退到之前的模式）。
  async shareByLink(previousMode: string): Promise<string> {
    if (this.isCreatingShareLink) {
      return '';
    }
    if (this.stagedFiles.length === 0) {
      await this.pickFiles();
    }
    if (this.stagedFiles.length === 0) {
      // 未选择文件或选择器被取消——回退到之前的模式
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
          // 导航前将模式重置为 single——避免 "link" 高亮
          // 返回时，这会误导用户对设备列表行为的理解
          this.setSendModeValue(SendMode.single);
          return shareUrl;
        }
      }
    } catch (_e) {
      // 链接创建失败——回退到之前的模式
      this.setSendModeValue(previousMode);
      return '';
    } finally {
      this.isCreatingShareLink = false;
    }
    return '';
  }

  // 构建单目标发送的 TransferPage 参数；没有需要导航的请求时返回 undefined
  // 文件已暂存。
  buildSendParams(
    device: DiscoveredDevice): Record<string, Object | string | number | boolean | Array<string>> | undefined {
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

  // 单目标发送前置准备：提前准备文件 + 计算校验和，结果缓存供 TransferViewModel 消费。
  // 返回 true 表示准备成功，可以导航；false 表示失败或无文件。
  // 如果缓存中已有预准备结果（文件未变化），跳过重复计算。
  async prepareAndChecksumForSend(): Promise<boolean> {
    if (this.stagedFiles.length === 0) {
      return false;
    }
    // 复用缓存——单目标模式可能用户重试发送（对方拒绝后重新点击）
    let items: Array<SendFileItem> | undefined = peekPrePreparedItems();
    if (items !== undefined && items.length > 0) {
      // 已有缓存，所有文件也都有 hash，直接复用
      let allHashed = true;
      for (let i = 0; i < items.length; i++) {
        if (items[i].hash === undefined || items[i].hash!.length === 0) {
          allHashed = false;
          break;
        }
      }
      if (allHashed) {
        return true;
      }
    }
    let uris: Array<string> = [];
    for (let i = 0; i < this.stagedFiles.length; i++) {
      uris.push(this.stagedFiles[i].uri);
    }
    items = await prepareSendFiles(uris);
    if (items.length === 0) {
      return false;
    }
    // 计算校验和（若设置开启，跳过已有 hash 的文件），进度条通过 notifyChange → refresh() 实时刷新
    await calculateChecksumsForFiles(items);
    // 重置本地进度显示
    this.checksumProgress = 0;
    this.checksumTotal = 0;
    // 缓存预准备结果，TransferViewModel 会消费
    setPrePreparedItems(items);
    return true;
  }

  // 多目标模式内联发送——不跳转 TransferPage，状态显示在设备卡片上
  async sendToMultipleDeviceInline(device: DiscoveredDevice): Promise<void> {
    // 立即显示"等待中"状态，让用户看到反馈
    let newStatuses: Record<string, string> = {};
    // 保留现有状态
    let keys = Object.keys(this.sendSessionStatuses);
    for (let i = 0; i < keys.length; i++) {
      newStatuses[keys[i]] = this.sendSessionStatuses[keys[i]];
    }
    newStatuses[device.ip] = 'waiting';
    this.sendSessionStatuses = newStatuses;

    // 复用缓存的预准备文件（已含校验和），避免每点一台设备就重新 prepare + checksum
    let items: Array<SendFileItem> | undefined = peekPrePreparedItems();
    if (items === undefined || items.length === 0) {
      // 首次点击：准备文件 + 计算校验和，缓存供后续设备复用
      let uris: Array<string> = [];
      for (let i = 0; i < this.stagedFiles.length; i++) {
        uris.push(this.stagedFiles[i].uri);
      }
      items = await prepareSendFiles(uris);
      if (items.length === 0) {
        // 发送准备失败，移除等待状态
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
      // 计算校验和（跳过已有 hash 的文件），进度条通过 notifyChange 实时刷新
      await calculateChecksumsForFiles(items);
      // 缓存供后续设备复用
      setPrePreparedItems(items);
      // 重置进度显示
      this.checksumProgress = 0;
      this.checksumTotal = 0;
    }
    // 使用 sendToDeviceMulti 发送单设备——它会创建会话并更新状态
    await sendToDeviceMulti([device], items);
    // 多目标模式下不清空已暂存文件——用户可能还要发送给更多设备
  }

  async sendToMultipleDevices(): Promise<void> {
    if (this.stagedFiles.length === 0) {
      return;
    }
    if (this.discoveredDevices.length === 0) {
      return;
    }
    // 复用缓存
    let items: Array<SendFileItem> | undefined = peekPrePreparedItems();
    if (items === undefined || items.length === 0) {
      let uris: Array<string> = [];
      for (let i = 0; i < this.stagedFiles.length; i++) {
        uris.push(this.stagedFiles[i].uri);
      }
      items = await prepareSendFiles(uris);
      if (items.length === 0) {
        return;
      }
      await calculateChecksumsForFiles(items);
      setPrePreparedItems(items);
      this.checksumProgress = 0;
      this.checksumTotal = 0;
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
