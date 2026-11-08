import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';
import {
  verifyNativeVersion,
  getNativeLibraryVersion,
  onBridgeEvent,
  nativeGetSecurityContext,
  nativeResetSecurityContext,
  nativeInitWithPersistedIdentity
} from './NativeBridge';
import {
  NativeEvent,
  NativeDeviceFoundEvent,
  NativeRegisterEvent,
  NativePrepareUploadEvent,
  NativeSessionEndEvent,
  NativeCancelReceivedEvent,
  NativePrepareUploadAbortedEvent,
  NativeProgressEvent,
  NativeChecksumProgressEvent,
  NativeWebAccessEvent,
  NativeWebDownloadStartedEvent,
  NativeWebDownloadProgressEvent,
  NativeWebDownloadFileDoneEvent,
  NativeWebDownloadEndedEvent,
  NativeWebSendSessionEndEvent,
  NativeWebUploadPrepareEvent,
  NativeWebUploadProgressEvent,
  NativeWebUploadDoneEvent,
  NativeErrorEvent,
  NativeSecurityContext
} from '../model/NativeTypes';
import { ReceiveHistoryEntry, SendSessionState } from '../model/Types';
import { getHistory } from './repository/ReceiveHistoryService';
import { getSendSessions, isTerminalSendStatus } from './repository/SendRepository';
import { getLogger, initLogger, registerAddLog } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { initBackgroundAttentionNotifier } from './BackgroundAttentionNotifier';

// ── 仓库导入（门面编排） ──
import { setAppContext, addLog, triggerRefresh } from './repository/AppCore';
import { activateConfiguredReceiveDirectory } from './repository/ReceiveDirectory';
import {
  loadFromPreferences,
  getTheme,
  getLocale,
  applyThemeToApp,
  applyLocaleToApp,
  getWebHttpsEnabled
} from './repository/SettingsRepository';
import { initDeviceIdentity, getDeviceAlias, getDeviceType } from './repository/DeviceRepository';
import {
  startLocalServer as serverStartLocal,
  stopLocalServer as serverStopLocal,
  refreshWifiWarning,
  isServerRunning,
  restartServer,
  restartDiscovery,
  getReceiveSaveDir
} from './repository/ServerRepository';
import {
  startRequestPolling,
  stopRequestPolling,
  hasActiveTransfers,
  handlePrepareUploadEventTyped,
  handleSessionEndEventTyped,
  handleCancelReceivedEventTyped,
  handlePrepareUploadAbortedEventTyped,
  handleProgressUpdateTyped
} from './repository/ReceiveRepository';
import { handleDeviceFound, handleRegisterEventTyped } from './repository/DiscoveryRepository';
import { handleChecksumProgress } from './repository/ChecksumRepository';
import {
  handleWebAccessTyped,
  handleWebDownloadStartedTyped,
  handleWebDownloadProgressTyped,
  handleWebDownloadFileDoneTyped,
  handleWebDownloadEndedTyped,
  handlePrepareUploadTyped,
  handleWebUploadProgressTyped,
  handleWebUploadDoneTyped,
  handleWebUploadFinished,
  refreshWebAddress,
  getWebActualPort,
  restartWebService,
  hasActiveWebDownloads,
  hasActiveWebUploads } from './repository/WebShareRepository';
import { noteWebAccess } from './BackgroundTransferService';

// ── 协议适配器模块导入（触发模块级自注册；ArkTS 无副作用导入，故引用其键常量） ──
import { LOCAL_SEND_KEY } from './transfer/adapters/LocalSendSendAdapter';
import { LOCAL_RECEIVE_KEY } from './transfer/adapters/LocalSendReceiveAdapter';
import { MTA_SEND_KEY } from './transfer/adapters/MtaSendAdapter';
import { MTA_RECEIVE_KEY } from './transfer/adapters/MtaReceiveAdapter';
import { WEB_DOWNLOAD_KEY } from './transfer/adapters/WebDownloadAdapter';
import { initializeAdapters } from './transfer/adapters/SessionAdapter';
import { registerProtocolDefaults } from './transfer/DefaultRegistrations';
import { notifyChange } from './repository/AppCore';
import { recoverSessionDrafts } from './transfer/SessionRecoveryService';
import { sweepReceiveTempWorkspacesOnInit } from './transfer/TempWorkspaceSweep';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:AppService', '应用');

// 进程级初始化标志：initAppService 由页面 aboutToAppear 调用，进程存活
// 而 Ability 重建（windowStage 重新加载页面）时会再次执行，模块级状态
// 只能初始化一次（事件订阅为追加式、网络监听无法注销）
let appServiceInitialized: boolean = false;
// 网络变化监听实例：进程全程存活，仅作持有以便观测/排查，无注销时机
let netConnection: connection.NetConnection | null = null;

/**
 * 每次 Ability 初始化都尝试恢复会话草稿。
 * 强杀/划掉 Ability 不一定会结束进程：进程存活时 Ability 重建会走 initAppService 早退分支，
 * 只在首次初始化时恢复会漏掉这类“任务刚发起就退出”的场景。恢复服务会跳过仍活跃的会话。
 * 同步执行，保证任务列表首次构建前历史已补写；草稿数量很少，IO 可接受。
 */
function recoverSessionDraftsOnInit(): void {
  try {
    // 先清扫接收临时区：同步部分在首次 await 前完成，覆盖草稿涉及的目录与
    // 旧版遗留目录；接收目录解析完成后补扫无草稿可推导的残留。
    sweepReceiveTempWorkspacesOnInit().catch((e: Error) => {
      logger.warn('清扫接收临时区失败：' + e.message);
    });
    let recovered = recoverSessionDrafts();
    logger.debug('会话草稿恢复：草稿=' + recovered.drafts + ' 成功=' + recovered.recovered +
      ' 失败=' + recovered.failed);
    if (recovered.recovered > 0) {
      notifyChange();
    }
  } catch (e) {
    logger.warn('会话草稿恢复失败：' + String(e));
  }
}

// ════════════════════════════════════════════════════════════
// 门面层再导出（业务逻辑位于 repository/*）
// ════════════════════════════════════════════════════════════

// AppCore —— 共享运行时
export { getLogs,
  clearLogs,
  addLog,
  subscribeLogs,
  unsubscribeLogs,
  subscribe,
  unsubscribe,
  notifyChange,
  triggerRefresh,
  getAppContext,
  getLocalInterfaces,
  updateLocalInterfaces,
  saveLogsToFile } from './repository/AppCore';

// 设置仓储导出
export { setHttpsEnabled,
  getHttpsEnabled,
  getEncryptedTransfer,
  setAutoConfirmMode,
  getAutoConfirmMode,
  getReceivePin,
  setReceivePin,
  setSaveToGallery,
  isSaveToGallery,
  getReceiveDirectoryUri,
  setReceiveDirectoryUri,
  setBackgroundReceiveEnabled,
  isBackgroundReceiveEnabled,
  setDestination,
  getDestination,
  setCustomAlias,
  getCustomAlias,
  setTheme,
  getTheme,
  setLocale,
  getLocale,
  setHideTabBarOnScroll,
  isHideTabBarOnScroll,
  setCreateChecksums,
  isCreateChecksums,
  setVerifyChecksums,
  isVerifyChecksums,
  setAutoClearStagedAfterSend,
  isAutoClearStagedAfterSend,
  setAdvancedSettings,
  isAdvancedSettings,
  setPort,
  getPort,
  setMulticastGroup,
  getMulticastGroup,
  setDiscoveryTimeout,
  getDiscoveryTimeout,
  setNetworkWhitelist,
  getNetworkWhitelist,
  setNetworkBlacklist,
  getNetworkBlacklist,
  doesServerNeedRestart,
  clearServerNeedsRestart,
  getLocalSendEnabled,
  setLocalSendEnabled,
  getMtaEnabled,
  setMtaEnabled,
  getWebSendAllowed,
  setWebSendAllowed,
  getWebReceiveAllowed,
  setWebReceiveAllowed,
  getWebHttpsEnabled,
  setWebHttpsEnabled,
  getWebPort,
  setWebPort,
  getWebInterfaceNames,
  getWebInterfaceBlacklistNames,
  setWebInterfaces,
  getWebDisplayAddress,
  setWebDisplayAddress,
  getMtaReceiveEnabled,
  setMtaReceiveEnabled,
  getMtaSimulatedBrand,
  setMtaSimulatedBrand,
  isMtaConnectionWarnings,
  setMtaConnectionWarnings } from './repository/SettingsRepository';

// 设备仓储导出
export { getDeviceAlias,
  getDeviceType,
  getDeviceModel,
  getLocalDeviceInfo,
  refreshDeviceInfo } from './repository/DeviceRepository';

// 服务端仓储导出
export { isServerRunning,
  getNoWifiWarning,
  getAllInterfacesDisabled,
  getServerFingerprint,
  refreshWifiWarning,
  startServer,
  stopServer,
  restartServer,
  restartDiscovery,
  cleanupReceiveCacheDirWithContext } from './repository/ServerRepository';

// 发现仓储导出
export { getDiscoveredDevices,
  getMulticastError,
  rescanDevices,
  isScanningStatus,
  connectByIp } from './repository/DiscoveryRepository';

// WebShareRepository（下方 re-export 仅供外部消费，内部使用走文件顶部 import）
export { getShareLink,
  createShareLink,
  stopShareLink,
  startWebUpload,
  ensureWebUpload,
  updateShareFiles,
  unmountShare,
  isShareActive,
  isSharingPath,
  disableWebUpload,
  setWebUploadAutoAccept,
  isWebUploadAutoAccept,
  getWebAccessCode,
  hasSharedFiles,
  getSharedFileCount,
  isWebUploadEnabled,
  applyWebSendAllowed,
  applyWebReceiveAllowed,
  restoreWebService,
  getWebAddresses,
  getSelectedWebAddress,
  selectWebDisplayAddress,
  refreshWebAddress,
  getWebActualPort,
  isWebPortFallback,
  restartWebService,
  hasActiveWebDownloads,
  hasActiveWebUploads } from './repository/WebShareRepository';

// 校验和仓储导出
export { calculateChecksumsForFiles,
  handleChecksumProgress } from './repository/ChecksumRepository';

// 发送仓储导出
export { sendResultErrorMessage,
  sendToDevice,
  sendToDeviceMulti,
  sendToDeviceWithNewSession,
  resolveSendProtocol,
  prepareSendFiles,
  cleanupSendDirWithContext,
  processSharedUris,
  getSendSessions,
  createSendSession,
  clearAllSendSessions,
  setPendingSharedUris,
  consumePendingSharedUris,
  setPendingSharedTexts,
  consumePendingSharedTexts,
  setPrePreparedItems,
  peekPrePreparedItems,
  invalidatePrePreparedItems,
  sendTextDir } from './repository/SendRepository';

export type { SendResult } from './repository/SendRepository';

// 接收仓储导出
export { getPendingRequests,
  respondToRequest,
  shouldAutoAccept,
  peekRecvCompleted,
  consumeRecvMediaFiles,
  getPendingRecvMediaPaths } from './repository/ReceiveRepository';

// 相册保存服务导出
export { saveMediaToGallery } from './GallerySaveService';

// NativeBridge（传输取消/会话相关）
export { nativeCancelTransfer,
  nativeCancelTransferLocal,
  nativeCancelLocalSession,
  nativeGetCurrentSendSessionId,
  nativeStartWebService,
  nativeStopWebService,
  nativeUpdateWebServiceFiles,
  nativeSetWebServiceUploadEnabled,
  nativeSetWebUploadTargets,
  nativeAcceptWebSession,
  nativeDeclineWebSession,
  nativeExpireWebSession } from './NativeBridge';

// 接收历史服务导出
export { updateGallerySavedStatus } from './repository/ReceiveHistoryService';

// MtaRepository —— 应用级 MTA 运行时（发现扫描 / 接收服务 / 收发互斥 / 命令门面）
export { startMtaDiscoveryScan,
  rescanMtaDiscovery,
  isMtaManualRefreshInFlight,
  stopMtaDiscoveryScan,
  markMtaSendClicked,
  getMtaSendClickedMs,
  getMtaDiscoveredDevices,
  getMtaBluetoothStatus,
  isMtaWifiOn,
  startMtaReceiveIfEnabled,
  applyMtaEnabled,
  applyMtaReceiveEnabled,
  stopMtaReceive,
  isMtaSendActive,
  suspendMtaReceiveForSend,
  resumeMtaReceiveAfterSend,
  acceptMtaReceiveRequest,
  acceptMtaReceiveText,
  rejectMtaReceiveRequest,
  cancelMtaReceive,
  getMtaReceiveSnapshot,
  getLocalMtaDeviceIdHex,
  applyMtaSimulatedBrand } from './repository/MtaRepository';

// MTA 接收预览缩略图缓存清理（冷启动）
export { cleanupMtaThumbnailDirWithContext } from './mta/MtaReceiveService';

// MTA 广播名称口径（与广播编码同源）
export { mtaBroadcastName } from './mta/MtaBleCommon';

// ── 历史记录 / 收藏（薄适配器） ──

export function getReceiveHistory(): Array<ReceiveHistoryEntry> {
  return getHistory();
}

// ── 统一会话引擎（会话注册表 / 任务历史 / 三类注册表 / 适配器） ──

// 会话注册表（唯一事实源）
export { createSession,
  appendFiles,
  updateFileProgress,
  setStage,
  confirmSession,
  declineSession,
  finish,
  cancel,
  retry,
  getSession,
  findByProtocol,
  querySessions,
  getAllSessions,
  getActiveCount,
  getPendingCount,
  getOverallSnapshot,
  subscribeSessions,
  unsubscribeSessions,
  getHistory,
  getHistoryRevision,
  clearHistory,
  getSessionCapabilities,
  resetRegistry } from './transfer/TransferSessionRegistry';

// 任务历史存储（抽象接口 + Preferences 实现）
export { getSessionHistory,
  clearSessionHistory,
  resetSessionHistoryCache,
  buildHistoryEntry } from './transfer/SessionHistoryStore';

// 设备来源 / 传输方式 / 设置分组注册表
export { registerSource, getSource, listSources, filterEnabledDeviceSources } from './transfer/DeviceSourceRegistry';

export { registerMethod, getMethod, listMethods, listMethodsByGroup } from './transfer/TransferMethodRegistry';

export { registerSettingsGroup, listSettingsGroups } from './transfer/SettingsGroupRegistry';

// 协议适配器契约与注册表
export { registerAdapter, getAdapter } from './transfer/adapters/SessionAdapter';

export type { SessionAdapter } from './transfer/adapters/SessionAdapter';

/**
 * 初始化统一会话引擎：建立协议适配器的事件订阅。
 * 幂等性由各适配器自行保证。
 */
function initSessionEngine(): void {
  // 引用各适配器键，确保适配器模块已被加载并完成自注册
  logger.debug('协议适配器已注册：' + LOCAL_SEND_KEY + ', ' + LOCAL_RECEIVE_KEY + ', ' +
    MTA_SEND_KEY + ', ' + MTA_RECEIVE_KEY + ', ' + WEB_DOWNLOAD_KEY);
  // 注册协议默认描述符（设备来源 / 传输方式 / 设置分组）
  registerProtocolDefaults();
  initializeAdapters();
}

// ════════════════════════════════════════════════════════════
// 生命周期编排（整合各仓库的关注点）
// ════════════════════════════════════════════════════════════

/**
 * 网络接口变化后的统一刷新：重枚举网卡，更新局域网警告与网页可展示地址。
 * 系统网络事件覆盖不到热点（SoftAP 不产生连接网络事件），
 * 由热点状态监听与页面进入时主动调用来补齐。
 */
export function refreshWebNetwork(): void {
  // 先重枚举缓存，警告与地址都基于同一份最新接口列表
  refreshWifiWarning();
  refreshWebAddress();
}

export function initAppService(context: common.UIAbilityContext): void {
  if (appServiceInitialized) {
    // Ability 重建时 context 实例会变化，仍需刷新以免后续操作使用失效上下文；
    // 其余模块级状态（日志/事件订阅/原生身份/网络监听）进程内只初始化一次
    setAppContext(context);
    logger.debug('应用服务初始化已跳过：已初始化');
    // 进程可能仍存活而 Ability 已重建：再次尝试恢复上次退出时留下的草稿。
    recoverSessionDraftsOnInit();
    return;
  }
  appServiceInitialized = true;

  // 先注册 addLog 回调（打破 Logger → AppCore 的循环依赖）
  registerAddLog(addLog);

  // 初始化日志系统：优先使用用户持久化选择，未保存过时使用构建默认级别
  initLogger();

  // 启动时校验原生库版本
  try {
    verifyNativeVersion();
    logger.debug('原生库版本：' + getNativeLibraryVersion());
  } catch (e) {
    logger.warn('原生版本检查失败：' + e);
    // 继续执行——版本不匹配按可恢复降级处理，不是致命错误
  }

  // 注册桥接层类型化事件订阅（发现、服务器、Web 分享事件按类型分发）
  try {
    onBridgeEvent('deviceFound', (e: NativeEvent) => {
      handleDeviceFound(e as NativeDeviceFoundEvent);
    });
    onBridgeEvent('register', (e: NativeEvent) => {
      handleRegisterEventTyped(e as NativeRegisterEvent);
    });
    onBridgeEvent('prepareUpload', (e: NativeEvent) => {
      handlePrepareUploadEventTyped(e as NativePrepareUploadEvent);
    });
    onBridgeEvent('sessionEnd', (e: NativeEvent) => {
      handleSessionEndEventTyped(e as NativeSessionEndEvent);
    });
    onBridgeEvent('cancelReceived', (e: NativeEvent) => {
      handleCancelReceivedEventTyped(e as NativeCancelReceivedEvent);
    });
    onBridgeEvent('uploadProgress', (e: NativeEvent) => {
      handleProgressUpdateTyped(e as NativeProgressEvent);
    });
    onBridgeEvent('checksumProgress', (e: NativeEvent) => {
      // 校验和计算进度：汇聚为字节进度写回发送会话（准备态）
      let ev = e as NativeChecksumProgressEvent;
      handleChecksumProgress(ev.cancelId, ev.hashedBytes);
    });
    onBridgeEvent('prepareUploadAborted', (e: NativeEvent) => {
      // 发送方在我们确认前丢弃了 prepare-upload 请求——
      // 将其作为取消事件呈现，使传输页作出反应。
      handlePrepareUploadAbortedEventTyped(e as NativePrepareUploadAbortedEvent);
    });
    onBridgeEvent('webAccess', (e: NativeEvent) => {
      let access = e as NativeWebAccessEvent;
      handleWebAccessTyped(access);
      noteWebAccess();
    });
    onBridgeEvent('webDownloadStarted', (e: NativeEvent) => {
      handleWebDownloadStartedTyped(e as NativeWebDownloadStartedEvent);
    });
    onBridgeEvent('webDownloadProgress', (e: NativeEvent) => {
      handleWebDownloadProgressTyped(e as NativeWebDownloadProgressEvent);
    });
    onBridgeEvent('webDownloadFileDone', (e: NativeEvent) => {
      handleWebDownloadFileDoneTyped(e as NativeWebDownloadFileDoneEvent);
    });
    onBridgeEvent('webDownloadEnded', (e: NativeEvent) => {
      handleWebDownloadEndedTyped(e as NativeWebDownloadEndedEvent);
    });
    onBridgeEvent('webSendSessionEnd', (e: NativeEvent) => {
      // 仅上传会话使用；下载已改用 webDownloadEnded
      handleWebUploadFinished((e as NativeWebSendSessionEndEvent).sessionId);
    });
    onBridgeEvent('webUploadPrepare', (e: NativeEvent) => {
      handlePrepareUploadTyped(e as NativeWebUploadPrepareEvent);
    });
    onBridgeEvent('webUploadProgress', (e: NativeEvent) => {
      handleWebUploadProgressTyped(e as NativeWebUploadProgressEvent);
    });
    onBridgeEvent('webUploadDone', (e: NativeEvent) => {
      handleWebUploadDoneTyped(e as NativeWebUploadDoneEvent);
    });
    onBridgeEvent('error', (e: NativeEvent) => {
      // 原生错误事件纳入发送失败诊断，不只依赖调用返回值
      handleNativeErrorEventTyped(e as NativeErrorEvent);
    });
    logger.debug('原生桥接事件已订阅');
  } catch (e) {
    logger.error('订阅原生桥接事件失败：' + JSON.stringify(e));
  }

  setAppContext(context);
  loadFromPreferences();
  initDeviceIdentity();

  // 启动时激活自定义接收目录的持久授权：接收历史/详情页按路径读取文件时需要
  activateConfiguredReceiveDirectory().catch((e: Error) => {
    logger.warn('激活接收目录授权失败：' + String(e));
  });

  // 初始化统一会话引擎（协议适配器事件订阅；适配器在文件头部导入以完成注册）
  try {
    initSessionEngine();
    // 后台关注通知按注册表待确认会话与网页访问状态发布/撤回
    initBackgroundAttentionNotifier();
    logger.debug('会话引擎已初始化');
    // 同步恢复上次强杀/退出遗留的会话草稿，保证任务列表首次构建前历史已补写。
    recoverSessionDraftsOnInit();
  } catch (e) {
    logger.error('初始化会话引擎失败：' + JSON.stringify(e));
  }

  // 初始化桥接层：生成/加载 TLS 身份并建立事件通道（幂等）。
  // 必须显式传入持久化目录（save_dir）：此时 BridgeState.save_dir 尚未设置
  // （createServer 才会写入），且 initialized 置位后 createServer 内的兜底
  // 初始化不会重新加载——若此处不传，identity.pem 永远不会被加载/保存，
  // 指纹将随每次冷启动变化（对方设备的配对/信任识别随之失效）。
  // 显式调用同时保证身份在首次进入 UI 前就已就绪，且事件通道在事件订阅后立即可用。
  try {
    nativeInitWithPersistedIdentity(getDeviceAlias(), getDeviceType(), getReceiveSaveDir());
    logger.debug('原生桥接已初始化 alias=' + getDeviceAlias() +
      ' type=' + getDeviceType());
  } catch (e) {
    logger.error('原生桥接初始化失败：' + JSON.stringify(e));
  }

  // 立即应用已保存的主题（浅色/深色/跟随系统）
  applyThemeToApp(getTheme());

  // 应用已保存的语言偏好
  applyLocaleToApp(getLocale());

  // 监听网络变化——刷新网卡并通知 UI
  try {
    netConnection = connection.createNetConnection();
    const netConn: connection.NetConnection = netConnection;

    // 网络变化自动扫描的防抖计时器
    let autoScanTimer: number = -1;
    // 本轮防抖窗口内是否包含连接建立/断开事件：合并事件时保留强制重启意图
    let pendingForceRestart: boolean = false;
    // 热点状态变化后的补查计时器
    let hotspotRecheckTimer: number = -1;

    // 实际应用一次网络变化：刷新网卡/警告/网页地址，服务器运行中则重启发现
    let applyNetworkChange = (force: boolean): void => {
      refreshWebNetwork();
      // 服务器运行中则重启发现（让组播 socket 适配新接口）
      if (isServerRunning()) {
        restartDiscovery(force);
      }
    };

    // 每次网络事件重置 1s 防抖计时器
    let onNetworkChange = (force: boolean): void => {
      if (force) {
        pendingForceRestart = true;
      }
      if (autoScanTimer >= 0) {
        clearTimeout(autoScanTimer);
      }
      autoScanTimer = setTimeout(() => {
        let forceRestart: boolean = pendingForceRestart;
        pendingForceRestart = false;
        applyNetworkChange(forceRestart);
        autoScanTimer = -1;
      }, 1000);
    };

    // 断线后的恢复需要强制重启（接口名与 IP 可能不变，但组播组成员关系已失效）；
    // 启动时的 netAvailable 只是网络本就可用，不能强制重启，否则会打断启动时
    // 刚发起的第一轮扫描，把设备发现推迟一整轮。
    let networkWasLost: boolean = false;
    netConn.on('netLost', () => {
      networkWasLost = true;
      onNetworkChange(true);
    });
    netConn.on('netAvailable', () => {
      let recovered: boolean = networkWasLost;
      networkWasLost = false;
      onNetworkChange(recovered);
    });
    netConn.on('netCapabilitiesChange', () => {
      onNetworkChange(false);
    });

    netConn.register(() => {
      // 注册时的初始检查
      onNetworkChange(false);
    });

    // 热点（SoftAP）启停不产生 netAvailable/netLost 等连接网络事件，
    // 单独监听热点状态，让网页面板与设置页的可用地址随热点开关即时更新。
    try {
      wifiManager.on('hotspotStateChange', (state: number): void => {
        logger.debug('热点状态变化 state=' + state);
        onNetworkChange(false);
        // 热点接口的 IPv4 可能晚于状态事件就绪：稍后补查一次，避免地址短暂缺失后不再更新
        if (hotspotRecheckTimer >= 0) {
          clearTimeout(hotspotRecheckTimer);
        }
        hotspotRecheckTimer = setTimeout((): void => {
          hotspotRecheckTimer = -1;
          applyNetworkChange(false);
        }, 3000);
      });
    } catch (e) {
      logger.warn('注册热点状态监听失败：' + String(e));
    }
  } catch (_e) {
    logger.warn('注册网络变化监听失败');
  }
}

// ── 原生错误事件诊断 ──

/**
 * 原生错误事件 → 诊断文本（纯函数，无副作用）：结构化输出上下文与消息；
 * 该事件本身不携带会话标识，由调用方在可归属时传入目标会话标识。
 */
export function formatNativeErrorDiagnostic(event: NativeErrorEvent, sessionId: string): string {
  let attribution: string = sessionId.length > 0 ? sessionId : '不可归属';
  return '原生错误 上下文=' + event.context + ' 消息=' + event.message + ' 会话=' + attribution;
}

/** 可归属的发送会话统一标识：恰有一个非终态发送会话时可归属，否则返回空串。 */
function attributableSendSessionId(): string {
  let candidate: string = '';
  let count: number = 0;
  let sessions: Array<SendSessionState> = getSendSessions();
  for (let i = 0; i < sessions.length; i++) {
    if (!isTerminalSendStatus(sessions[i].status)) {
      count++;
      candidate = sessions[i].unifiedSessionId;
    }
  }
  return count === 1 ? candidate : '';
}

/** 原生错误事件处理：纳入发送失败诊断；可归属时关联到当前进行中的发送会话。 */
function handleNativeErrorEventTyped(event: NativeErrorEvent): void {
  logger.error(formatNativeErrorDiagnostic(event, attributableSendSessionId()));
}

// ── 服务器生命周期（整合服务器 + 传输关注点） ──

export async function startLocalServer(): Promise<string> {
  let fingerprint: string = await serverStartLocal();
  startRequestPolling();
  return fingerprint;
}

export async function stopLocalServer(): Promise<void> {
  stopRequestPolling();
  await serverStopLocal();
}

// ── 安全上下文（TLS 证书） ──

// 传输进行中时重置的守卫错误标识（供 ViewModel 区分「忙」与「一般失败」）
const RESET_BUSY_ERROR: string = 'ACTIVE_TRANSFERS';

/**
 * 获取当前生效的安全上下文（证书/公钥/私钥/指纹）。
 */
export function getSecurityContext(): NativeSecurityContext {
  return nativeGetSecurityContext();
}

/**
 * 重置 TLS 证书并持久化。
 * - 存在进行中传输（含网页下载/上传）时抛错（不中断文件传输）
 * - 重置成功后若 LocalSend 服务器运行中则自动重启；网页 HTTPS 运行中同样重启以应用新证书
 * - 返回重置后的安全上下文
 */
export async function resetTlsCertificate(): Promise<NativeSecurityContext> {
  // Web 传输不占用统一传输任务，需单独检查：重置会换掉网页 HTTPS 复用证书
  if (hasActiveTransfers() || hasActiveWebDownloads() || hasActiveWebUploads()) {
    throw new Error(RESET_BUSY_ERROR);
  }
  let ctx: NativeSecurityContext = nativeResetSecurityContext();
  if (isServerRunning()) {
    await restartServer();
  }
  // 网页服务与 LocalSend 生命周期独立，但 HTTPS 复用桥接层证书：
  // 正在以 HTTPS 运行时重启一次，使浏览器拿到新证书（HTTP 无需处理）。
  if (getWebHttpsEnabled() && getWebActualPort() > 0) {
    await restartWebService();
  }
  return ctx;
}

// ── 通知深链信号（进程内一次性） ──

/** 待消费的导航意图：目标 + 会话标识（仅任务详情页非空，其余为空串）。 */
export interface PendingNavigation {
  target: string
  sessionId: string
}

// 空导航意图（只读）：消费后复用同一实例，避免高频变更总线上重复分配。
const EMPTY_PENDING_NAVIGATION: PendingNavigation = { target: '', sessionId: '' };

// 待消费的导航意图：通知点击意图由 EntryAbility 解析 want 后置位，主页面消费即清空。
let pendingNavigation: PendingNavigation = EMPTY_PENDING_NAVIGATION;

/** 置位深链导航信号并触发变更总线（幂等：重复设置同值安全）。 */
export function setPendingNavigation(target: string, sessionId: string = ''): void {
  pendingNavigation = { target: target, sessionId: sessionId };
  triggerRefresh();
}

/** 读取并清空深链信号（一次性消费）。 */
export function consumePendingNavigation(): PendingNavigation {
  let pending: PendingNavigation = pendingNavigation;
  pendingNavigation = EMPTY_PENDING_NAVIGATION;
  return pending;
}
