import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { formatSizeDetailed } from '../utils/FormatUtil';
import { DeviceItemViewModel } from './DeviceItemViewModel';
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
  getActiveProgress,
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
import { DiscoveredDevice, SendFileItem, StagedFile, SendMode, FavoriteDevice, TransferFileDescriptor, TransferProgress } from '../model/Types';
import {
  addFavoriteFromDiscovered,
  removeFavorite,
  isFavorite,
  getFavorites as getFavoritesService,
  subscribeFavorites,
  unsubscribeFavorites
} from '../service/FavoritesService';
import { computeSessionProgress } from '../utils/TransferProgressUtil';
import { getMimeForExt as mimeGetMimeForExt, isImageExtension } from '../utils/MimeUtils';
import { generateVideoThumbnail } from '../utils/VideoThumbnailUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendViewModel');

// 收藏展示对象构建（模块级纯函数，可被 entry/src/test 单测直接导入）：
// 以持久化收藏记录为骨架，叠加同指纹的实时发现快照字段。
// 合并规则：自定义别名不可被广播别名覆盖；IP/端口/协议优先实时快照；
// 版本/型号/类型按 FR-006 回退链取值：实时快照(非空字符串) >
// 收藏记录持久化字段(非空字符串) > 缺省——设备离线时由收藏时持久化的
// 型号/类型/版本兜底，保证徽标、图标与详情页版本号不缺失。
function buildFavoriteDisplayDevice(fav: FavoriteDevice, live?: DiscoveredDevice): DiscoveredDevice {
  // 版本：实时快照 > 收藏记录持久化值 > ''（详情页版本号为空）
  let version: string = '';
  if (live !== undefined && live.version.length > 0) {
    version = live.version;
  } else if (fav.version !== undefined && fav.version.length > 0) {
    version = fav.version;
  }
  // 型号：实时快照 > 收藏记录持久化值 > ''（型号徽标隐藏）
  let deviceModel: string = '';
  if (live !== undefined && live.deviceModel.length > 0) {
    deviceModel = live.deviceModel;
  } else if (fav.deviceModel !== undefined && fav.deviceModel.length > 0) {
    deviceModel = fav.deviceModel;
  }
  // 类型：实时快照 > 收藏记录持久化值 > 'mobile'（默认图标）
  let deviceType: string = 'mobile';
  if (live !== undefined && live.deviceType.length > 0) {
    deviceType = live.deviceType;
  } else if (fav.deviceType !== undefined && fav.deviceType.length > 0) {
    deviceType = fav.deviceType;
  }
  let display: DiscoveredDevice = {
    // 别名：用户自定义别名恒定优先；否则实时快照别名优先于收藏记录兜底
    alias: fav.customAlias === true ? fav.alias : (live !== undefined ? live.alias : fav.alias),
    ip: live?.ip ?? fav.ip,
    port: live?.port ?? fav.port,
    // 指纹是收藏记录主键，恒定不变
    fingerprint: fav.fingerprint,
    version: version,
    deviceModel: deviceModel,
    deviceType: deviceType,
    // 协议：实时快照 > 上次成功连接的协议 > 'http'
    protocol: live?.protocol ?? fav.lastProtocol ?? 'http',
    // 离线时 lastSeen 为 0（哨兵值）
    lastSeen: live?.lastSeen ?? 0,
    channels: live?.channels ?? [],
    publicKey: live?.publicKey
  };
  return display;
}

// 发送页签业务状态 + 命令，从 SendContent 抽出。
// 持有服务器状态镜像 + 收藏快照，无需 AppStorage 即可响应式渲染。
@ObservedV2
export class SendViewModel {
  @Trace public stagedFiles: Array<StagedFile> = []
  @Trace public discoveredDevices: Array<DiscoveredDevice> = []
  // 设备列表展示数据源：包装 DiscoveredDevice 的 DeviceItemViewModel，供 DeviceListItem 消费。
  // 与 discoveredDevices 同步刷新（refresh() 中重建）。
  @Trace public deviceItemViewModels: Array<DeviceItemViewModel> = []
  @Trace public checksumProgress: number = 0
  @Trace public checksumTotal: number = 0
  @Trace public sendSessionStatuses: Record<string, string> = {} // key=IP，value=最新状态字符串
  // 多目标发送时每台设备（key=IP）的发送百分比（0-100），供设备列表内联展示。
  @Trace public sendSessionProgress: Record<string, number> = {}
  // 多目标发送时每台设备（key=IP）的错误消息，finishedWithErrors/pinRequired 等终态时显示具体原因。
  @Trace public sendSessionErrorMessages: Record<string, string> = {}
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

  // 检查 URI 是否已在暂存列表中（基于 URI 精确匹配）。
  // Picker 返回的用户文件 URI 是文件的唯一标识，同一文件多次选中 URI 字符串一致，
  // 因此直接比对字符串即可可靠去重。
  private isAlreadyStaged(uri: string): boolean {
    for (let i = 0; i < this.stagedFiles.length; i++) {
      if (this.stagedFiles[i].uri === uri) {
        return true;
      }
    }
    return false;
  }

  // 过滤掉已暂存的文件，返回新增项。
  private filterNewStaged(files: Array<StagedFile>): Array<StagedFile> {
    let result: Array<StagedFile> = [];
    for (let i = 0; i < files.length; i++) {
      if (!this.isAlreadyStaged(files[i].uri)) {
        result.push(files[i]);
      }
    }
    return result;
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
      let newFiles: Array<StagedFile> = this.filterNewStaged(sharedFiles);
      if (newFiles.length > 0) {
        // 合并而非替换：保留用户已手动暂存的文件
        for (let i = 0; i < newFiles.length; i++) {
          this.stagedFiles.push(newFiles[i]);
        }
        invalidatePrePreparedItems();
        this.updateTotalSizeCache();
      }
    }
    // .slice() 强制产生新数组引用：V2 状态管理下 @Trace 数组同引用重复赋值不触发 UI 刷新
    // （官方 FAQ faqs-arkui-1011 场景一）；被动 device_found 到达时 mergeDeviceIntoList
    // 仅做元素替换、原始数组引用不变，透传原始引用会使界面不更新。取副本保证每次
    // 通知均可被观测，与下方 favoriteDevices 的既有 .slice() 惯例保持一致。
    this.discoveredDevices = getDiscoveredDevices().slice();
    let viewModels: Array<DeviceItemViewModel> = [];
    for (let i = 0; i < this.discoveredDevices.length; i++) {
      viewModels.push(new DeviceItemViewModel(this.discoveredDevices[i]));
    }
    this.deviceItemViewModels = viewModels;
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
    // 构建以 IP 为键的错误消息映射（终态会话携带 errorMessage 时）
    let errorMessages: Record<string, string> = {};
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].errorMessage !== undefined && sessions[i].errorMessage!.length > 0) {
        errorMessages[sessions[i].targetIp] = sessions[i].errorMessage!;
      }
    }
    this.sendSessionErrorMessages = errorMessages;
    // 构建以 IP 为键的发送百分比映射（每设备独立进度）。
    // 使用 computeSessionProgress：按会话内文件(fileId)聚合，避免逻辑会话 id 与接收方会话 id 不一致导致恒为 0。
    let active: Array<TransferProgress> = getActiveProgress();
    let progressBySession: Record<string, number> = computeSessionProgress(sessions, active);
    let sendProgress: Record<string, number> = {};
    for (let i = 0; i < sessions.length; i++) {
      let st = sessions[i];
      sendProgress[st.targetIp] = progressBySession[st.sessionId] ?? 0;
    }
    this.sendSessionProgress = sendProgress;
    logger.debug('[send-progress] sessions=' + sessions.length + ' active=' + active.length +
      ' progress=' + JSON.stringify(sendProgress) +
      ' statuses=' + JSON.stringify(statuses));
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
      this.stageUris(uris, undefined);
    } catch (e) {
      logger.error('pickFiles error: ' + JSON.stringify(e));
    }
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
      this.stageUris(uris, true);
    } catch (e) {
      logger.error('pickImages error: ' + JSON.stringify(e));
    }
  }

  async pickAudio(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    let audioPicker = new picker.AudioViewPicker(this.context);
    let options = new picker.AudioSelectOptions();
    try {
      let uris: Array<string> = await audioPicker.select(options);
      this.stageUris(uris, false);
    } catch (e) {
      logger.error('pickAudio error: ' + JSON.stringify(e));
    }
  }

  // 视频选择：使用 photoAccessHelper.PhotoViewPicker + VIDEO_TYPE
  async pickVideos(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    let photoPicker = new photoAccessHelper.PhotoViewPicker();
    let options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE;
    options.maxSelectNumber = 10;
    try {
      let result = await photoPicker.select(options);
      let uris: Array<string> = result.photoUris;
      this.stageUris(uris, false);
    } catch (e) {
      logger.error('pickVideos error: ' + JSON.stringify(e));
    }
  }

  // 文档选择：使用 DocumentViewPicker + fileSuffixFilters 过滤办公格式
  async pickDocuments(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    let documentPicker = new picker.DocumentViewPicker(this.context);
    let options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 10;
    options.fileSuffixFilters = ['文档|.doc,.docx,.ppt,.pptx,.xls,.xlsx,.pdf,.wps,.et,.dps,.ofd,.xmind,.mm,.opml'];
    try {
      let uris: Array<string> = await documentPicker.select(options);
      this.stageUris(uris, undefined);
    } catch (e) {
      logger.error('pickDocuments error: ' + JSON.stringify(e));
    }
  }

  // 压缩包选择：使用 DocumentViewPicker + fileSuffixFilters 过滤压缩包格式
  async pickArchives(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    let documentPicker = new picker.DocumentViewPicker(this.context);
    let options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 10;
    options.fileSuffixFilters = ['压缩包|.zip,.rar,.7z,.tar,.gz'];
    try {
      let uris: Array<string> = await documentPicker.select(options);
      this.stageUris(uris, false);
    } catch (e) {
      logger.error('pickArchives error: ' + JSON.stringify(e));
    }
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
      this.sendSessionProgress = {};
      this.sendSessionErrorMessages = {};
    }
    this.updateTotalSizeCache();
  }

  // 视频暂存项的缩略图懒加载（fire-and-forget）。
  // 生成成功后重建数组携带新的 item（含缩略图），配合列表 key 含就绪标记实现界面刷新；
  // 文件不可用/解码失败时静默回退类型图标。
  // 当前竖向列表模式下不显示缩略图，此方法暂未从 UI 触发调用。
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
    this.sendSessionProgress = {};
    this.sendSessionErrorMessages = {};
    this.cachedTotalSizeText = '';
  }

  updateTotalSizeCache(): void {
    let totalBytes = this.computeStagedTotalSize();
    this.cachedTotalSizeText = totalBytes === 0 ? '' : formatSizeDetailed(totalBytes);
  }

  getTotalSizeText(): string {
    return this.cachedTotalSizeText;
  }

  rescanDevices(): void {
    rescanDevices();
  }

  // 返回要导航到的分享链接 URL；未创建链接时返回 ''
  // （选择器被取消或失败）。
  // 网页分享是一次性动作，不改变发送模式值。
  async shareByLink(): Promise<string> {
    if (this.isCreatingShareLink) {
      return '';
    }
    if (this.stagedFiles.length === 0) {
      await this.pickFiles();
    }
    if (this.stagedFiles.length === 0) {
      // 未选择文件或选择器被取消
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
          return shareUrl;
        }
      }
    } catch (_e) {
      // 链接创建失败
      return '';
    } finally {
      this.isCreatingShareLink = false;
    }
    return '';
  }

  // 构建单目标发送的 TransferPage 参数；没有需要导航的请求时返回 undefined
  // 文件已暂存。
  buildSendParams(
    device: DiscoveredDevice): Record<string, Object | string | number | boolean | Array<string> | Array<TransferFileDescriptor>> | undefined {
    if (this.stagedFiles.length === 0) {
      return undefined;
    }
    let uris: Array<string> = [];
    for (let i = 0; i < this.stagedFiles.length; i++) {
      uris.push(this.stagedFiles[i].uri);
    }
    let allManualText: boolean = true;
    let computedTotalSize = this.computeStagedTotalSize();
    for (let i = 0; i < this.stagedFiles.length; i++) {
      if (this.stagedFiles[i].isManualText !== true) {
        allManualText = false;
      }
    }
    // 文件清单：优先使用预准备缓存（含稳定的 fileId 与真实大小），
    // 以便逐文件进度能按 fileId 匹配 activeProgress；缓存缺失时回退到
    // 暂存文件（此时 fileId 为空、大小由 stat 计算）。
    let descriptors: Array<TransferFileDescriptor> = [];
    let prePrepared: Array<SendFileItem> | undefined = peekPrePreparedItems();
    if (prePrepared !== undefined && prePrepared.length > 0) {
      for (let i = 0; i < prePrepared.length; i++) {
        let item = prePrepared[i];
        descriptors.push({
          fileId: item.fileId,
          fileName: item.fileName,
          size: item.size,
          fileType: item.fileType
        });
      }
    } else {
      for (let i = 0; i < this.stagedFiles.length; i++) {
        let sf = this.stagedFiles[i];
        let fileSize: number = 0;
        try {
          let stat = fs.statSync(sf.uri);
          fileSize = stat.size;
        } catch (_e) {
        }
        descriptors.push({
          fileId: '',
          fileName: sf.fileName,
          size: fileSize,
          fileType: sf.fileType
        });
      }
    }
    let localInfo = getLocalDeviceInfo();
    let params: Record<string, Object | string | number | boolean | Array<string> | Array<TransferFileDescriptor>> = {
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
      'fileDescriptors': descriptors,
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
    items = await this.prepareAndCacheItems();
    return items.length > 0;
  }

  // 多目标模式内联发送——不跳转 TransferPage，状态显示在设备卡片上
  async sendToMultipleDeviceInline(device: DiscoveredDevice): Promise<void> {
    // 若该设备已有进行中的发送（等待/校验中/发送中），忽略重复点击，避免向同一设备并发发送导致"设备忙"。
    let existingStatus: string | undefined = this.sendSessionStatuses[device.ip];
    if (existingStatus !== undefined &&
      (existingStatus === 'waiting' || existingStatus === 'calculatingHash' || existingStatus === 'sending')) {
      return;
    }

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
      items = await this.prepareAndCacheItems();
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
      items = await this.prepareAndCacheItems();
      if (items.length === 0) {
        return;
      }
    }
    await sendToDeviceMulti(this.discoveredDevices, items);
  }

  // 收藏清单展示数据源：仅输出「不在发现快照中」的离线收藏设备（FR-010 展示分流唯一性）。
  // 在线收藏（指纹 ∈ 发现快照）跳过不输出——该设备仅由附近列表渲染，
  // 实心爱心即收藏标记，从而保证任意时刻每台设备恰好出现一次；
  // 判定只按 fingerprint 匹配，不比较 IP（容忍 DHCP 重新分配）。
  // 由 @Trace favoriteDevices / discoveredDevices 驱动，Repeat 引用即可响应式刷新。
  getFavoriteDevicesForDisplay(): Array<DiscoveredDevice> {
    let result: Array<DiscoveredDevice> = [];
    for (let i = 0; i < this.favoriteDevices.length; i++) {
      let fav = this.favoriteDevices[i];
      // 指纹命中发现快照即视为在线，从收藏清单排除
      let foundInSnapshot: boolean = false;
      for (let j = 0; j < this.discoveredDevices.length; j++) {
        if (this.discoveredDevices[j].fingerprint === fav.fingerprint) {
          foundInSnapshot = true;
          break;
        }
      }
      if (foundInSnapshot) {
        continue;
      }
      // 离线收藏：无实时快照，型号/类型/版本由收藏记录持久化字段兜底
      // （FR-006 回退链末级；缺省时徽标隐藏/默认图标/空版本），lastSeen 置 0
      result.push(buildFavoriteDisplayDevice(fav, undefined));
    }
    return result;
  }

  // 收藏列表展示数据源（DeviceItemViewModel 包装版，供 DeviceListItem 消费）。
  getFavoriteDeviceItemViewModels(): Array<DeviceItemViewModel> {
    let devices = this.getFavoriteDevicesForDisplay();
    let result: Array<DeviceItemViewModel> = [];
    for (let i = 0; i < devices.length; i++) {
      result.push(new DeviceItemViewModel(devices[i]));
    }
    return result;
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

  // ── 私有辅助：选择/统计/prepare 收敛（US5） ──

  // 将选择器返回的 uri 列表去重后暂存为 StagedFile 并刷新总大小缓存。
  // forceImage: true=强制标记为图片（图片选择器）；false=强制非图片（音频/视频/压缩包）；
  // undefined=按扩展名判断（通用/文档选择器）。
  private stageUris(uris: Array<string>, forceImage: boolean | undefined): void {
    for (let i = 0; i < uris.length; i++) {
      let uri = uris[i];
      if (this.isAlreadyStaged(uri)) {
        continue;
      }
      let name = this.extractFileNameFromUri(uri);
      let ext = this.getExtension(name);
      let isImg: boolean = forceImage !== undefined ? forceImage : isImageExtension(ext);
      let mime = mimeGetMimeForExt(ext);
      let staged: StagedFile = {
        uri: uri,
        fileName: name,
        fileType: mime,
        isImage: isImg
      };
      this.stagedFiles.push(staged);
    }
    this.updateTotalSizeCache();
  }

  // 计算所有暂存文件的总字节数（stat 失败的文件跳过，与历史实现一致）。
  private computeStagedTotalSize(): number {
    let total: number = 0;
    for (let i = 0; i < this.stagedFiles.length; i++) {
      try {
        let stat = fs.statSync(this.stagedFiles[i].uri);
        total = total + stat.size;
      } catch (_e) {
      }
    }
    return total;
  }

  // 准备暂存文件（prepareSendFiles + 计算校验和）并缓存预准备结果，供 TransferViewModel 消费。
  // 返回准备结果；无文件/失败时返回空数组。
  private async prepareAndCacheItems(): Promise<Array<SendFileItem>> {
    let uris: Array<string> = [];
    for (let i = 0; i < this.stagedFiles.length; i++) {
      uris.push(this.stagedFiles[i].uri);
    }
    let items: Array<SendFileItem> = await prepareSendFiles(uris);
    if (items.length === 0) {
      return items;
    }
    // 计算校验和（若设置开启，跳过已有 hash 的文件），进度条通过 notifyChange → refresh() 实时刷新
    await calculateChecksumsForFiles(items);
    // 重置本地进度显示
    this.checksumProgress = 0;
    this.checksumTotal = 0;
    // 缓存预准备结果，TransferViewModel 会消费
    setPrePreparedItems(items);
    return items;
  }
}
