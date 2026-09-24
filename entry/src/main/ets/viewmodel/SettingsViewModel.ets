import {
  setHttpsEnabled,
  refreshDeviceInfo,
  setReceivePin,
  setAutoFinish,
  setSaveToHistory,
  setSaveToGallery,
  setDestination,
  setCustomAlias,
  getCustomAlias,
  setCustomDeviceType,
  getCustomDeviceType,
  setTheme,
  setLocale,
  setHideTabBarOnScroll,
  isHideTabBarOnScroll,
  setAdvancedSettings,
  setPort,
  setMulticastGroup,
  setDiscoveryTimeout,
  setNetworkWhitelist,
  getNetworkWhitelist,
  setNetworkBlacklist,
  getNetworkBlacklist,
  setCreateChecksums,
  setVerifyChecksums,
  setAutoClearStagedAfterSend,
  setAutoConfirmMode,
  restartServer,
  startServer,
  stopServer,
  getAutoConfirmMode,
  setAutoAcceptWebDownload,
  getAutoAcceptWebDownload,
  getReceivePin,
  isAutoFinish,
  isSaveToHistory,
  isSaveToGallery,
  getDestination,
  getTheme,
  getLocale,
  isCreateChecksums,
  isVerifyChecksums,
  isAutoClearStagedAfterSend,
  isAdvancedSettings,
  getPort,
  getMulticastGroup,
  getDiscoveryTimeout,
  getEncryptedTransfer,
  isServerRunning,
  doesServerNeedRestart,
  getNoWifiWarning,
  getAllInterfacesDisabled,
  subscribe,
  unsubscribe,
  getAppContext,
  restartDiscovery,
  getLocalSendEnabled,
  setLocalSendEnabled,
  getMtaEnabled,
  setMtaEnabled,
  getMtaReceiveEnabled,
  setMtaReceiveEnabled,
  applyMtaEnabled,
  applyMtaReceiveEnabled,
  stopMtaReceive,
  getMtaSimulatedBrand,
  setMtaSimulatedBrand,
  applyMtaSimulatedBrand,
  isMtaConnectionWarnings,
  setMtaConnectionWarnings
} from '../service/AppService';
import {
  isNotificationPermissionGranted,
  isBluetoothPermissionGranted,
  requestNotificationPermission,
  requestBluetoothPermission,
  guideToNotificationSettings,
  guideToBluetoothPermissionSetting
} from '../service/PermissionService';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AutoConfirmMode } from '../model/Types';
import { generateAlias, getSystemDeviceName } from '../utils/AliasGenerator';
import { errorText } from '../utils/FormatUtil';
import { getNativeLibraryVersion, getLocalSendProtocolVersion } from '../service/NativeBridge';
import { setDebugEnabled, getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { getLocalInterfaces, updateLocalInterfaces } from '../service/AppService';
import { NetworkInterface } from '../model/Types';
import {
  DEFAULT_ENCRYPTED_TRANSFER,
  DEFAULT_AUTO_CONFIRM_MODE,
  DEFAULT_RECEIVE_PIN,
  DEFAULT_AUTO_FINISH,
  DEFAULT_AUTO_ACCEPT_WEB_DOWNLOAD,
  DEFAULT_SAVE_TO_HISTORY,
  DEFAULT_SAVE_TO_GALLERY,
  DEFAULT_DESTINATION,
  DEFAULT_THEME,
  DEFAULT_LOCALE,
  DEFAULT_HIDE_TAB_BAR_ON_SCROLL,
  DEFAULT_CREATE_CHECKSUMS,
  DEFAULT_VERIFY_CHECKSUMS,
  DEFAULT_ADVANCED_SETTINGS,
  DEFAULT_PORT,
  DEFAULT_MULTICAST_GROUP,
  DEFAULT_DISCOVERY_TIMEOUT,
  DEFAULT_NETWORK_WHITELIST,
  DEFAULT_NETWORK_BLACKLIST,
  DEFAULT_AUTO_CLEAR_STAGED,
  DEFAULT_LOCALSEND_ENABLED,
  DEFAULT_MTA_ENABLED,
  DEFAULT_MTA_RECEIVE_ENABLED,
  DEFAULT_MTA_SIMULATED_BRAND,
  DEFAULT_MTA_CONNECTION_WARNINGS,
  DEFAULT_CUSTOM_ALIAS,
  DEFAULT_CUSTOM_DEVICE_TYPE
} from '../model/SettingsDefaults';
import { DialogService } from '../service/DialogService';
import { listActiveSessionsByProtocolKeys, cancel } from '../service/transfer/TransferSessionRegistry';
import { TransferSession, SessionDataFlow } from '../model/transfer/TransferSession';
import { LOCAL_SEND_KEY } from '../service/transfer/adapters/LocalSendSendAdapter';
import { LOCAL_RECEIVE_KEY } from '../service/transfer/adapters/LocalSendReceiveAdapter';
import { MTA_SEND_KEY } from '../service/transfer/adapters/MtaSendAdapter';
import { MTA_RECEIVE_KEY } from '../service/transfer/adapters/MtaReceiveAdapter';
import { WEB_DOWNLOAD_KEY } from '../service/transfer/adapters/WebDownloadAdapter';

// 网络设置相关类型经 ViewModel 出口（View 层不直接 import model/Types）。
export { NetworkInterface, NetworkType } from '../model/Types';

const logger = getLogger(LogDomains.SETTINGS, 'HandySend:SettingsViewModel', '设置页');

// LocalSend 总开关关闭时中断的会话协议键范围：LocalSend 发送/接收 + 网页下载
const LOCALSEND_SESSION_KEYS: Array<string> = [LOCAL_SEND_KEY, LOCAL_RECEIVE_KEY, WEB_DOWNLOAD_KEY];

// MTA 总开关关闭时中断的会话协议键范围：MTA 发送/接收
const MTA_SESSION_KEYS: Array<string> = [MTA_SEND_KEY, MTA_RECEIVE_KEY];

// 设置业务命令 + 身份状态，从 SettingsContent 抽出。
// 持有全部设置值 + 服务/持久化副作用。
@ObservedV2
export class SettingsViewModel {
  @Trace public customAlias: string = DEFAULT_CUSTOM_ALIAS
  @Trace public customDeviceType: string = DEFAULT_CUSTOM_DEVICE_TYPE
  @Trace public handySendVersion: string = ''
  @Trace public localsendVersion: string = ''
  @Trace public protocolVersion: string = ''
  // 设置状态
  @Trace public autoAcceptWebDownload: boolean = DEFAULT_AUTO_ACCEPT_WEB_DOWNLOAD
  @Trace public encryptedTransfer: boolean = DEFAULT_ENCRYPTED_TRANSFER
  @Trace public autoConfirmMode: string = DEFAULT_AUTO_CONFIRM_MODE as string
  @Trace public receivePin: string = DEFAULT_RECEIVE_PIN
  @Trace public autoFinish: boolean = DEFAULT_AUTO_FINISH
  @Trace public saveToHistory: boolean = DEFAULT_SAVE_TO_HISTORY
  @Trace public saveToGallery: boolean = DEFAULT_SAVE_TO_GALLERY
  @Trace public localSendEnabled: boolean = DEFAULT_LOCALSEND_ENABLED
  @Trace public mtaEnabled: boolean = DEFAULT_MTA_ENABLED
  @Trace public mtaReceiveEnabled: boolean = DEFAULT_MTA_RECEIVE_ENABLED
  @Trace public mtaSimulatedBrandId: number = DEFAULT_MTA_SIMULATED_BRAND
  @Trace public mtaConnectionWarnings: boolean = DEFAULT_MTA_CONNECTION_WARNINGS
  @Trace public destination: string = DEFAULT_DESTINATION
  @Trace public advancedSettings: boolean = DEFAULT_ADVANCED_SETTINGS
  @Trace public port: number = DEFAULT_PORT
  @Trace public multicastGroup: string = DEFAULT_MULTICAST_GROUP
  @Trace public discoveryTimeout: number = DEFAULT_DISCOVERY_TIMEOUT
  @Trace public networkWhitelist: string = DEFAULT_NETWORK_WHITELIST
  @Trace public networkBlacklist: string = DEFAULT_NETWORK_BLACKLIST
  @Trace public createChecksums: boolean = DEFAULT_CREATE_CHECKSUMS
  @Trace public verifyChecksums: boolean = DEFAULT_VERIFY_CHECKSUMS
  @Trace public autoClearStaged: boolean = DEFAULT_AUTO_CLEAR_STAGED
  @Trace public serverNeedsRestart: boolean = false
  @Trace public hideTabBarOnScroll: boolean = DEFAULT_HIDE_TAB_BAR_ON_SCROLL
  @Trace public theme: string = DEFAULT_THEME
  @Trace public locale: string = DEFAULT_LOCALE
  @Trace public serverReady: boolean = false
  @Trace public noWifiWarning: boolean = false
  @Trace public allInterfacesDisabled: boolean = false
  @Trace public notificationGranted: boolean = false
  @Trace public bluetoothGranted: boolean = false
  @Trace public interfaceListVersion: number = 0 // 接口列表版本号，每次刷新递增，供 UI 监听
  private refreshCallback: () => void = () => {
  }

  loadInitialData(): void {
    this.customAlias = getCustomAlias();
    this.customDeviceType = getCustomDeviceType();

    this.loadSettings();

    // 获取版本信息
    this.localsendVersion = getNativeLibraryVersion();
    this.protocolVersion = 'v' + getLocalSendProtocolVersion();
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
      .then((bundleInfo: bundleManager.BundleInfo) => {
        this.handySendVersion = bundleInfo.versionName;
      })
      .catch((_e: BusinessError) => {
        this.handySendVersion = '';
      });
  }

  // 从 AppService 加载全部设置并订阅服务器状态变化。
  loadSettings(): void {
    this.autoAcceptWebDownload = getAutoAcceptWebDownload();
    this.encryptedTransfer = getEncryptedTransfer();
    this.autoConfirmMode = getAutoConfirmMode() as string;
    this.receivePin = getReceivePin();
    this.autoFinish = isAutoFinish();
    this.saveToHistory = isSaveToHistory();
    this.saveToGallery = isSaveToGallery();
    this.localSendEnabled = getLocalSendEnabled();
    this.mtaEnabled = getMtaEnabled();
    this.mtaReceiveEnabled = getMtaReceiveEnabled();
    this.mtaSimulatedBrandId = getMtaSimulatedBrand();
    this.mtaConnectionWarnings = isMtaConnectionWarnings();
    this.destination = getDestination();
    this.theme = getTheme();
    this.locale = getLocale();
    this.hideTabBarOnScroll = isHideTabBarOnScroll();
    this.createChecksums = isCreateChecksums();
    this.verifyChecksums = isVerifyChecksums();
    this.autoClearStaged = isAutoClearStagedAfterSend();
    this.advancedSettings = isAdvancedSettings();
    this.port = getPort();
    this.multicastGroup = getMulticastGroup();
    this.discoveryTimeout = getDiscoveryTimeout();
    this.networkWhitelist = getNetworkWhitelist();
    this.networkBlacklist = getNetworkBlacklist();
    this.serverReady = isServerRunning();
    this.serverNeedsRestart = doesServerNeedRestart();
    this.noWifiWarning = getNoWifiWarning();
    // 权限为系统状态（非持久化设置），随设置加载一并查询刷新
    this.notificationGranted = isNotificationPermissionGranted();
    this.bluetoothGranted = isBluetoothPermissionGranted();
  }

  subscribe(): void {
    this.refreshCallback = () => {
      this.serverReady = isServerRunning();
      this.serverNeedsRestart = doesServerNeedRestart();
      this.noWifiWarning = getNoWifiWarning();
      this.allInterfacesDisabled = getAllInterfacesDisabled();
      // 权限可能已在系统侧变更（如从设置页返回），一并重新查询
      this.notificationGranted = isNotificationPermissionGranted();
      this.bluetoothGranted = isBluetoothPermissionGranted();
      // 接口列表可能已刷新（网络变化时），通知 UI 重新读取
      this.interfaceListVersion++;
    };
    subscribe(this.refreshCallback);
  }

  unsubscribe(): void {
    unsubscribe(this.refreshCallback);
  }

  setAlias(value: string): void {
    this.customAlias = value;
    setCustomAlias(value);
    refreshDeviceInfo();
  }

  setDeviceType(value: string): void {
    this.customDeviceType = value;
    setCustomDeviceType(value);
    refreshDeviceInfo();
  }

  randomizeAlias(): void {
    let newAlias = generateAlias();
    this.setAlias(newAlias);
  }

  useSystemAlias(): void {
    let sysName = getSystemDeviceName();
    this.setAlias(sysName);
  }

  setAutoConfirmMode(mode: string): void {
    this.autoConfirmMode = mode;
    if (mode === 'off') {
      setAutoConfirmMode(AutoConfirmMode.off);
    } else if (mode === 'paired') {
      setAutoConfirmMode(AutoConfirmMode.paired);
    } else {
      setAutoConfirmMode(AutoConfirmMode.on);
    }
  }

  setReceivePinValue(pin: string): void {
    this.receivePin = pin;
    setReceivePin(pin);
  }

  setAutoFinishEnabled(on: boolean): void {
    this.autoFinish = on;
    setAutoFinish(on);
  }

  setGallerySaveEnabled(on: boolean): void {
    this.saveToGallery = on;
    setSaveToGallery(on);
  }

  setHistorySaveEnabled(on: boolean): void {
    this.saveToHistory = on;
    setSaveToHistory(on);
  }

  setAutoAcceptWebDownloadEnabled(on: boolean): void {
    this.autoAcceptWebDownload = on;
    setAutoAcceptWebDownload(on);
  }

  /** 发送成功后自动清空暂存（默认关闭：暂存保留以支持连续发送） */
  setAutoClearStagedAfterSendEnabled(on: boolean): void {
    this.autoClearStaged = on;
    setAutoClearStagedAfterSend(on);
  }

  // LocalSend 总开关：开启或无活跃传输时立即持久化并启停服务器（含设备发现与网页分享）；
  // 关闭且有活跃传输（含待确认）时先二次确认，确认后写入、生效并逐会话中断
  setLocalSendEnabledValue(on: boolean): void {
    this.setProtocolToggleValue(on, LOCALSEND_SESSION_KEYS, $r('app.string.localsend_enabled_label'),
      (enabled: boolean) => {
        this.localSendEnabled = enabled;
        setLocalSendEnabled(enabled);
      },
      (enabled: boolean) => {
        this.applyLocalSendEnabled(enabled);
      });
  }

  // 按开关状态启停 LocalSend 服务器（开启=重启恢复，关闭=停止）
  private applyLocalSendEnabled(on: boolean): void {
    if (on) {
      startServer().catch((e: Error) => {
        logger.warn('LocalSend 开启后启动服务器失败: ' + errorText(e));
      });
    } else {
      stopServer().catch((e: Error) => {
        logger.warn('LocalSend 关闭后停止服务器失败: ' + errorText(e));
      });
    }
  }

  // MTA 总开关：开启或无活跃传输时立即持久化并生效（关闭=停接收与发现扫描，开启=按接收子开关恢复接收）；
  // 关闭且有活跃传输（含待确认）时先二次确认，确认后写入、生效并逐会话中断
  setMtaEnabledValue(on: boolean): void {
    this.setProtocolToggleValue(on, MTA_SESSION_KEYS, $r('app.string.mta_enabled_label'),
      (enabled: boolean) => {
        this.mtaEnabled = enabled;
        setMtaEnabled(enabled);
      },
      () => {
        applyMtaEnabled();
      });
  }

  /**
   * 协议总开关统一写入流程：
   * - 开启方向或无活跃传输：立即写入并生效；
   * - 关闭且有活跃传输（含待确认）：弹窗确认——确认后写入、生效并逐会话中断（落取消终态）；
   *   取消则不写入，显式写回原值驱动 Toggle 回弹。
   */
  private setProtocolToggleValue(on: boolean, sessionKeys: Array<string>, labelRes: Resource,
    write: (enabled: boolean) => void, apply: (enabled: boolean) => void): void {
    let label: string = this.resolveResourceText(labelRes);
    if (on) {
      write(true);
      apply(true);
      logger.info('协议开关已开启: ' + label);
      return;
    }
    let active = listActiveSessionsByProtocolKeys(sessionKeys);
    if (active.length === 0) {
      write(false);
      apply(false);
      logger.info('协议开关已关闭（无活跃传输）: ' + label);
      return;
    }
    let vm = this;
    DialogService.showProtocolDisableConfirmDialog(
      label,
      vm.buildSessionDetailLines(active),
      (confirmed: boolean) => {
        if (confirmed) {
          write(false);
          apply(false);
          vm.cancelSessions(active);
          logger.info('协议开关已关闭（用户确认）: ' + label + '，中断会话数=' + active.length);
        } else {
          // 取消：开关保持原值（true），写回以驱动绑定 Toggle 回弹
          write(true);
          logger.info('协议开关关闭已取消: ' + label);
        }
      });
  }

  // 解析资源为当前语言文本（解析失败回退空串）
  private resolveResourceText(res: Resource): string {
    let ctx = getAppContext();
    if (ctx === undefined) {
      return '';
    }
    try {
      return ctx.resourceManager.getStringSync(res.id);
    } catch (e) {
      logger.warn('解析资源文本失败: ' + errorText(e));
      return '';
    }
  }

  // 构建活跃会话明细行（方向 + 对端名 + 文件名/数量）
  private buildSessionDetailLines(sessions: Array<TransferSession>): Array<string> {
    let lines: Array<string> = [];
    for (let i = 0; i < sessions.length; i++) {
      lines.push(this.buildSessionDetailLine(sessions[i]));
    }
    return lines;
  }

  private buildSessionDetailLine(session: TransferSession): string {
    let templateRes: Resource = session.dataFlow === SessionDataFlow.outbound ?
      $r('app.string.protocol_disable_session_send') : $r('app.string.protocol_disable_session_receive');
    let template: string = this.resolveResourceText(templateRes);
    let summary: string = this.sessionFileSummary(session);
    // 模板含两个 %s：依次填对端名与文件摘要
    return template.replace('%s', session.peer.displayName).replace('%s', summary);
  }

  // 会话文件摘要：单文件显示文件名，多文件显示数量
  private sessionFileSummary(session: TransferSession): string {
    if (session.files.length === 1) {
      return session.files[0].fileName;
    }
    let countText: string = this.resolveResourceText($r('app.string.transfer_center_file_count'));
    let replaced: string = countText.replace('%d', String(session.files.length));
    return replaced;
  }

  // 逐会话中断（落取消终态；声明不可取消的会话由 cancel 内部跳过，交由协议侧事件终结）
  private cancelSessions(sessions: Array<TransferSession>): void {
    for (let i = 0; i < sessions.length; i++) {
      cancel(sessions[i].id);
    }
  }

  // 互传联盟接收开关：持久化后立即按开关启停 MTA 接收服务
  setMtaReceiveEnabledValue(on: boolean): void {
    this.mtaReceiveEnabled = on;
    setMtaReceiveEnabled(on);
    if (on) {
      applyMtaReceiveEnabled();
    } else {
      stopMtaReceive();
    }
  }

  // 模拟品牌：持久化后刷新接收广播身份（接收未运行时为空操作）
  setMtaSimulatedBrandValue(id: number): void {
    this.mtaSimulatedBrandId = id;
    setMtaSimulatedBrand(id);
    applyMtaSimulatedBrand();
  }

  // 互传连接提醒开关：持久化后经 notifyChange 通知主页面重算警告横幅
  setMtaConnectionWarningsValue(on: boolean): void {
    this.mtaConnectionWarnings = on;
    setMtaConnectionWarnings(on);
  }

  setThemeMode(theme: string): void {
    this.theme = theme;
    setTheme(theme);
  }

  setHideTabBarOnScrollEnabled(on: boolean): void {
    this.hideTabBarOnScroll = on;
    setHideTabBarOnScroll(on);
  }

  // 设置语言（语言弹窗使用）：更新 UI 状态并调用 AppService.setLocale 完成持久化与切换
  setLocaleValue(value: string): void {
    this.locale = value;
    setLocale(value);
  }

  setEncryptionEnabled(on: boolean): void {
    this.encryptedTransfer = on;
    setHttpsEnabled(on);
  }

  /**
   * 点击「通知权限」项：未开启时先申请（首次弹窗），仍被拒则引导到系统通知设置。
   * 权限为系统状态，操作后重新查询并刷新展示。
   */
  async applyNotificationPermission(): Promise<void> {
    try {
      if (this.notificationGranted) {
        return;
      }
      let ctx = getAppContext();
      if (ctx === undefined) {
        return;
      }
      let granted: boolean = await requestNotificationPermission(ctx);
      if (!granted) {
        // 半模态设置弹窗在用户操作完成后才返回，返回后重新查询即为最新状态
        await guideToNotificationSettings(ctx);
        granted = isNotificationPermissionGranted();
      }
      this.notificationGranted = granted;
    } catch (e) {
      logger.warn('通知权限申请流程异常: ' + errorText(e));
    }
  }

  /** 点击「蓝牙权限」项：未授予时先申请（首次弹窗），仍被拒则引导到系统权限设置。 */
  async applyBluetoothPermission(): Promise<void> {
    try {
      if (this.bluetoothGranted) {
        return;
      }
      let ctx = getAppContext();
      if (ctx === undefined) {
        return;
      }
      let granted: boolean = await requestBluetoothPermission(ctx);
      if (!granted) {
        await guideToBluetoothPermissionSetting(ctx);
        granted = isBluetoothPermissionGranted();
      }
      this.bluetoothGranted = granted;
    } catch (e) {
      logger.warn('蓝牙权限申请流程异常: ' + errorText(e));
    }
  }

  // 解析并校验对话框原始输入；应用成功时返回 true。
  setPortValue(value: string): boolean {
    let p = parseInt(value);
    if (isNaN(p) || p <= 0 || p > 65535) {
      return false;
    }
    this.port = p;
    setPort(p);
    return true;
  }

  setMulticastGroupValue(v: string): void {
    this.multicastGroup = v;
    setMulticastGroup(v);
  }

  // 解析并校验对话框原始输入；应用成功时返回 true。
  setDiscoveryTimeoutValue(value: string): boolean {
    let t = parseInt(value);
    if (isNaN(t) || t <= 0) {
      return false;
    }
    this.discoveryTimeout = t;
    setDiscoveryTimeout(t);
    return true;
  }

  // 保存网络白/黑名单并立即重启 discovery（不需要重启服务器）
  saveNetworkListsAndApply(whitelist: string, blacklist: string): void {
    logger.debug('白名单: \'' + whitelist + '\' 黑名单: \'' + blacklist + '\'');
    this.networkWhitelist = whitelist;
    this.networkBlacklist = blacklist;
    setNetworkWhitelist(whitelist);
    setNetworkBlacklist(blacklist);
    restartDiscovery();
  }

  // 获取本机网络接口列表，委托调用 AppCore
  getLocalInterfacesList(): Array<NetworkInterface> {
    return getLocalInterfaces();
  }

  // 刷新本机网络接口列表（重新枚举所有接口）
  refreshLocalInterfaces(): void {
    updateLocalInterfaces();
  }

  setChecksumsEnabled(on: boolean): void {
    this.createChecksums = on;
    this.verifyChecksums = on;
    setCreateChecksums(on);
    setVerifyChecksums(on);
  }

  restartServer(): Promise<string | void> {
    return restartServer();
  }

  startServer(): Promise<string | void> {
    return startServer();
  }

  stopServer(): Promise<string | void> {
    return stopServer();
  }

  restoreDefaults(): void {
    // 将所有设置重置为默认值（全部引用 SettingsDefaults 常量）
    // 设备身份——空字符串时根据系统信息自动检测
    this.customAlias = DEFAULT_CUSTOM_ALIAS;
    this.customDeviceType = DEFAULT_CUSTOM_DEVICE_TYPE;
    setCustomAlias(DEFAULT_CUSTOM_ALIAS);
    setCustomDeviceType(DEFAULT_CUSTOM_DEVICE_TYPE);

    // 接收设置
    this.autoConfirmMode = DEFAULT_AUTO_CONFIRM_MODE as string;
    setAutoConfirmMode(DEFAULT_AUTO_CONFIRM_MODE);
    this.receivePin = DEFAULT_RECEIVE_PIN;
    setReceivePin(DEFAULT_RECEIVE_PIN);
    this.autoFinish = DEFAULT_AUTO_FINISH;
    setAutoFinish(DEFAULT_AUTO_FINISH);
    this.saveToHistory = DEFAULT_SAVE_TO_HISTORY;
    setSaveToHistory(DEFAULT_SAVE_TO_HISTORY);
    this.saveToGallery = DEFAULT_SAVE_TO_GALLERY;
    setSaveToGallery(DEFAULT_SAVE_TO_GALLERY);
    this.destination = DEFAULT_DESTINATION;
    setDestination(DEFAULT_DESTINATION);

    // 主题与外观
    this.theme = DEFAULT_THEME;
    setTheme(DEFAULT_THEME);
    this.hideTabBarOnScroll = DEFAULT_HIDE_TAB_BAR_ON_SCROLL;
    setHideTabBarOnScroll(DEFAULT_HIDE_TAB_BAR_ON_SCROLL);
    this.autoAcceptWebDownload = DEFAULT_AUTO_ACCEPT_WEB_DOWNLOAD;
    setAutoAcceptWebDownload(DEFAULT_AUTO_ACCEPT_WEB_DOWNLOAD);
    // LocalSend 总开关复位：值变化时才启停服务器，避免无谓重启
    let localSendWasEnabled: boolean = this.localSendEnabled;
    this.localSendEnabled = DEFAULT_LOCALSEND_ENABLED;
    setLocalSendEnabled(DEFAULT_LOCALSEND_ENABLED);
    if (localSendWasEnabled !== DEFAULT_LOCALSEND_ENABLED) {
      this.applyLocalSendEnabled(DEFAULT_LOCALSEND_ENABLED);
    }
    // MTA 总开关复位：值变化时才启停接收与扫描，避免无谓重启
    let mtaWasEnabled: boolean = this.mtaEnabled;
    this.mtaEnabled = DEFAULT_MTA_ENABLED;
    setMtaEnabled(DEFAULT_MTA_ENABLED);
    if (mtaWasEnabled !== DEFAULT_MTA_ENABLED) {
      applyMtaEnabled();
    }
    this.mtaReceiveEnabled = DEFAULT_MTA_RECEIVE_ENABLED;
    setMtaReceiveEnabled(DEFAULT_MTA_RECEIVE_ENABLED);
    applyMtaReceiveEnabled();
    this.mtaSimulatedBrandId = DEFAULT_MTA_SIMULATED_BRAND;
    setMtaSimulatedBrand(DEFAULT_MTA_SIMULATED_BRAND);
    applyMtaSimulatedBrand();
    this.mtaConnectionWarnings = DEFAULT_MTA_CONNECTION_WARNINGS;
    setMtaConnectionWarnings(DEFAULT_MTA_CONNECTION_WARNINGS);

    // 语言——重置为跟随系统（使用 setLocale 走完整流程）
    this.locale = DEFAULT_LOCALE;
    setLocale(DEFAULT_LOCALE);

    // 发送设置
    this.autoClearStaged = DEFAULT_AUTO_CLEAR_STAGED;
    setAutoClearStagedAfterSend(DEFAULT_AUTO_CLEAR_STAGED);

    // 安全
    this.encryptedTransfer = DEFAULT_ENCRYPTED_TRANSFER;
    setHttpsEnabled(DEFAULT_ENCRYPTED_TRANSFER);

    // 高级设置
    this.advancedSettings = DEFAULT_ADVANCED_SETTINGS;
    setAdvancedSettings(DEFAULT_ADVANCED_SETTINGS);
    this.port = DEFAULT_PORT;
    setPort(DEFAULT_PORT);
    this.multicastGroup = DEFAULT_MULTICAST_GROUP;
    setMulticastGroup(DEFAULT_MULTICAST_GROUP);
    this.discoveryTimeout = DEFAULT_DISCOVERY_TIMEOUT;
    setDiscoveryTimeout(DEFAULT_DISCOVERY_TIMEOUT);
    this.networkWhitelist = DEFAULT_NETWORK_WHITELIST;
    setNetworkWhitelist(DEFAULT_NETWORK_WHITELIST);
    this.networkBlacklist = DEFAULT_NETWORK_BLACKLIST;
    setNetworkBlacklist(DEFAULT_NETWORK_BLACKLIST);
    this.createChecksums = DEFAULT_CREATE_CHECKSUMS;
    this.verifyChecksums = DEFAULT_VERIFY_CHECKSUMS;
    setCreateChecksums(DEFAULT_CREATE_CHECKSUMS);
    setVerifyChecksums(DEFAULT_VERIFY_CHECKSUMS);

    // 调试日志（非常驻设置项，不经 SettingsDefaults）：恢复默认时一并复位该内存态
    setDebugEnabled(false);

    // 刷新设备信息（服务器重启横幅会自动显示）
    refreshDeviceInfo();

    // 仅当服务器确实以默认设置运行时才清除重启横幅。
    // 不要盲目清除——setHttpsEnabled(true) 等操作可能已设置重启标志
    // 如果服务器曾以非默认值运行（例如 HTTPS=false）。
    // 服务器以新设置重启后，重启横幅会自动消失。
  }
}
