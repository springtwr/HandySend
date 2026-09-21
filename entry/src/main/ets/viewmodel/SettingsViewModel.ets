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
  getServerError,
  getNoWifiWarning,
  getAllInterfacesDisabled,
  subscribe,
  unsubscribe,
  restartDiscovery,
  getMtaReceiveEnabled,
  setMtaReceiveEnabled,
  applyMtaReceiveEnabled,
  stopMtaReceive,
  getMtaSimulatedBrand,
  setMtaSimulatedBrand,
  applyMtaSimulatedBrand,
  isMtaConnectionWarnings,
  setMtaConnectionWarnings
} from '../service/AppService';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AutoConfirmMode } from '../model/Types';
import { generateAlias, getSystemDeviceName } from '../utils/AliasGenerator';
import { getNativeLibraryVersion, getLocalSendProtocolVersion } from '../service/NativeBridge';
import { isDebugEnabled, setDebugEnabled, getLogger } from '../utils/Logger';
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
  DEFAULT_MTA_RECEIVE_ENABLED,
  DEFAULT_MTA_SIMULATED_BRAND,
  DEFAULT_MTA_CONNECTION_WARNINGS,
  DEFAULT_CUSTOM_ALIAS,
  DEFAULT_CUSTOM_DEVICE_TYPE
} from '../model/SettingsDefaults';

// 网络设置相关类型经 ViewModel 出口（View 层不直接 import model/Types）。
export { NetworkInterface, NetworkType } from '../model/Types';

const logger = getLogger(LogDomains.SETTINGS, 'HandySend:SettingsViewModel', '设置页');

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
  @Trace public serverError: string = ''
  @Trace public noWifiWarning: boolean = false
  @Trace public allInterfacesDisabled: boolean = false
  @Trace public debugLogEnabled: boolean = false
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
    this.serverError = getServerError();
    this.noWifiWarning = getNoWifiWarning();
    this.debugLogEnabled = isDebugEnabled();
  }

  subscribe(): void {
    this.refreshCallback = () => {
      this.serverReady = isServerRunning();
      this.serverNeedsRestart = doesServerNeedRestart();
      this.serverError = getServerError();
      this.noWifiWarning = getNoWifiWarning();
      this.allInterfacesDisabled = getAllInterfacesDisabled();
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

  setAdvancedSettingsEnabled(on: boolean): void {
    this.advancedSettings = on;
    setAdvancedSettings(on);
  }

  setDebugLogEnabled(on: boolean): void {
    this.debugLogEnabled = on;
    setDebugEnabled(on);
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

    // 调试日志（非常驻设置项，不经 SettingsDefaults）
    this.debugLogEnabled = false;
    setDebugEnabled(false);

    // 刷新设备信息（服务器重启横幅会自动显示）
    refreshDeviceInfo();

    // 仅当服务器确实以默认设置运行时才清除重启横幅。
    // 不要盲目清除——setHttpsEnabled(true) 等操作可能已设置重启标志
    // 如果服务器曾以非默认值运行（例如 HTTPS=false）。
    // 服务器以新设置重启后，重启横幅会自动消失。
  }
}
