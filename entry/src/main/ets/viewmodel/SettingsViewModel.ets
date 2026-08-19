import { preferencesUtil } from '../utils/PreferencesUtil';
import { setHttpsEnabled, refreshDeviceInfo, setReceivePin, setAutoFinish, setSaveToHistory, setSaveToGallery,
  setDestination, setTheme, setLocale, setEnableAnimations, setAdvancedSettings, setPort, setMulticastGroup,
  setDiscoveryTimeout, setNetworkWhitelist, setNetworkBlacklist, setCreateChecksums, setVerifyChecksums,
  setSendMode, setQuickSaveMode, restartServer, startServer, stopServer,
  getAutoSaveMode, getHideShareByLink, getSilentReceive, getReceivePin, isAutoFinish,
  isSaveToHistory, isSaveToGallery, getDestination, getTheme, getLocale, isEnableAnimations,
  isCreateChecksums, isVerifyChecksums, getSendMode, isAdvancedSettings,
  getShareViaLinkAutoAccept, getReceiveViaLinkAutoAccept, getPort, getMulticastGroup,
  getDiscoveryTimeout, getNetworkWhitelist, getNetworkBlacklist, getEncryptedTransfer,
  isServerRunning, doesServerNeedRestart, getServerError, getNoWifiWarning,
  subscribe, unsubscribe } from '../service/AppService';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SendMode, QuickSaveMode } from '../model/Types';
import { generateAlias, getSystemDeviceName } from '../utils/AliasGenerator';
import { getNativeLibraryVersion, getLocalSendProtocolVersion } from '../service/NativeBridge';

// Settings business commands + identity state, extracted from SettingsContent.
// Owns all settings values + service/persistence side effects.
@ObservedV2
export class SettingsViewModel {
  @Trace public customAlias: string = ''
  @Trace public customDeviceType: string = 'mobile'
  @Trace public customDeviceModel: string = ''
  @Trace public handySendVersion: string = ''
  @Trace public localsendVersion: string = ''
  @Trace public protocolVersion: string = ''
  // Settings state
  @Trace public hideShareByLink: boolean = false
  @Trace public silentReceive: boolean = true
  @Trace public encryptedTransfer: boolean = true
  @Trace public autoSaveMode: string = 'paired'
  @Trace public receivePin: string = ''
  @Trace public autoFinish: boolean = false
  @Trace public saveToHistory: boolean = true
  @Trace public saveToGallery: boolean = true
  @Trace public destination: string = ''
  @Trace public advancedSettings: boolean = false
  @Trace public port: number = 53317
  @Trace public multicastGroup: string = '224.0.0.167'
  @Trace public discoveryTimeout: number = 3000
  @Trace public networkWhitelist: string = ''
  @Trace public networkBlacklist: string = ''
  @Trace public createChecksums: boolean = true
  @Trace public verifyChecksums: boolean = true
  @Trace public sendMode: string = 'single'
  @Trace public shareViaLinkAutoAccept: boolean = false
  @Trace public receiveViaLinkAutoAccept: boolean = false
  @Trace public serverNeedsRestart: boolean = false
  @Trace public enableAnimations: boolean = true
  @Trace public theme: string = 'system'
  @Trace public locale: string = ''
  @Trace public serverReady: boolean = false
  @Trace public serverError: string = ''
  @Trace public noWifiWarning: boolean = false
  private refreshCallback: () => void = () => {}

  loadInitialData(): void {
    this.customAlias = preferencesUtil.getString('customAlias', '');
    this.customDeviceType = preferencesUtil.getString('customDeviceType', 'mobile');
    this.customDeviceModel = preferencesUtil.getString('customDeviceModel', '');

    this.loadSettings();

    // Get version info
    this.localsendVersion = getNativeLibraryVersion();
    this.protocolVersion = getLocalSendProtocolVersion();
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).then((bundleInfo: bundleManager.BundleInfo) => {
      this.handySendVersion = bundleInfo.versionName;
    }).catch((_e: BusinessError) => {
      this.handySendVersion = '';
    });
  }

  // Loads all settings from AppService + subscribes to server-state changes.
  loadSettings(): void {
    this.hideShareByLink = getHideShareByLink();
    this.silentReceive = getSilentReceive();
    this.encryptedTransfer = getEncryptedTransfer();
    this.autoSaveMode = getAutoSaveMode() as string;
    this.receivePin = getReceivePin();
    this.autoFinish = isAutoFinish();
    this.saveToHistory = isSaveToHistory();
    this.saveToGallery = isSaveToGallery();
    this.destination = getDestination();
    this.theme = getTheme();
    this.locale = getLocale();
    this.enableAnimations = isEnableAnimations();
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

  setAutoSaveMode(mode: string): void {
    this.autoSaveMode = mode;
    preferencesUtil.setString('autoSaveMode', mode);
    if (mode === 'off') {
      setQuickSaveMode(QuickSaveMode.off);
    } else if (mode === 'paired') {
      setQuickSaveMode(QuickSaveMode.paired);
    } else {
      setQuickSaveMode(QuickSaveMode.on);
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

  setHideShareByLink(on: boolean): void {
    this.hideShareByLink = on;
    preferencesUtil.setBoolean('hideShareByLink', on);
  }

  setSilentReceiveEnabled(on: boolean): void {
    this.silentReceive = on;
    preferencesUtil.setBoolean('silentReceive', on);
  }

  setThemeMode(theme: string): void {
    this.theme = theme;
    setTheme(theme);
  }

  setAnimationsEnabled(on: boolean): void {
    this.enableAnimations = on;
    setEnableAnimations(on);
  }

  setEncryptionEnabled(on: boolean): void {
    this.encryptedTransfer = on;
    setHttpsEnabled(on);
  }

  setAdvancedSettingsEnabled(on: boolean): void {
    this.advancedSettings = on;
    setAdvancedSettings(on);
  }

  // Parses + validates the raw dialog input; returns true when applied.
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

  // Parses + validates the raw dialog input; returns true when applied.
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
    // Reset all settings to their default values
    // Device identity — empty strings trigger auto-detection from system info
    this.customAlias = '';
    this.customDeviceType = '';
    this.customDeviceModel = '';
    preferencesUtil.setString('customAlias', '');
    preferencesUtil.setString('customDeviceType', '');
    preferencesUtil.setString('customDeviceModel', '');

    // Receive settings
    this.autoSaveMode = 'off';
    setQuickSaveMode(QuickSaveMode.off);
    this.receivePin = '';
    setReceivePin('');
    this.autoFinish = false;
    setAutoFinish(false);
    this.saveToHistory = true;
    setSaveToHistory(true);
    this.saveToGallery = false;
    setSaveToGallery(false);
    this.destination = '';
    setDestination('');

    // Theme & appearance
    this.theme = 'system';
    setTheme('system');
    this.enableAnimations = true;
    setEnableAnimations(true);
    this.hideShareByLink = false;
    preferencesUtil.setBoolean('hideShareByLink', false);
    this.silentReceive = true;
    preferencesUtil.setBoolean('silentReceive', true);

    // Language — reset to follow system (use setLocale for full pipeline)
    this.locale = '';
    setLocale('');

    // Send settings
    this.sendMode = SendMode.single;
    setSendMode(SendMode.single);

    // Security
    this.encryptedTransfer = true;
    setHttpsEnabled(true);

    // Advanced settings
    this.advancedSettings = false;
    setAdvancedSettings(false);
    this.port = 53317;
    setPort(53317);
    this.multicastGroup = '224.0.0.167';
    setMulticastGroup('224.0.0.167');
    this.discoveryTimeout = 3000;
    setDiscoveryTimeout(3000);
    this.networkWhitelist = '';
    setNetworkWhitelist('');
    this.networkBlacklist = '';
    setNetworkBlacklist('');
    this.createChecksums = true;
    this.verifyChecksums = true;
    setCreateChecksums(true);
    setVerifyChecksums(true);

    // Refresh device info (server restart banner will show automatically)
    refreshDeviceInfo();

    // Only clear the restart banner if the server is actually running with default settings.
    // Do NOT blindly clear — setHttpsEnabled(true) etc. may have set the restart flag
    // if the server was running with non-default values (e.g. HTTPS=false).
    // The restart banner will self-clear when the server is restarted with the new settings.
  }
}
