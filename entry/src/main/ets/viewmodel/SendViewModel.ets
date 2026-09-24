import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { formatSizeDetailed } from '../utils/FormatUtil';
import { DeviceItemViewModel } from './DeviceItemViewModel';
import {
  getDiscoveredDevices,
  rescanDevices,
  isScanningStatus,
  prepareSendFiles,
  createShareLink,
  getShareLink,
  processSharedUris,
  isAutoClearStagedAfterSend,
  calculateChecksumsForFiles,
  isServerRunning,
  doesServerNeedRestart,
  getNoWifiWarning,
  getAllInterfacesDisabled,
  consumePendingSharedUris,
  consumePendingSharedTexts,
  sendToDeviceMulti,
  startServer,
  restartServer,
  clearAllSendSessions,
  querySessions,
  setPrePreparedItems,
  peekPrePreparedItems,
  invalidatePrePreparedItems,
  getMtaDiscoveredDevices,
  isMtaBluetoothOn,
  isMtaWifiOn,
  isMtaConnectionWarnings,
  markMtaSendClicked,
  rescanMtaDiscovery,
  getLocalSendEnabled,
  getMtaEnabled,
  sendTextDir,
  connectByIp,
  getPort
} from '../service/AppService';
import {
  DiscoveredDevice,
  SendFileItem,
  StagedFile,
  FavoriteDevice,
  TransferFileDescriptor
} from '../model/Types';
import { TransferSession, SessionFilter, SessionStage, isTerminalStage } from '../model/transfer/TransferSession';
import { LOCAL_SEND_KEY } from '../service/transfer/adapters/LocalSendSendAdapter';
import {
  isMtaSendSessionActive,
  startMtaSend as startMtaSendFlow
} from '../service/transfer/adapters/MtaSendAdapter';
import { collectManualTextUris, isAllManualText } from '../model/SendTextPreparation';
import { DragDropParseResult } from '../model/DragDropParser';
import {
  addFavoriteFromDiscovered,
  removeFavorite,
  isFavorite,
  getFavorites as getFavoritesService,
  subscribeFavorites,
  unsubscribeFavorites
} from '../service/repository/FavoritesService';
import { buildMtaSendRequest, combineTextContents, MtaSendRequest } from '../model/mta/MtaMainModels';
import { partitionDevicesByType, hasAnyMtaDevice, DeviceTypePartition } from '../model/SendDeviceGrouping';
import { getMimeForExt as mimeGetMimeForExt, isImageExtension } from '../utils/MimeUtils';
import { generateVideoThumbnail } from '../utils/VideoThumbnailUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SendViewModel', '发送页');

// 设备来源键（与 DeviceSourceRegistry 中注册的来源描述符 key 一一对应）
const SOURCE_KEY_LOCAL_SEND: string = 'localsend';
const SOURCE_KEY_MTA: string = 'mta';

// ── 点击设备即发送的发起结果 ──

/** 「点击设备即发送」的发起结果。 */
export enum SendInitiateResult {
  /** 已进入发送流程 */
  initiated = 'initiated',
  /** 该目标已有进行中的发送，本次被拒绝执行 */
  blocked = 'blocked',
  /** 无暂存内容可发送 */
  noContent = 'no_content'
}

// ── 从收藏面板发起发送的结果 ──

/** 从收藏面板发起发送的结果（供视图给出对应提示）。 */
export enum FavoriteSendResult {
  /** 已进入发送流程 */
  initiated = 'initiated',
  /** 离线定向探测失败，未发起发送 */
  probeFailed = 'probe_failed',
  /** 无暂存内容可发送 */
  noContent = 'no_content',
  /** 该目标已有进行中的发送，本次被拒绝执行 */
  busy = 'busy',
  /** LocalSend 协议总开关关闭（防御分支） */
  disabled = 'disabled'
}

/**
 * 判定「点击设备即发送」的发起结果（纯函数，无副作用）：
 * 在途或已有活跃会话优先判为被拦截（不误伤正常路径），否则按是否有可发送内容判为已发起/无内容。
 */
export function decideSendInitiateResult(inFlight: boolean, hasActiveSession: boolean,
  hasContent: boolean): SendInitiateResult {
  if (inFlight || hasActiveSession) {
    return SendInitiateResult.blocked;
  }
  if (!hasContent) {
    return SendInitiateResult.noContent;
  }
  return SendInitiateResult.initiated;
}

/**
 * 失效手动文本条目筛选（纯函数，可注入文件存在性判定，便于单测）：
 * 移除标记为手动文本（isManualText）且底层文件已不存在的条目，保留其余条目。
 * 仅处理应用自建的发送文本条目；文件选择器等外部来源条目不在此列，不受影响。
 */
export function pruneMissingManualTextFiles(files: Array<StagedFile>,
  fileExists: (uri: string) => boolean): Array<StagedFile> {
  let kept: Array<StagedFile> = [];
  for (let i = 0; i < files.length; i++) {
    let staged: StagedFile = files[i];
    if (staged.isManualText === true && !fileExists(staged.uri)) {
      continue;
    }
    kept.push(staged);
  }
  return kept;
}

/**
 * 协议总开关设备来源过滤（纯函数，可独立测试）：
 * LocalSend 总开关关闭时局域网设备组清空、MTA 总开关关闭时互传设备组清空。
 */
export function filterDevicesByProtocolToggles(partition: DeviceTypePartition,
  localSendEnabled: boolean, mtaEnabled: boolean): DeviceTypePartition {
  return {
    local: localSendEnabled ? partition.local : [],
    mta: mtaEnabled ? partition.mta : []
  };
}

/**
 * 协议总开关收藏过滤（纯函数，可独立测试）：
 * LocalSend 总开关关闭时全部收藏隐藏（收藏均为局域网来源设备，MTA 设备不可收藏）。
 */
export function filterFavoritesByProtocolToggles(favorites: Array<FavoriteDevice>,
  localSendEnabled: boolean): Array<FavoriteDevice> {
  return localSendEnabled ? favorites : [];
}

/**
 * 协议总开关来源键过滤（纯函数，可独立测试）：
 * 从「曾发现过设备的来源」集合中移除被禁用协议对应的来源键（目标区来源标签随之消失）。
 */
export function filterSeenSourceKeysByProtocolToggles(seen: Array<string>,
  localSendEnabled: boolean, mtaEnabled: boolean): Array<string> {
  let result: Array<string> = [];
  for (let i = 0; i < seen.length; i++) {
    let key: string = seen[i];
    if (key === SOURCE_KEY_LOCAL_SEND && !localSendEnabled) {
      continue;
    }
    if (key === SOURCE_KEY_MTA && !mtaEnabled) {
      continue;
    }
    result.push(key);
  }
  return result;
}

/**
 * 「两个协议均禁用」提示卡显隐判定（纯函数，可独立测试）：
 * 单一协议禁用时不提示；仅两个总开关都关闭、且用户未在本次会话内关闭过该提示时显示。
 */
export function shouldShowProtocolDisabledHint(localSendEnabled: boolean, mtaEnabled: boolean,
  dismissed: boolean): boolean {
  return !localSendEnabled && !mtaEnabled && !dismissed;
}

// 发送页签业务状态 + 命令，从 SendContent 抽出。
// 持有服务器状态镜像 + 收藏快照，无需 AppStorage 即可响应式渲染。
@ObservedV2
export class SendViewModel {
  @Trace public stagedFiles: Array<StagedFile> = []
  @Trace public discoveredDevices: Array<DiscoveredDevice> = []
  // 按设备类型拆分的展示数据源：局域网（LocalSend）与互传联盟（MTA）各占一组，供设备类型标签分别渲染。
  @Trace public localDeviceItemViewModels: Array<DeviceItemViewModel> = []
  @Trace public mtaDeviceItemViewModels: Array<DeviceItemViewModel> = []
  // 会话级标记：本次发送页会话内是否曾发现过互传联盟设备。
  // 一旦置真即在 refresh() 中保持（不主动复位），作为设备类型标签出现与否的唯一依据。
  @Trace public hasSeenMtaDevice: boolean = false
  // 本机蓝牙开关状态：关闭时互传标签展示蓝牙未开启提示（蓝牙关闭会同时清空互传设备列表）
  @Trace public mtaBluetoothOn: boolean = true
  // 本机 WLAN 开关状态：互传 P2P 传输依赖 WLAN，关闭时提示可发现但无法传输
  @Trace public mtaWifiOn: boolean = true
  // 互传连接提醒开关：关闭时不显示互传相关的连接警告横幅
  @Trace public mtaConnectionWarnings: boolean = true
  // 协议总开关镜像：关闭时隐藏对应来源设备/收藏并 gate 连接警告（LocalSend 关=收藏全部隐藏，收藏均为局域网设备）
  @Trace public localSendEnabled: boolean = true
  @Trace public mtaEnabled: boolean = true
  @Trace public cachedTotalSizeText: string = ''
  @Trace public isCreatingShareLink: boolean = false
  // 服务器状态 + 设置镜像
  @Trace public serverReady: boolean = false
  @Trace public serverNeedsRestart: boolean = false
  // 刷新按钮旋转角（发送页目标区刷新反馈）
  @Trace public refreshAngle: number = 0
  // 本次发送页会话曾发现过设备的来源键（来源标签出现判定依据，会话内保持可见）
  @Trace public seenSourceKeys: Array<string> = []
  @Trace public favoriteDevices: Array<FavoriteDevice> = []
  @Trace public isScanning: boolean = false
  @Trace public noWifiWarning: boolean = false
  @Trace public allInterfacesDisabled: boolean = false
  private context: common.UIAbilityContext | undefined = undefined
  // 在途发送目标 IP 集合：点击后立即置位、发送收口后清除，弥补注册表会话创建前的空窗
  private inFlightSendIps: Set<string> = new Set()
  // 暂存项大小缓存（uri → 字节数）：statSync 结果稳定，避免重复系统调用
  private stagedSizeCache: Map<string, number> = new Map()
  private favoritesCallback: () => void = () => {
  }
  // 已触发视频缩略图生成的 uri 集合（防重复加载）
  private videoPreviewRequestedUris: Set<string> = new Set()

  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  // 订阅收藏设备变化（从视图的 aboutToAppear 调用）。
  subscribeFavorites(): void {
    this.favoritesCallback = () => {
      // LocalSend 总开关关闭时收藏保持隐藏（收藏均为局域网来源设备）
      this.favoriteDevices = filterFavoritesByProtocolToggles(getFavoritesService().slice(),
        this.localSendEnabled);
      // 收藏变更（新增/重命名/删除）即时回填附近列表别名，保证两处口径一致
      this.applyFavoriteAliases();
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
    // 失效手动文本条目自检：清除发送文本文件后移除底层文件已消失的条目（先于消费新内容收敛）
    this.pruneMissingStagedTextFiles();
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
    // 消费分享的文本/链接数据，写入文件后暂存
    let pendingTextsJson: string = consumePendingSharedTexts();
    if (pendingTextsJson.length > 0) {
      try {
        let parsed: Object = JSON.parse(pendingTextsJson);
        if (Array.isArray(parsed)) {
          let textRecords: Array<Object> = parsed as Array<Object>;
          for (let i = 0; i < textRecords.length; i++) {
            let record: Object = textRecords[i];
            let content: string = (record as Record<string, string>)['content'] ?? '';
            let title: string = (record as Record<string, string>)['title'] ?? '';
            let utd: string = (record as Record<string, string>)['utd'] ?? '';
            // 组合文本内容：超链接类型组合标题+内容，纯文本类型仅用内容
            let text: string = '';
            if (utd === 'general.hyperlink') {
              if (title.length > 0 && content.length > 0) {
                text = title + '\n' + content;
              } else if (content.length > 0) {
                text = content;
              } else if (title.length > 0) {
                text = title;
              }
            } else {
              text = content.length > 0 ? content : title;
            }
            // 跳过空内容（content 和 title 均为空）
            if (text.length === 0) {
              continue;
            }
            // prefix 根据 utd 类型区分：超链接 → 'link_'，其他 → 'share_'
            let prefix: string = utd === 'general.hyperlink' ? 'link_' : 'share_';
            // 失效时机由 stageTextFile 在确有新增时承担（空内容在上一分支已 continue）
            this.stageTextFile(text, prefix);
          }
        }
      } catch (_e) {
        logger.error('Failed to parse pending shared texts: ' + String(_e));
      }
    }
    // .slice() 强制产生新数组引用：V2 状态管理下 @Trace 数组同引用重复赋值不触发 UI 刷新
    // （官方 FAQ faqs-arkui-1011 场景一）；被动 device_found 到达时 mergeDeviceIntoList
    // 仅做元素替换、原始数组引用不变，透传原始引用会使界面不更新。取副本保证每次
    // 通知均可被观测，与下方 favoriteDevices 的既有 .slice() 惯例保持一致。
    this.discoveredDevices = getDiscoveredDevices().slice();
    // 本机蓝牙状态：关闭时互传设备一律不展示（蓝牙事件丢失时也能保证列表清空）
    this.mtaBluetoothOn = isMtaBluetoothOn();
    this.mtaWifiOn = isMtaWifiOn();
    this.mtaConnectionWarnings = isMtaConnectionWarnings();
    // 协议总开关镜像：驱动来源设备/收藏过滤与连接警告 gate
    this.localSendEnabled = getLocalSendEnabled();
    this.mtaEnabled = getMtaEnabled();
    // 合并 LocalSend（discoveredDevices）与 MTA（由 MtaRepository 独立持有，discoveredDevices 不含）
    // 为统一设备集，再按来源协议拆分为局域网/互传两组展示数据源。
    let mtaDiscovered: Array<DiscoveredDevice> = [];
    if (this.mtaBluetoothOn && this.mtaEnabled) {
      mtaDiscovered = getMtaDiscoveredDevices();
    }
    let allDevices: Array<DiscoveredDevice> = [];
    for (let i = 0; i < this.discoveredDevices.length; i++) {
      allDevices.push(this.discoveredDevices[i]);
    }
    for (let i = 0; i < mtaDiscovered.length; i++) {
      allDevices.push(mtaDiscovered[i]);
    }
    let partition: DeviceTypePartition = partitionDevicesByType(allDevices);
    // 协议总开关关闭时隐藏对应来源设备（LocalSend=局域网组，MTA=互传组）
    let visible: DeviceTypePartition = filterDevicesByProtocolToggles(partition,
      this.localSendEnabled, this.mtaEnabled);
    let localViewModels: Array<DeviceItemViewModel> = [];
    for (let i = 0; i < visible.local.length; i++) {
      localViewModels.push(new DeviceItemViewModel(visible.local[i]));
    }
    let mtaViewModels: Array<DeviceItemViewModel> = [];
    for (let i = 0; i < visible.mta.length; i++) {
      mtaViewModels.push(new DeviceItemViewModel(visible.mta[i]));
    }
    // 按来源协议分组的展示数据源（目标区分别渲染局域网与互传两组）
    this.localDeviceItemViewModels = localViewModels;
    this.mtaDeviceItemViewModels = mtaViewModels;
    // 一旦发现互传设备即置真，此后本次发送页会话内标签持续可见（即使互传设备数归 0）
    if (hasAnyMtaDevice(allDevices)) {
      this.hasSeenMtaDevice = true;
    }
    // 互传发现扫描的启停由页面可见性驱动（MainTabFloating），数据刷新不再拉起扫描
    this.isScanning = isScanningStatus();
    this.serverReady = isServerRunning();
    this.serverNeedsRestart = doesServerNeedRestart();
    this.noWifiWarning = getNoWifiWarning();
    this.allInterfacesDisabled = getAllInterfacesDisabled();
    // LocalSend 总开关关闭时隐藏全部收藏（收藏均为局域网来源设备）
    this.favoriteDevices = filterFavoritesByProtocolToggles(getFavoritesService().slice(),
      this.localSendEnabled);
    // 收藏自定义别名回填附近列表（与面板口径一致）
    this.applyFavoriteAliases();
    // 来源标签出现判定：记录本次会话曾发现过设备的来源（会话内保持可见；禁用来源除外）
    this.updateSeenSourceKeys();
  }

  /**
   * 依据已发现设备更新「曾发现过设备的来源」集合（会话内单调累积）。
   * 协议总开关关闭的来源不累积，并从集合中移除已累积键（目标区来源标签随之消失）。
   */
  private updateSeenSourceKeys(): void {
    let seen: Array<string> = filterSeenSourceKeysByProtocolToggles(this.seenSourceKeys,
      this.localSendEnabled, this.mtaEnabled);
    if (this.localSendEnabled && this.localDeviceItemViewModels.length > 0 &&
      seen.indexOf(SOURCE_KEY_LOCAL_SEND) < 0) {
      seen.push(SOURCE_KEY_LOCAL_SEND);
    }
    if (this.mtaEnabled && (this.mtaDeviceItemViewModels.length > 0 || this.hasSeenMtaDevice) &&
      seen.indexOf(SOURCE_KEY_MTA) < 0) {
      seen.push(SOURCE_KEY_MTA);
    }
    this.seenSourceKeys = seen;
  }

  /**
   * 收藏自定义别名回填：为附近列表条目写入其收藏的自定义别名，使面板与附近列表对同一设备
   * 显示一致；未收藏或无自定义别名时清空覆盖，回退设备广播别名。
   */
  private applyFavoriteAliases(): void {
    for (let i = 0; i < this.localDeviceItemViewModels.length; i++) {
      let item: DeviceItemViewModel = this.localDeviceItemViewModels[i];
      item.aliasOverride = this.favoriteAliasFor(item.fingerprint);
    }
  }

  /** 该设备收藏的自定义别名（未收藏或未设置自定义别名时返回空串）。 */
  private favoriteAliasFor(fingerprint: string): string {
    for (let i = 0; i < this.favoriteDevices.length; i++) {
      let favorite: FavoriteDevice = this.favoriteDevices[i];
      if (favorite.fingerprint === fingerprint) {
        // 仅自定义别名参与覆盖，避免收藏记录中的广播别名滞后于实时发现
        return favorite.customAlias ? favorite.alias : '';
      }
    }
    return '';
  }

  /**
   * 目标区某来源键的设备项数据源（响应式：来源注册表描述符 key → ViewModel 设备项数组）。
   * 目标区据此渲染设备网格，保证设备发现刷新能驱动 Repeat/Grid 重渲染；
   * 未接入映射的来源返回空数组，由调用方回退到注册表的发现数据源。
   */
  deviceItemsForSource(sourceKey: string): Array<DeviceItemViewModel> {
    if (sourceKey === SOURCE_KEY_LOCAL_SEND) {
      return this.localDeviceItemViewModels;
    }
    if (sourceKey === SOURCE_KEY_MTA) {
      return this.mtaDeviceItemViewModels;
    }
    return [];
  }

  /**
   * 失效手动文本条目自检：清空发送文本目录（或条目文件被外部移除）后，移除暂存列表中
   * 底层文件已不存在的手动文本条目，避免残留「点发送必然失败」的失效条目；
   * 文件选择器等外部来源条目不在此列。确有移除时失效预准备结果并刷新总大小统计。
   */
  private pruneMissingStagedTextFiles(): void {
    let kept: Array<StagedFile> = pruneMissingManualTextFiles(this.stagedFiles,
      (uri: string): boolean => this.stagedFileExists(uri));
    if (kept.length === this.stagedFiles.length) {
      return;
    }
    // 被移除条目的 stat 缓存项随之作废，避免缓存键累积
    for (let i = 0; i < this.stagedFiles.length; i++) {
      let uri: string = this.stagedFiles[i].uri;
      let retained: boolean = false;
      for (let j = 0; j < kept.length; j++) {
        if (kept[j].uri === uri) {
          retained = true;
          break;
        }
      }
      if (!retained) {
        this.stagedSizeCache.delete(uri);
      }
    }
    this.stagedFiles = kept;
    invalidatePrePreparedItems();
    this.updateTotalSizeCache();
  }

  /** 判定暂存项 uri 对应文件是否存在（访问异常按不存在处理）。 */
  private stagedFileExists(uri: string): boolean {
    try {
      return fs.accessSync(uri);
    } catch (_e) {
      return false;
    }
  }

  /** 暂存项真实字节大小（statSync 结果缓存；文件不可读时为 0）。 */
  getStagedFileSize(index: number): number {
    let staged: StagedFile | undefined = this.stagedFiles[index];
    if (staged === undefined) {
      return 0;
    }
    let cached: number | undefined = this.stagedSizeCache.get(staged.uri);
    if (cached !== undefined) {
      return cached;
    }
    let size: number = 0;
    try {
      size = fs.statSync(staged.uri).size;
    } catch (_e) {
      size = 0;
    }
    this.stagedSizeCache.set(staged.uri, size);
    return size;
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

  // 拖拽内容入口：解析结果 → 暂存列表（内部复用 stageUris / stageTextFile，不复制实现）。
  // uris 非空 → 按扩展名判定图片走 stageUris；texts 逐条以 drop_ 前缀走 stageTextFile
  // （空内容跳过、内容与既有文本条目重复则静默跳过）。
  // 返回 true 表示至少新增一条暂存，false 表示全部为重复或为空（供视图决定 Toast 与拖拽结果）。
  applyDroppedContent(result: DragDropParseResult): boolean {
    let added: boolean = false;
    if (result.uris.length > 0) {
      let beforeCount: number = this.stagedFiles.length;
      this.stageUris(result.uris, undefined);
      if (this.stagedFiles.length > beforeCount) {
        added = true;
      }
    }
    for (let i = 0; i < result.texts.length; i++) {
      let item = result.texts[i];
      if (item.content.length === 0) {
        continue;
      }
      // 文本条目由 stageTextFile 新建沙箱文件承载、URI 每次拖入均不同，无法按 URI 去重，
      // 故按内容精确匹配：已存在相同内容时静默跳过（不新增条目、不提示）
      if (this.isTextContentStaged(item.content)) {
        logger.debug('dropped text skipped (duplicate content): isLink=' + item.isLink);
        continue;
      }
      let beforeCount: number = this.stagedFiles.length;
      this.stageTextFile(item.content, 'drop_');
      if (this.stagedFiles.length > beforeCount) {
        added = true;
      }
      // isLink 仅用于来源追溯日志（拖入的超链接以组合文本暂存，行为与纯文本一致）
      logger.debug('dropped text staged: isLink=' + item.isLink + ' prefix=drop_');
    }
    return added;
  }

  // 判定暂存列表中是否已存在内容完全相同的文本条目（仅比较写入沙箱的文本条目）。
  // 文本条目 URI 指向自建文件，需读取内容逐条精确比较；读取失败（文件缺失等）视为未命中。
  private isTextContentStaged(content: string): boolean {
    for (let i = 0; i < this.stagedFiles.length; i++) {
      let staged: StagedFile = this.stagedFiles[i];
      if (staged.isManualText !== true) {
        continue;
      }
      let existing: string = '';
      try {
        existing = fs.readTextSync(staged.uri);
      } catch (_e) {
        continue;
      }
      if (existing === content) {
        return true;
      }
    }
    return false;
  }

  // 会话标志：应用进程内是否已弹过拖入可靠性提示（进程重启后重置）
  private static dropReliabilityHintShown: boolean = false;

  // 判定是否需要弹出拖入可靠性提示：仅移动端（非 2in1，电脑上直接拖拽不涉及中转站）、
  // 本次拖入含文件类记录（文本已写入沙箱、不受来源关闭影响）、且本会话尚未提示过；
  // 命中时置位会话标志（保证同一会话仅弹一次），返回是否需要弹窗。
  shouldShowDropReliabilityHint(hasFileRecords: boolean): boolean {
    if (!hasFileRecords) {
      return false;
    }
    if (deviceInfo.deviceType === '2in1') {
      return false;
    }
    if (SendViewModel.dropReliabilityHintShown) {
      return false;
    }
    SendViewModel.dropReliabilityHintShown = true;
    return true;
  }

  stageTextFile(text: string, prefix: string): void {
    if (this.context === undefined) {
      return;
    }
    // 手动文本写入「发送文本」统一目录（应用私有持久目录，filesDir/text_send/）：
    // 写入与「清除任务历史」的清空共用同一路径来源（见 SendRepository.sendTextDir）；
    // 未发起发送的文本在移出暂存/清空暂存时仍按既有规则删除（见 deleteStagedTextFile）
    let sendDir: string = sendTextDir();
    if (sendDir.length === 0) {
      return;
    }
    try {
      fs.mkdirSync(sendDir);
    } catch (_e) {
    }
    let fileName: string = prefix + Date.now() + '.txt';
    let filePath: string = sendDir + fileName;
    // 同毫秒内多次暂存会命中同一文件名（后写覆盖先写造成内容串扰），冲突时追加序号改名
    if (fs.accessSync(filePath, fs.AccessModeType.EXIST)) {
      let seq: number = 1;
      do {
        fileName = prefix + Date.now() + '_' + seq + '.txt';
        filePath = sendDir + fileName;
        seq++;
      } while (fs.accessSync(filePath, fs.AccessModeType.EXIST));
    }
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
    // 暂存列表新增条目后，既有预准备结果不再对应当前内容，须失效，
    // 否则下次发送会复用旧条目（内容静默丢失）
    invalidatePrePreparedItems();
    this.updateTotalSizeCache();
  }

  // 编辑文本消息：覆盖写原文件（WRITE_ONLY | CREATE | TRUNC），不改变条目身份与持久化语义——
  // uri/fileName/fileType/isManualText/persisted 等字段全部保持不变，仅更新文件承载的文本内容；
  // 已随某次发送发起的条目（persisted）编辑后其底层文件仍不随暂存列表清理删除。
  // 内容变化后使预准备结果失效，并删除该条目的大小缓存、刷新暂存总大小统计。
  updateStagedTextFile(index: number, newText: string): void {
    let staged: StagedFile | undefined = this.stagedFiles[index];
    if (staged === undefined || staged.isManualText !== true) {
      return;
    }
    try {
      let file: fs.File = fs.openSync(staged.uri,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, newText);
      } finally {
        fs.closeSync(file);
      }
    } catch (_e) {
      return;
    }
    // 文件内容已变化：既有预准备结果不再对应当前内容，须失效（与 stageTextFile 的失效时机一致）
    invalidatePrePreparedItems();
    // 该条目字节大小已随内容变化，删除 stat 缓存项，总大小经 statSync 重新计算
    this.stagedSizeCache.delete(staged.uri);
    this.updateTotalSizeCache();
  }

  // 手动文本暂存项的 uri 指向 text_send/ 下的自建文件，移出/清空暂存列表时
  // 同步删除底层文件；但已随发送发起的条目（persisted）其文件是发送产物的本地副本，
  // 不随暂存列表清理删除。picker URI 非本应用所有，不处理；文件已不存在时静默忽略。
  private deleteStagedTextFile(staged: StagedFile): void {
    if (staged.isManualText !== true || staged.persisted === true) {
      return;
    }
    try {
      fs.unlinkSync(staged.uri);
    } catch (_e) {
    }
  }

  /** 标记手输文本条目为「已发起发送」：其落盘文件此后不随暂存列表清理删除。 */
  private markManualTextPersisted(): void {
    for (let i = 0; i < this.stagedFiles.length; i++) {
      if (this.stagedFiles[i].isManualText === true) {
        this.stagedFiles[i].persisted = true;
      }
    }
  }

  removeStagedFile(index: number): void {
    let removed: StagedFile | undefined = this.stagedFiles[index];
    if (removed !== undefined) {
      this.deleteStagedTextFile(removed);
      this.stagedSizeCache.delete(removed.uri);
      // 释放缩略图请求标记：同一文件再次被选中时（URI 稳定）需重新生成缩略图
      this.videoPreviewRequestedUris.delete(removed.uri);
    }
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
    }
    this.updateTotalSizeCache();
  }

  // 视频暂存项的缩略图懒加载（fire-and-forget）。
  // 生成成功后重建数组携带新的 item（含缩略图），配合列表 key 含就绪标记实现界面刷新；
  // 文件不可用/解码失败时静默回退类型图标。
  // 由竖向列表条目的 onAppear 触发；缩略图未就绪的条目先显示视频类型图标。
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
      logger.warn('生成失败，回退类型图标 uri=' + src.uri);
      return;
    }
    // await 期间暂存列表可能已被删除/清空（条目前移），按 uri 重新定位
    // 目标条目，避免按过期 index 写回造成缩略图错位
    let currentIndex: number = -1;
    let updated: Array<StagedFile> = this.stagedFiles.slice();
    for (let i = 0; i < updated.length; i++) {
      if (updated[i].uri === src.uri) {
        currentIndex = i;
        break;
      }
    }
    if (currentIndex < 0) {
      return;
    }
    let copy: StagedFile = {
      uri: src.uri,
      fileName: src.fileName,
      fileType: src.fileType,
      isImage: src.isImage,
      isManualText: src.isManualText,
      // 透传持久化/源修改时间标记：重建条目不得丢失（发送元数据依赖）
      persisted: src.persisted,
      lastModified: src.lastModified,
      previewPixelMap: pixelMap
    };
    updated[currentIndex] = copy;
    this.stagedFiles = updated;
  }

  clearStagedFiles(): void {
    for (let i = 0; i < this.stagedFiles.length; i++) {
      this.deleteStagedTextFile(this.stagedFiles[i]);
    }
    this.stagedFiles = [];
    this.stagedSizeCache.clear();
    this.videoPreviewRequestedUris.clear();
    invalidatePrePreparedItems();
    clearAllSendSessions();
    this.cachedTotalSizeText = '';
  }

  updateTotalSizeCache(): void {
    let totalBytes = this.computeStagedTotalSize();
    this.cachedTotalSizeText = totalBytes === 0 ? '' : formatSizeDetailed(totalBytes);
  }

  getTotalSizeText(): string {
    return this.cachedTotalSizeText;
  }

  // 触发一轮 LocalSend 发现扫描（MTA 扫描由调用方另行触发，避免重复发起）
  rescanDevices(): void {
    rescanDevices();
  }

  // 触发一轮 MTA 发现扫描（与 LocalSend 发现同一触发时机，不依赖服务器就绪）
  rescanMtaDevices(): void {
    rescanMtaDiscovery();
  }

  // 构建 MTA 发送页面参数（复用暂存文件；无可发送内容时返回 undefined）
  buildMtaSendParams(device: DiscoveredDevice): MtaSendRequest | undefined {
    if (this.stagedFiles.length === 0) {
      return undefined;
    }
    // 文本发送：全部暂存项均为手动文本时以 MTA 原生文本方式发送
    // 判定由共享纯函数提供，不再自行遍历暂存项构建布尔数组
    if (isAllManualText(this.stagedFiles)) {
      let contents: Array<string> = [];
      for (let i = 0; i < this.stagedFiles.length; i++) {
        try {
          contents.push(fs.readTextSync(this.stagedFiles[i].uri));
        } catch (_e) {
        }
      }
      let textContent = combineTextContents(contents);
      if (textContent.length === 0) {
        return undefined;
      }
      let request = buildMtaSendRequest(device, [], [], true, textContent);
      // 单一手输文本：携带其持久文件路径，供详情页按路径读取内容预览
      // （多个手输文本合并为一条协议文本，无单一文件与之对应，故不携带路径）
      if (this.stagedFiles.length === 1) {
        request.textFilePath = this.stagedFiles[0].uri;
      }
      return request;
    }
    let uris: Array<string> = [];
    let descriptors: Array<TransferFileDescriptor> = [];
    for (let i = 0; i < this.stagedFiles.length; i++) {
      let staged = this.stagedFiles[i];
      uris.push(staged.uri);
      let size: number = 0;
      try {
        size = fs.statSync(staged.uri).size;
      } catch (_e) {
      }
      descriptors.push({
        fileId: '',
        fileName: staged.fileName,
        size: size,
        fileType: staged.fileType
      });
    }
    return buildMtaSendRequest(device, uris, descriptors, false, '');
  }

  /** 是否存在进行中的 MTA 发送（发送页「设备忙」反馈，判定取自注册表与收发互斥计数）。 */
  isMtaSendBusy(): boolean {
    return isMtaSendSessionActive();
  }

  /** 发起 MTA 发送：编排（服务生命周期/收发互斥/注册表登记）由 MTA 发送适配器承接。 */
  startMtaSend(params: MtaSendRequest): void {
    let context = this.context;
    if (context === undefined) {
      return;
    }
    markMtaSendClicked();
    startMtaSendFlow(params, context).catch((e: Object): void => {
      logger.warn('MTA 发送启动失败: ' + String(e));
    });
  }

  // 返回要导航到的分享链接 URL；未创建链接时返回 ''
  // （选择器被取消或失败）。
  // 网页分享是一次性动作，不改变发送模式值。
  async shareByLink(): Promise<string> {
    // LocalSend 总开关关闭时不创建分享链接（菜单入口已置灰，此处为防御纵深）
    if (!this.localSendEnabled) {
      logger.warn('LocalSend 已禁用，忽略网页分享请求');
      return '';
    }
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
      // 手动文本条目的源定位经共享筛选纯函数产出，随 uris 一并交由共享准备层
      // 统一补设文本内容信息，网页分享不再单独维护筛选与补设循环
      let manualTextUris: Array<string> = collectManualTextUris(this.stagedFiles);
      let items: Array<SendFileItem> = await prepareSendFiles(uris, manualTextUris);
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

  // 点击设备即发送（无单/多目标模式差异）：发送后停留发送页，进度经任务/详情页呈现。
  // 目标是否已有活跃发送取自统一会话注册表，另以在途 IP 集合弥补「点击→会话创建」的空窗；
  // 不再维护以 IP 为键的发送状态/进度/错误映射。
  // 返回明确发起结果：被拦截不再静默返回，由视图层据结果给出可见提示。
  async sendToMultipleDeviceInline(device: DiscoveredDevice): Promise<SendInitiateResult> {
    // 已有缓存的预准备文件（已含校验和）即视为有内容；否则以暂存内容为准
    let cached: Array<SendFileItem> | undefined = peekPrePreparedItems();
    let hasContent: boolean = (cached !== undefined && cached.length > 0) || this.stagedFiles.length > 0;
    // 该目标已有非终态发送会话或在途即拒绝重复点击；在途集合弥补「点击→会话创建」之间的空窗
    let result: SendInitiateResult = decideSendInitiateResult(this.inFlightSendIps.has(device.ip),
      this.hasActiveSendTo(device.ip), hasContent);
    if (result !== SendInitiateResult.initiated) {
      return result;
    }
    // 本次发送已发起：手输文本的持久文件此后不随暂存列表清理而删除
    this.markManualTextPersisted();
    this.inFlightSendIps.add(device.ip);
    try {
      // 复用缓存的预准备文件（已含校验和），避免每点一台设备就重新 prepare + checksum
      let items: Array<SendFileItem> | undefined = cached;
      if (items === undefined || items.length === 0) {
        // 首次点击：准备文件 + 计算校验和，缓存供后续设备复用
        items = await this.prepareAndCacheItems();
        if (items.length === 0) {
          return SendInitiateResult.noContent;
        }
      }
      // 发送前该目标已有会话标识：用于识别本次新建的会话
      let beforeIds: Array<string> = this.sendSessionIdsForIp(device.ip);
      // 使用 sendToDeviceMulti 发送单设备——它会创建会话并驱动进度（点击即发送，无模式差异）
      await sendToDeviceMulti([device], items);
      // 暂存内容默认保留以支持连续发送；仅在「发送成功后自动清空暂存」开启且本次成功时清空
      if (isAutoClearStagedAfterSend() && this.hasNewSucceededSendTo(device.ip, beforeIds)) {
        this.clearStagedFiles();
        invalidatePrePreparedItems();
      }
      return SendInitiateResult.initiated;
    } finally {
      this.inFlightSendIps.delete(device.ip);
    }
  }

  /**
   * 收藏设备发送编排：在线（发现快照命中）直接发送；离线按已保存地址与端口定向探测，
   * 探测成功后再发送。返回结果枚举供视图层给出提示。
   */
  async sendToFavorite(favorite: FavoriteDevice): Promise<FavoriteSendResult> {
    // LocalSend 总开关关闭时不允许发送（入口已置灰，此处为防御纵深）
    if (!this.localSendEnabled) {
      return FavoriteSendResult.disabled;
    }
    let device: DiscoveredDevice | undefined = undefined;
    for (let i = 0; i < this.discoveredDevices.length; i++) {
      if (this.discoveredDevices[i].fingerprint === favorite.fingerprint) {
        device = this.discoveredDevices[i];
        break;
      }
    }
    // 离线：按保存地址定向探测（端口缺失时回退当前服务端口）
    if (device === undefined) {
      let port: number = favorite.port > 0 ? favorite.port : getPort();
      let probed: DiscoveredDevice | undefined = await connectByIp(favorite.ip, port);
      if (probed === undefined) {
        return FavoriteSendResult.probeFailed;
      }
      device = probed;
    }
    let result: SendInitiateResult = await this.sendToMultipleDeviceInline(device);
    if (result === SendInitiateResult.blocked) {
      return FavoriteSendResult.busy;
    }
    if (result === SendInitiateResult.noContent) {
      return FavoriteSendResult.noContent;
    }
    return FavoriteSendResult.initiated;
  }

  /** 该目标是否存在进行中的发送会话（点击去重判定，来源＝统一会话注册表）。 */
  private hasActiveSendTo(ip: string): boolean {
    let filter: SessionFilter = { protocolKey: LOCAL_SEND_KEY };
    let sessions: Array<TransferSession> = querySessions(filter);
    for (let i = 0; i < sessions.length; i++) {
      let session = sessions[i];
      if (session.peer.ip === ip && !isTerminalStage(session.stage)) {
        return true;
      }
    }
    return false;
  }

  /** 该目标当前在注册表中的发送会话标识集合（发送前快照）。 */
  private sendSessionIdsForIp(ip: string): Array<string> {
    let filter: SessionFilter = { protocolKey: LOCAL_SEND_KEY };
    let sessions: Array<TransferSession> = querySessions(filter);
    let ids: Array<string> = [];
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].peer.ip === ip) {
        ids.push(sessions[i].id);
      }
    }
    return ids;
  }

  /** 本次发送是否成功（该目标新出现的成功终态会话）。 */
  private hasNewSucceededSendTo(ip: string, beforeIds: Array<string>): boolean {
    let filter: SessionFilter = { protocolKey: LOCAL_SEND_KEY };
    let sessions: Array<TransferSession> = querySessions(filter);
    for (let i = 0; i < sessions.length; i++) {
      let session = sessions[i];
      if (session.peer.ip === ip && session.stage === SessionStage.succeeded &&
        beforeIds.indexOf(session.id) < 0) {
        return true;
      }
    }
    return false;
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

  startServer(): Promise<string | void> {
    return startServer();
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

  // ── 私有辅助：选择/统计/prepare 收敛 ──

  // 将选择器返回的 uri 列表去重后暂存为 StagedFile 并刷新总大小缓存；
  // 确有条目新增时使既有预准备结果失效（未新增则保持复用）。
  // forceImage: true=强制标记为图片（图片选择器）；false=强制非图片（音频/视频/压缩包）；
  // undefined=按扩展名判断（通用/文档选择器）。
  private stageUris(uris: Array<string>, forceImage: boolean | undefined): void {
    let addedCount: number = 0;
    for (let i = 0; i < uris.length; i++) {
      let uri = uris[i];
      if (this.isAlreadyStaged(uri)) {
        continue;
      }
      let name = this.extractFileNameFromUri(uri);
      let ext = this.getExtension(name);
      let isImg: boolean = forceImage !== undefined ? forceImage : isImageExtension(ext);
      let mime = mimeGetMimeForExt(ext);
      // 暂存前捕获源文件修改时间：后续若发生字节复制会把副本时间置为当前时刻，
      // 必须在此刻取原值才能保真。fs.Stat.mtime 为距 1970 的秒数，统一转为 Unix 毫秒
      let lastModified: number | undefined = undefined;
      try {
        lastModified = Math.floor(fs.statSync(uri).mtime * 1000);
      } catch (_e) {
        lastModified = undefined;
      }
      let staged: StagedFile = {
        uri: uri,
        fileName: name,
        fileType: mime,
        isImage: isImg,
        lastModified: lastModified
      };
      this.stagedFiles.push(staged);
      addedCount++;
    }
    // 仅在有实际新增时失效：暂存内容未变化时保持复用既有准备结果
    // （多目标模式连续向多台设备发送依赖该复用，不得每次无条件重新准备）
    if (addedCount > 0) {
      invalidatePrePreparedItems();
    }
    this.updateTotalSizeCache();
  }

  // 计算所有暂存文件的总字节数（stat 失败的文件跳过）。
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

  // 准备暂存文件（prepareSendFiles + 计算校验和）并缓存预准备结果，供发送链路复用。
  // 手动文本条目的 preview 补设随 uris 一并交由共享准备层统一完成。
  // 返回准备结果；无文件/失败时返回空数组。
  private async prepareAndCacheItems(): Promise<Array<SendFileItem>> {
    let uris: Array<string> = [];
    for (let i = 0; i < this.stagedFiles.length; i++) {
      uris.push(this.stagedFiles[i].uri);
    }
    // await 前的暂存指纹：准备期间用户增删暂存会使 await 前后指纹不一致
    let fingerprintBefore: string = uris.join('\n');
    // 手动文本条目的源定位经共享筛选纯函数产出，随 uris 一并传入共享准备层，
    // 由 prepareSendFiles 统一补设 preview（单目标、多目标、指定 IP 共用此路径）
    let manualTextUris: Array<string> = collectManualTextUris(this.stagedFiles);
    let items: Array<SendFileItem> = await prepareSendFiles(uris, manualTextUris);
    if (items.length === 0) {
      return items;
    }
    // 回填源修改时间：按源 URI 匹配（prepareSendFiles 可能跳过失败项，索引不保证对齐）
    let modifiedByUri: Record<string, number> = {};
    for (let i = 0; i < this.stagedFiles.length; i++) {
      let m = this.stagedFiles[i].lastModified;
      if (m !== undefined) {
        modifiedByUri[this.stagedFiles[i].uri] = m;
      }
    }
    for (let i = 0; i < items.length; i++) {
      let m = modifiedByUri[items[i].filePath];
      if (m !== undefined) {
        items[i].lastModified = m;
      }
    }
    // 计算校验和（若设置开启，跳过已有 hash 的文件）
    await calculateChecksumsForFiles(items);
    // 暂存指纹未变才缓存预准备结果：await 期间暂存被增删/清空时跳过缓存，
    // 避免旧快照污染后续点击发送（本次仍按点击时刻的内容发送）
    let fingerprintAfter: string = '';
    for (let i = 0; i < this.stagedFiles.length; i++) {
      if (i > 0) {
        fingerprintAfter += '\n';
      }
      fingerprintAfter += this.stagedFiles[i].uri;
    }
    if (fingerprintAfter === fingerprintBefore) {
      setPrePreparedItems(items);
    }
    return items;
  }
}
