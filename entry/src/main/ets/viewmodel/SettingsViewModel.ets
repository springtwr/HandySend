import { preferencesUtil } from '../utils/PreferencesUtil';
import { setHttpsEnabled, refreshDeviceInfo, setReceivePin, setAutoFinish, setSaveToHistory, setSaveToGallery,
  setDestination, setTheme, setLocale, setEnableAnimations, setHideTabBarOnScroll, isHideTabBarOnScroll,
  setAdvancedSettings, setPort, setMulticastGroup,
  setDiscoveryTimeout,   setNetworkWhitelist, getNetworkWhitelist, setNetworkBlacklist, getNetworkBlacklist, setCreateChecksums, setVerifyChecksums,
  setSendMode, setAutoConfirmMode, restartServer, startServer, stopServer,
  getAutoConfirmMode, setAutoAcceptWebDownload, getAutoAcceptWebDownload, getReceivePin, isAutoFinish,
  isSaveToHistory, isSaveToGallery, getDestination, getTheme, getLocale, isEnableAnimations,
  isCreateChecksums, isVerifyChecksums, getSendMode, isAdvancedSettings,
  getShareViaLinkAutoAccept, getReceiveViaLinkAutoAccept, getPort, getMulticastGroup,
  getDiscoveryTimeout, getEncryptedTransfer,
  isServerRunning, doesServerNeedRestart, getServerError, getNoWifiWarning,
  subscribe, unsubscribe } from '../service/AppService';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SendMode, AutoConfirmMode } from '../model/Types';
import { generateAlias, getSystemDeviceName } from '../utils/AliasGenerator';
import { getNativeLibraryVersion, getLocalSendProtocolVersion } from '../service/NativeBridge';
import { isDebugEnabled, setDebugEnabled } from '../utils/Logger';
import { getLocalInterfaces } from '../service/repository/AppCore';
import { NetworkInterface } from '../model/Types';

// 设置业务命令 + 身份状态，从 SettingsContent 抽出。
// 持有全部设置值 + 服务/持久化副作用。
@ObservedV2
export class SettingsViewModel {
  @Trace public customAlias: string = ''
  @Trace public customDeviceType: string = 'mobile'
  @Trace public customDeviceModel: string = ''
  @Trace public handySendVersion: string = ''
  @Trace public localsendVersion: string = ''
  @Trace public protocolVersion: string = ''
  // 设置状态
  @Trace public autoAcceptWebDownload: boolean = true
  @Trace public encryptedTransfer: boolean = true
  @Trace public autoConfirmMode: string = 'paired'
  @Trace public receivePin: string = ''
  @Trace public autoFinish: boolean = true
  @Trace public saveToHistory: boolean = true
  @Trace public saveToGallery: boolean = true
  @Trace public destination: string = ''
  @Trace public advancedSettings: boolean = false
  @Trace public port: number = 53317
  @Trace public multicastGroup: string = '224.0.0.167'
  @Trace public discoveryTimeout: number = 1000
  @Trace public networkWhitelist: string = ''
  @Trace public networkBlacklist: string = ''
  @Trace public createChecksums: boolean = true
  @Trace public verifyChecksums: boolean = true
  @Trace public sendMode: string = 'single'
  @Trace public shareViaLinkAutoAccept: boolean = false
  @Trace public receiveViaLinkAutoAccept: boolean = false
  @Trace public serverNeedsRestart: boolean = false
  @Trace public enableAnimations: boolean = true
  @Trace public hideTabBarOnScroll: boolean = false
  @Trace public theme: string = 'system'
  @Trace public locale: string = ''
  @Trace public serverReady: boolean = false
  @Trace public serverError: string = ''
  @Trace public noWifiWarning: boolean = false
  @Trace public debugLogEnabled: boolean = false
  private refreshCallback: () => void = () => {}

  loadInitialData(): void {
    this.customAlias = preferencesUtil.getString('customAlias', '');
    this.customDeviceType = preferencesUtil.getString('customDeviceType', 'mobile');
    this.customDeviceModel = preferencesUtil.getString('customDeviceModel', '');

    this.loadSettings();

    // 获取版本信息
    this.localsendVersion = getNativeLibraryVersion();
    this.protocolVersion = 'v' + getLocalSendProtocolVersion();
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).then((bundleInfo: bundleManager.BundleInfo) => {
      this.handySendVersion = bundleInfo.versionName;
    }).catch((_e: BusinessError) => {
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
    this.destination = getDestination();
    this.theme = getTheme();
    this.locale = getLocale();
    this.enableAnimations = isEnableAnimations();
    this.hideTabBarOnScroll = isHideTabBarOnScroll();
    this.createChecksums = isCreateChecksums();
    this.verifyChecksums = isVerifyChecksums();
    this.sendMode = getSendMode() as string;
    this.advancedSettings = isAdvancedSettings();
    this.shareViaLinkAutoAccept = getShareViaLinkAutoAccept();
    this.receiveViaLinkAutoAccept = getReceiveViaLinkAutoAccept();
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
    };
    subscribe(this.refreshCallback);
  }

  unsubscribe(): void {
    unsubscribe(this.refreshCallback);
  }

  setAlias(value: string): void {
    this.customAlias = value;
    preferencesUtil.setString('customAlias', value);
    refreshDeviceInfo();
  }

  setDeviceType(value: string): void {
    this.customDeviceType = value;
    preferencesUtil.setString('customDeviceType', value);
    refreshDeviceInfo();
  }

  setDeviceModel(value: string): void {
    this.customDeviceModel = value;
    preferencesUtil.setString('customDeviceModel', value);
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
    preferencesUtil.setString('autoConfirmMode', mode);
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

  setThemeMode(theme: string): void {
    this.theme = theme;
    setTheme(theme);
  }

  setAnimationsEnabled(on: boolean): void {
    this.enableAnimations = on;
    setEnableAnimations(on);
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

  setNetworkWhitelistValue(v: string): void {
    this.networkWhitelist = v;
    setNetworkWhitelist(v);
  }

  setNetworkBlacklistValue(v: string): void {
    this.networkBlacklist = v;
    setNetworkBlacklist(v);
  }

  // 获取本机网络接口列表，委托调用 AppCore
  getLocalInterfacesList(): Array<NetworkInterface> {
    return getLocalInterfaces();
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
    // 将所有设置重置为默认值
    // 设备身份——空字符串时根据系统信息自动检测
    this.customAlias = '';
    this.customDeviceType = '';
    this.customDeviceModel = '';
    preferencesUtil.setString('customAlias', '');
    preferencesUtil.setString('customDeviceType', '');
    preferencesUtil.setString('customDeviceModel', '');

    // 接收设置
    this.autoConfirmMode = 'off';
    setAutoConfirmMode(AutoConfirmMode.off);
    this.receivePin = '';
    setReceivePin('');
    this.autoFinish = true;
    setAutoFinish(true);
    this.saveToHistory = true;
    setSaveToHistory(true);
    this.saveToGallery = false;
    setSaveToGallery(false);
    this.destination = '';
    setDestination('');

    // 主题与外观
    this.theme = 'system';
    setTheme('system');
    this.enableAnimations = true;
    setEnableAnimations(true);
    this.hideTabBarOnScroll = false;
    setHideTabBarOnScroll(false);
    this.autoAcceptWebDownload = true;
    setAutoAcceptWebDownload(true);

    // 语言——重置为跟随系统（使用 setLocale 走完整流程）
    this.locale = '';
    setLocale('');

    // 发送设置
    this.sendMode = SendMode.single;
    setSendMode(SendMode.single);

    // 安全
    this.encryptedTransfer = true;
    setHttpsEnabled(true);

    // 高级设置
    this.advancedSettings = false;
    setAdvancedSettings(false);
    this.port = 53317;
    setPort(53317);
    this.multicastGroup = '224.0.0.167';
    setMulticastGroup('224.0.0.167');
    this.discoveryTimeout = 1000;
    setDiscoveryTimeout(1000);
    this.networkWhitelist = 'wifi,ethernet';
    setNetworkWhitelist('wifi,ethernet');
    this.networkBlacklist = 'cellular,unknown';
    setNetworkBlacklist('cellular,unknown');
    this.createChecksums = true;
    this.verifyChecksums = true;
    setCreateChecksums(true);
    setVerifyChecksums(true);

    // 调试日志
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
