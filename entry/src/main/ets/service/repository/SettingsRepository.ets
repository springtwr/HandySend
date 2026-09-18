import { ConfigurationConstant } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { preferencesRepo } from './PreferencesRepo';
import {
  KEY_ENCRYPTED_TRANSFER,
  KEY_AUTO_CONFIRM_MODE,
  KEY_RECEIVE_PIN,
  KEY_AUTO_FINISH,
  KEY_SAVE_TO_HISTORY,
  KEY_SAVE_TO_GALLERY,
  KEY_DESTINATION,
  KEY_THEME,
  KEY_LOCALE,
  KEY_ENABLE_ANIMATIONS,
  KEY_HIDE_TAB_BAR_ON_SCROLL,
  KEY_CREATE_CHECKSUMS,
  KEY_VERIFY_CHECKSUMS,
  KEY_SEND_MODE,
  KEY_ADVANCED_SETTINGS,
  KEY_PORT,
  KEY_MULTICAST_GROUP,
  KEY_DISCOVERY_TIMEOUT,
  KEY_NETWORK_WHITELIST,
  KEY_NETWORK_BLACKLIST,
  KEY_AUTO_ACCEPT_WEB_DOWNLOAD,
  KEY_MTA_RECEIVE_ENABLED,
  KEY_MTA_SIMULATED_BRAND,
  KEY_MTA_CONNECTION_WARNINGS
} from '../../utils/PreferencesUtil';
import { AutoConfirmMode, SendMode, NetworkType, NetworkInterface } from '../../model/Types';
import { MTA_BRAND_ID_THIRD_PARTY, normalizeMtaBrandId } from '../../model/mta/MtaBrandRegistry';
import { getAppContext, notifyChange } from './AppCore';

const logger = getLogger(LogDomains.SETTINGS, 'HandySend:SettingsRepository', '设置');
const DEFAULT_PORT = 53317;

// ── 设置状态（唯一事实来源；Preferences 负责持久化） ──

let httpsEnabled = true;
let autoConfirmMode: AutoConfirmMode = AutoConfirmMode.off;
let receivePin: string = '';
let autoFinish: boolean = true;
let autoAcceptWebDownload: boolean = true;
let saveToHistory: boolean = true;
let saveToGallery: boolean = false;
let destination: string = '';
let theme: string = 'system';
let locale: string = '';
let enableAnimations: boolean = true;
let hideTabBarOnScroll: boolean = false;
let createChecksums: boolean = false;
let verifyChecksums: boolean = true;
let sendMode: SendMode = SendMode.single;
let advancedSettings: boolean = false;
let port: number = DEFAULT_PORT;
let multicastGroup: string = '224.0.0.167';
let discoveryTimeout: number = 1000;
let serverNeedsRestart: boolean = false;
let mtaReceiveEnabled: boolean = true;
let mtaSimulatedBrand: number = MTA_BRAND_ID_THIRD_PARTY;
let mtaConnectionWarnings: boolean = true;

// ── 服务器重启标志（与 ServerRepository 共享） ──

export function markServerNeedsRestart(): void {
  serverNeedsRestart = true;
}

export function clearServerNeedsRestart(): void {
  serverNeedsRestart = false;
}

export function doesServerNeedRestart(): boolean {
  return serverNeedsRestart;
}

// ── 从 Preferences 加载全部设置（应用启动时调用一次） ──

export function loadFromPreferences(): void {
  httpsEnabled = preferencesRepo.getBoolean(KEY_ENCRYPTED_TRANSFER, true);

  let savedAutoConfirm: string = preferencesRepo.getString(KEY_AUTO_CONFIRM_MODE, 'off');
  autoConfirmMode = (savedAutoConfirm === 'off' || savedAutoConfirm === 'paired' || savedAutoConfirm === 'on') ?
    savedAutoConfirm as AutoConfirmMode : AutoConfirmMode.off;

  receivePin = preferencesRepo.getString(KEY_RECEIVE_PIN, '');
  autoFinish = preferencesRepo.getBoolean(KEY_AUTO_FINISH, true);
  autoAcceptWebDownload = preferencesRepo.getBoolean(KEY_AUTO_ACCEPT_WEB_DOWNLOAD, true);
  saveToHistory = preferencesRepo.getBoolean(KEY_SAVE_TO_HISTORY, true);
  saveToGallery = preferencesRepo.getBoolean(KEY_SAVE_TO_GALLERY, false);
  destination = preferencesRepo.getString(KEY_DESTINATION, '');
  theme = preferencesRepo.getString(KEY_THEME, 'system');
  locale = preferencesRepo.getString(KEY_LOCALE, '');
  enableAnimations = preferencesRepo.getBoolean(KEY_ENABLE_ANIMATIONS, true);
  hideTabBarOnScroll = preferencesRepo.getBoolean(KEY_HIDE_TAB_BAR_ON_SCROLL, false);
  createChecksums = preferencesRepo.getBoolean(KEY_CREATE_CHECKSUMS, false);
  verifyChecksums = preferencesRepo.getBoolean(KEY_VERIFY_CHECKSUMS, true);
  let savedSendMode: string = preferencesRepo.getString(KEY_SEND_MODE, 'single');
  sendMode = (savedSendMode === 'single' || savedSendMode === 'multiple' || savedSendMode === 'link') ?
    savedSendMode as SendMode : SendMode.single;
  advancedSettings = preferencesRepo.getBoolean(KEY_ADVANCED_SETTINGS, false);
  port = preferencesRepo.getNumber(KEY_PORT, DEFAULT_PORT);
  multicastGroup = preferencesRepo.getString(KEY_MULTICAST_GROUP, '224.0.0.167');
  discoveryTimeout = preferencesRepo.getNumber(KEY_DISCOVERY_TIMEOUT, 1000);
  mtaReceiveEnabled = preferencesRepo.getBoolean(KEY_MTA_RECEIVE_ENABLED, true);
  // 未注册/越界的持久化值按第三方处理（不写回，避免读取产生副作用）
  mtaSimulatedBrand = normalizeMtaBrandId(
    preferencesRepo.getNumber(KEY_MTA_SIMULATED_BRAND, MTA_BRAND_ID_THIRD_PARTY));
  mtaConnectionWarnings = preferencesRepo.getBoolean(KEY_MTA_CONNECTION_WARNINGS, true);
}

// ── 加密 / HTTPS ──

export function setHttpsEnabled(enabled: boolean): void {
  logger.debug(httpsEnabled.toString() + ' → ' + enabled.toString());
  httpsEnabled = enabled;
  // 立即持久化，避免应用退出时丢失设置
  preferencesRepo.setBoolean(KEY_ENCRYPTED_TRANSFER, enabled);
  preferencesRepo.flushNow();
  logger.debug(
    'persisted: key=' + KEY_ENCRYPTED_TRANSFER + ' value=' + enabled.toString() + ' flushed');
  markServerNeedsRestart();
  notifyChange();
}

export function getHttpsEnabled(): boolean {
  return httpsEnabled;
}

export function getEncryptedTransfer(): boolean {
  return httpsEnabled;
}

// ── 接收设置 ──

export function setAutoConfirmMode(mode: AutoConfirmMode): void {
  autoConfirmMode = mode;
  preferencesRepo.setString(KEY_AUTO_CONFIRM_MODE, mode);
  notifyChange();
}

export function getAutoConfirmMode(): AutoConfirmMode {
  return autoConfirmMode;
}

export function getReceivePin(): string {
  return receivePin;
}

export function setReceivePin(pin: string): void {
  receivePin = pin;
  preferencesRepo.setString(KEY_RECEIVE_PIN, pin);
  // PIN 变更需要重启服务器
  markServerNeedsRestart();
  notifyChange();
}

export function setAutoFinish(enabled: boolean): void {
  autoFinish = enabled;
  preferencesRepo.setBoolean(KEY_AUTO_FINISH, enabled);
  notifyChange();
}

export function isAutoFinish(): boolean {
  return autoFinish;
}

export function setSaveToHistory(enabled: boolean): void {
  saveToHistory = enabled;
  preferencesRepo.setBoolean(KEY_SAVE_TO_HISTORY, enabled);
  notifyChange();
}

export function isSaveToHistory(): boolean {
  return saveToHistory;
}

export function setSaveToGallery(enabled: boolean): void {
  saveToGallery = enabled;
  preferencesRepo.setBoolean(KEY_SAVE_TO_GALLERY, enabled);
  notifyChange();
}

export function isSaveToGallery(): boolean {
  return saveToGallery;
}

// ── 互传联盟（MTA）接收开关 ──

export function setMtaReceiveEnabled(enabled: boolean): void {
  mtaReceiveEnabled = enabled;
  preferencesRepo.setBoolean(KEY_MTA_RECEIVE_ENABLED, enabled);
  notifyChange();
}

export function getMtaReceiveEnabled(): boolean {
  return mtaReceiveEnabled;
}

// ── 互传联盟（MTA）模拟品牌 ──

/** 写入模拟品牌（未注册/越界值按第三方归一），持久化并通知订阅者；不含广播副作用 */
export function setMtaSimulatedBrand(id: number): void {
  mtaSimulatedBrand = normalizeMtaBrandId(id);
  preferencesRepo.setNumber(KEY_MTA_SIMULATED_BRAND, mtaSimulatedBrand);
  notifyChange();
}

/** 当前模拟品牌标识（默认第三方） */
export function getMtaSimulatedBrand(): number {
  return mtaSimulatedBrand;
}

// ── 互传联盟（MTA）连接提醒 ──

/** 互传连接提醒开关：关闭后主页面不再显示互传相关的蓝牙/WLAN 警告横幅 */
export function setMtaConnectionWarnings(enabled: boolean): void {
  mtaConnectionWarnings = enabled;
  preferencesRepo.setBoolean(KEY_MTA_CONNECTION_WARNINGS, enabled);
  notifyChange();
}

export function isMtaConnectionWarnings(): boolean {
  return mtaConnectionWarnings;
}

export function setDestination(path: string): void {
  destination = path;
  preferencesRepo.setString(KEY_DESTINATION, path);
  notifyChange();
}

export function getDestination(): string {
  return destination;
}

// ── 主题 / 语言 / 外观 ──

// 设备身份（customAlias/customDeviceType）

export function setCustomAlias(alias: string): void {
  preferencesRepo.setCustomAlias(alias);
}

export function getCustomAlias(): string {
  return preferencesRepo.getCustomAlias();
}

export function setCustomDeviceType(deviceType: string): void {
  preferencesRepo.setCustomDeviceType(deviceType);
}

export function getCustomDeviceType(): string {
  return preferencesRepo.getCustomDeviceType();
}

// 应用主题色模式到应用上下文（浅色/深色/跟随系统）。theme 应用逻辑的唯一实现。
export function applyThemeToApp(mode: string): void {
  try {
    let appCtx = getAppContext();
    if (appCtx) {
      let applicationContext = appCtx.getApplicationContext();
      if (mode === 'light') {
        applicationContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (mode === 'dark') {
        applicationContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        applicationContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    }
  } catch (_e) {
    logger.warn('applyColorMode failed');
  }
}

// 应用语言偏好到应用上下文。locale 应用逻辑的唯一实现。
export function applyLocaleToApp(lang: string): void {
  try {
    if (lang === 'system' || lang === '') {
      // 显式设置系统语言而非 'default'，以立即生效
      let sysLang = i18n.System.getSystemLanguage();
      i18n.System.setAppPreferredLanguage(sysLang);
    } else if (lang === 'zh') {
      i18n.System.setAppPreferredLanguage('zh-Hans');
    } else if (lang === 'zh-TW') {
      i18n.System.setAppPreferredLanguage('zh-Hant');
    } else if (lang === 'en') {
      i18n.System.setAppPreferredLanguage('en-US');
    } else {
      i18n.System.setAppPreferredLanguage(lang);
    }
  } catch (_e) {
    logger.warn('setAppPreferredLanguage failed');
  }
}

export function setTheme(mode: string): void {
  theme = mode;
  preferencesRepo.setString(KEY_THEME, mode);
  applyThemeToApp(mode);
  notifyChange();
}

export function getTheme(): string {
  return theme;
}

export function setLocale(lang: string): void {
  locale = lang;
  preferencesRepo.setString(KEY_LOCALE, lang);
  applyLocaleToApp(lang);
  notifyChange();
}

export function getLocale(): string {
  return locale;
}

export function setEnableAnimations(enabled: boolean): void {
  enableAnimations = enabled;
  preferencesRepo.setBoolean(KEY_ENABLE_ANIMATIONS, enabled);
  notifyChange();
}

export function isEnableAnimations(): boolean {
  return enableAnimations;
}

export function setHideTabBarOnScroll(enabled: boolean): void {
  hideTabBarOnScroll = enabled;
  preferencesRepo.setBoolean(KEY_HIDE_TAB_BAR_ON_SCROLL, enabled);
  notifyChange();
}

export function isHideTabBarOnScroll(): boolean {
  return hideTabBarOnScroll;
}

// ── 自动确认下载请求（仅 Web 分享下载生效） ──

export function setAutoAcceptWebDownload(enabled: boolean): void {
  autoAcceptWebDownload = enabled;
  preferencesRepo.setBoolean(KEY_AUTO_ACCEPT_WEB_DOWNLOAD, enabled);
  notifyChange();
}

export function getAutoAcceptWebDownload(): boolean {
  return autoAcceptWebDownload;
}

// ── 校验和设置 ──

export function setCreateChecksums(enabled: boolean): void {
  createChecksums = enabled;
  preferencesRepo.setBoolean(KEY_CREATE_CHECKSUMS, enabled);
  notifyChange();
}

export function isCreateChecksums(): boolean {
  return createChecksums;
}

export function setVerifyChecksums(enabled: boolean): void {
  verifyChecksums = enabled;
  preferencesRepo.setBoolean(KEY_VERIFY_CHECKSUMS, enabled);
  notifyChange();
}

export function isVerifyChecksums(): boolean {
  return verifyChecksums;
}

// ── 发送设置 ──

export function setSendMode(mode: SendMode): void {
  sendMode = mode;
  preferencesRepo.setString(KEY_SEND_MODE, mode);
  notifyChange();
}

export function getSendMode(): SendMode {
  return sendMode;
}

export function setAdvancedSettings(enabled: boolean): void {
  advancedSettings = enabled;
  preferencesRepo.setBoolean(KEY_ADVANCED_SETTINGS, enabled);
  notifyChange();
}

export function isAdvancedSettings(): boolean {
  return advancedSettings;
}

// ── 网络设置 ──

export function setPort(p: number): void {
  port = p;
  preferencesRepo.setNumber(KEY_PORT, p);
  markServerNeedsRestart();
  notifyChange();
}

export function getPort(): number {
  return port;
}

export function setMulticastGroup(group: string): void {
  multicastGroup = group;
  preferencesRepo.setString(KEY_MULTICAST_GROUP, group);
  markServerNeedsRestart();
  notifyChange();
}

export function getMulticastGroup(): string {
  return multicastGroup;
}

export function setDiscoveryTimeout(timeout: number): void {
  discoveryTimeout = timeout;
  preferencesRepo.setNumber(KEY_DISCOVERY_TIMEOUT, timeout);
  markServerNeedsRestart();
  notifyChange();
}

export function getDiscoveryTimeout(): number {
  return discoveryTimeout;
}

export function setNetworkWhitelist(list: string): void {
  logger.debug('\'' + list + '\'');
  preferencesRepo.setString(KEY_NETWORK_WHITELIST, list);
  notifyChange();
}

export function getNetworkWhitelist(): string {
  return preferencesRepo.getString(KEY_NETWORK_WHITELIST, '');
}

export function setNetworkBlacklist(list: string): void {
  logger.debug('\'' + list + '\'');
  preferencesRepo.setString(KEY_NETWORK_BLACKLIST, list);
  notifyChange();
}

export function getNetworkBlacklist(): string {
  return preferencesRepo.getString(KEY_NETWORK_BLACKLIST, '');
}

// ── 网络列表辅助（逗号分隔字符串 → Array<string>） ──

export function getNetworkListAsArray(key: string): Array<string> | undefined {
  let raw: string = preferencesRepo.getString(key, '');
  if (raw.length === 0) {
    return undefined;
  }
  let parts: Array<string> = raw.split(',');
  let result: Array<string> = [];
  for (let i = 0; i < parts.length; i++) {
    let trimmed: string = parts[i].trim();
    if (trimmed.length > 0) {
      result.push(trimmed);
    }
  }
  return result.length > 0 ? result : undefined;
}

// 确保白名单/黑名单有默认值：首次启动时（两者都为空），
// 根据当前接口类型自动设置——wifi/ethernet 入白名单，其他入黑名单。
// 必须在 updateLocalInterfaces() 之后调用（依赖接口列表数据）。
export function ensureDefaultNetworkLists(interfaces: Array<NetworkInterface>): void {
  let currentWhitelist = getNetworkWhitelist();
  let currentBlacklist = getNetworkBlacklist();
  if (currentWhitelist.length > 0 || currentBlacklist.length > 0) {
    // 已有配置，不覆盖
    return;
  }
  let whitelistNames: Array<string> = [];
  let blacklistNames: Array<string> = [];
  for (let i = 0; i < interfaces.length; i++) {
    let name = interfaces[i].name;
    if (name.length === 0) {
      continue;
    }
    let ifaceType = interfaces[i].type;
    if (ifaceType === NetworkType.wifi || ifaceType === NetworkType.ethernet) {
      whitelistNames.push(name);
    } else {
      blacklistNames.push(name);
    }
  }
  setNetworkWhitelist(whitelistNames.join(','));
  setNetworkBlacklist(blacklistNames.join(','));
  logger.debug('首次初始化: 白名单=[' +
    whitelistNames.join(', ') + '] 黑名单=[' + blacklistNames.join(', ') + ']');
}
