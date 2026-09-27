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
  KEY_HIDE_TAB_BAR_ON_SCROLL,
  KEY_CREATE_CHECKSUMS,
  KEY_VERIFY_CHECKSUMS,
  KEY_AUTO_CLEAR_STAGED,
  KEY_ADVANCED_SETTINGS,
  KEY_PORT,
  KEY_MULTICAST_GROUP,
  KEY_DISCOVERY_TIMEOUT,
  KEY_NETWORK_WHITELIST,
  KEY_NETWORK_BLACKLIST,
  KEY_AUTO_ACCEPT_WEB_DOWNLOAD,
  KEY_LOCALSEND_ENABLED,
  KEY_MTA_ENABLED,
  KEY_MTA_RECEIVE_ENABLED,
  KEY_MTA_SIMULATED_BRAND,
  KEY_MTA_CONNECTION_WARNINGS
} from '../../utils/PreferencesUtil';
import { AutoConfirmMode, NetworkType, NetworkInterface } from '../../model/Types';
import { normalizeMtaBrandId } from '../../model/mta/MtaBrandRegistry';
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
  DEFAULT_MTA_CONNECTION_WARNINGS
} from '../../model/SettingsDefaults';
import { getAppContext, notifyChange } from './AppCore';
import { LANGUAGE_LIST } from '../../common/LanguageConstants';

const logger = getLogger(LogDomains.SETTINGS, 'HandySend:SettingsRepository', '设置');

// ── 设置状态（唯一事实来源；Preferences 负责持久化） ──

let httpsEnabled: boolean = DEFAULT_ENCRYPTED_TRANSFER;
let autoConfirmMode: AutoConfirmMode = DEFAULT_AUTO_CONFIRM_MODE;
let receivePin: string = DEFAULT_RECEIVE_PIN;
let autoFinish: boolean = DEFAULT_AUTO_FINISH;
let autoAcceptWebDownload: boolean = DEFAULT_AUTO_ACCEPT_WEB_DOWNLOAD;
let saveToHistory: boolean = DEFAULT_SAVE_TO_HISTORY;
let saveToGallery: boolean = DEFAULT_SAVE_TO_GALLERY;
let destination: string = DEFAULT_DESTINATION;
let theme: string = DEFAULT_THEME;
let locale: string = DEFAULT_LOCALE;
let hideTabBarOnScroll: boolean = DEFAULT_HIDE_TAB_BAR_ON_SCROLL;
let createChecksums: boolean = DEFAULT_CREATE_CHECKSUMS;
let verifyChecksums: boolean = DEFAULT_VERIFY_CHECKSUMS;
let advancedSettings: boolean = DEFAULT_ADVANCED_SETTINGS;
let port: number = DEFAULT_PORT;
let multicastGroup: string = DEFAULT_MULTICAST_GROUP;
let discoveryTimeout: number = DEFAULT_DISCOVERY_TIMEOUT;
let serverNeedsRestart: boolean = false;
let localSendEnabled: boolean = DEFAULT_LOCALSEND_ENABLED;
let mtaEnabled: boolean = DEFAULT_MTA_ENABLED;
let mtaReceiveEnabled: boolean = DEFAULT_MTA_RECEIVE_ENABLED;
let mtaSimulatedBrand: number = DEFAULT_MTA_SIMULATED_BRAND;
let mtaConnectionWarnings: boolean = DEFAULT_MTA_CONNECTION_WARNINGS;

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
  httpsEnabled = preferencesRepo.getBoolean(KEY_ENCRYPTED_TRANSFER, DEFAULT_ENCRYPTED_TRANSFER);

  let savedAutoConfirm: string = preferencesRepo.getString(KEY_AUTO_CONFIRM_MODE, DEFAULT_AUTO_CONFIRM_MODE as string);
  autoConfirmMode = (savedAutoConfirm === 'off' || savedAutoConfirm === 'paired' || savedAutoConfirm === 'on') ?
    savedAutoConfirm as AutoConfirmMode : DEFAULT_AUTO_CONFIRM_MODE;

  receivePin = preferencesRepo.getString(KEY_RECEIVE_PIN, DEFAULT_RECEIVE_PIN);
  autoFinish = preferencesRepo.getBoolean(KEY_AUTO_FINISH, DEFAULT_AUTO_FINISH);
  autoAcceptWebDownload = preferencesRepo.getBoolean(KEY_AUTO_ACCEPT_WEB_DOWNLOAD, DEFAULT_AUTO_ACCEPT_WEB_DOWNLOAD);
  saveToHistory = preferencesRepo.getBoolean(KEY_SAVE_TO_HISTORY, DEFAULT_SAVE_TO_HISTORY);
  saveToGallery = preferencesRepo.getBoolean(KEY_SAVE_TO_GALLERY, DEFAULT_SAVE_TO_GALLERY);
  destination = preferencesRepo.getString(KEY_DESTINATION, DEFAULT_DESTINATION);
  theme = preferencesRepo.getString(KEY_THEME, DEFAULT_THEME);
  locale = preferencesRepo.getString(KEY_LOCALE, DEFAULT_LOCALE);
  hideTabBarOnScroll = preferencesRepo.getBoolean(KEY_HIDE_TAB_BAR_ON_SCROLL, DEFAULT_HIDE_TAB_BAR_ON_SCROLL);
  createChecksums = preferencesRepo.getBoolean(KEY_CREATE_CHECKSUMS, DEFAULT_CREATE_CHECKSUMS);
  verifyChecksums = preferencesRepo.getBoolean(KEY_VERIFY_CHECKSUMS, DEFAULT_VERIFY_CHECKSUMS);
  advancedSettings = preferencesRepo.getBoolean(KEY_ADVANCED_SETTINGS, DEFAULT_ADVANCED_SETTINGS);
  port = preferencesRepo.getNumber(KEY_PORT, DEFAULT_PORT);
  multicastGroup = preferencesRepo.getString(KEY_MULTICAST_GROUP, DEFAULT_MULTICAST_GROUP);
  discoveryTimeout = preferencesRepo.getNumber(KEY_DISCOVERY_TIMEOUT, DEFAULT_DISCOVERY_TIMEOUT);
  localSendEnabled = preferencesRepo.getBoolean(KEY_LOCALSEND_ENABLED, DEFAULT_LOCALSEND_ENABLED);
  mtaEnabled = preferencesRepo.getBoolean(KEY_MTA_ENABLED, DEFAULT_MTA_ENABLED);
  mtaReceiveEnabled = preferencesRepo.getBoolean(KEY_MTA_RECEIVE_ENABLED, DEFAULT_MTA_RECEIVE_ENABLED);
  // 未注册/越界的持久化值按第三方处理（不写回，避免读取产生副作用）
  mtaSimulatedBrand = normalizeMtaBrandId(
    preferencesRepo.getNumber(KEY_MTA_SIMULATED_BRAND, DEFAULT_MTA_SIMULATED_BRAND));
  mtaConnectionWarnings = preferencesRepo.getBoolean(KEY_MTA_CONNECTION_WARNINGS, DEFAULT_MTA_CONNECTION_WARNINGS);
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

// ── 协议总开关 ──

export function setLocalSendEnabled(enabled: boolean): void {
  localSendEnabled = enabled;
  preferencesRepo.setBoolean(KEY_LOCALSEND_ENABLED, enabled);
  notifyChange();
}

export function getLocalSendEnabled(): boolean {
  return localSendEnabled;
}

export function setMtaEnabled(enabled: boolean): void {
  mtaEnabled = enabled;
  preferencesRepo.setBoolean(KEY_MTA_ENABLED, enabled);
  notifyChange();
}

export function getMtaEnabled(): boolean {
  return mtaEnabled;
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

// 语言应用重入守卫：设置应用语言会触发系统配置变化回调，回调链路若重入语言设置
// 会造成无限递归（栈溢出），故真正调用 setAppPreferredLanguage 期间置位、结束复位。
let applyingLocale: boolean = false;

// 最近一次请求设置的语言（BCP47）：用于判断系统语言是否已应用，避免重复设置触发回调。
let lastRequestedLocaleBcp47: string = '';

// 应用语言偏好到应用上下文。locale 应用逻辑的唯一实现。
// value → BCP47 映射以 LANGUAGE_LIST 为单一数据来源，未登记的值原样透传。
export function applyLocaleToApp(lang: string): void {
  // 重入守卫：正在应用语言时直接返回，避免与配置变化回调互相触发形成递归
  if (applyingLocale) {
    return;
  }
  try {
    let bcp47 = lang;
    if (lang === 'system' || lang === '') {
      // 跟随系统：显式设置当前系统语言，避免 'default' 清除偏好语言需冷启动才生效；
      // 系统语言取不到（为空或调用异常）时回退 'default'，保持原有可用性。
      // 之后系统语言再变化时的持续跟随由 syncSystemLanguageIfFollowing 在回到前台时补偿。
      let systemLang = '';
      try {
        systemLang = i18n.System.getSystemLanguage();
      } catch (_e) {
        logger.warn('getSystemLanguage failed');
      }
      bcp47 = systemLang.length > 0 ? systemLang : 'default';
    } else {
      for (let i = 0; i < LANGUAGE_LIST.length; i++) {
        if (LANGUAGE_LIST[i].value === lang) {
          bcp47 = LANGUAGE_LIST[i].bcp47;
          break;
        }
      }
    }
    applyingLocale = true;
    try {
      i18n.System.setAppPreferredLanguage(bcp47);
      // 记录本次请求设置的语言，供跟随系统同步比对，避免重复设置
      lastRequestedLocaleBcp47 = bcp47;
    } finally {
      // 无论成功与否都复位，保证后续调用不被误拦截
      applyingLocale = false;
    }
  } catch (_e) {
    logger.warn('setAppPreferredLanguage failed');
  }
}

// 系统语言变化补偿：仅在用户选择「跟随系统」（locale 为空）时，把新的系统语言重新应用，
// 使应用在切换回跟随系统后仍持续跟随系统语言。非跟随系统、系统语言为空、或语言已应用
// 时均不做任何事；调用由 EntryAbility.onForeground 触发（不放在 onConfigurationUpdate 内，
// 以免与 setAppPreferredLanguage 触发的配置回调形成递归）。
export function syncSystemLanguageIfFollowing(): void {
  // 重入守卫：正在应用语言时直接返回，不重复设置
  if (applyingLocale) {
    logger.debug('sysLangSync: 跳过（正在应用语言，重入守卫）');
    return;
  }
  let currentLocale = getLocale();
  if (currentLocale !== '') {
    // 用户未选择「跟随系统」，此处不应同步，打一条说明便于比对
    logger.debug('sysLangSync: 跳过（非跟随系统）locale=\'' + currentLocale + '\'');
    return;
  }
  try {
    let systemLang = i18n.System.getSystemLanguage();
    if (systemLang.length === 0) {
      logger.debug('sysLangSync: 跳过（系统语言为空）systemLang=\'\'');
      return;
    }
    // 仅用于诊断：提前取一次当前已设语言以便聚合打印（读取无副作用，判定条件不变）
    let appPreferred = i18n.System.getAppPreferredLanguage();
    logger.debug('sysLangSync: locale=\'\' systemLang=\'' + systemLang +
      '\' appPreferred=\'' + appPreferred + '\' lastRequested=\'' + lastRequestedLocaleBcp47 + '\'');
    // 防回环：系统语言与"最近一次请求设置的语言"相同，或与当前已设语言相同，均无需重复设置
    if (lastRequestedLocaleBcp47 === systemLang) {
      logger.debug('sysLangSync: 跳过（与最近一次请求设置的语言相同）');
      return;
    }
    if (appPreferred === systemLang) {
      logger.debug('sysLangSync: 跳过（与当前已设语言相同）');
      return;
    }
    applyingLocale = true;
    try {
      i18n.System.setAppPreferredLanguage(systemLang);
      lastRequestedLocaleBcp47 = systemLang;
      logger.info('sysLangSync: 已应用系统语言 \'' + systemLang + '\'');
    } finally {
      applyingLocale = false;
    }
  } catch (_e) {
    logger.warn('syncSystemLanguageIfFollowing failed');
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

/** 发送成功后是否自动清空暂存内容（默认关闭：暂存保留以支持连续发送）。 */
export function setAutoClearStagedAfterSend(enabled: boolean): void {
  preferencesRepo.setBoolean(KEY_AUTO_CLEAR_STAGED, enabled);
  notifyChange();
}

export function isAutoClearStagedAfterSend(): boolean {
  return preferencesRepo.getBoolean(KEY_AUTO_CLEAR_STAGED, DEFAULT_AUTO_CLEAR_STAGED);
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
  return preferencesRepo.getString(KEY_NETWORK_WHITELIST, DEFAULT_NETWORK_WHITELIST);
}

export function setNetworkBlacklist(list: string): void {
  logger.debug('\'' + list + '\'');
  preferencesRepo.setString(KEY_NETWORK_BLACKLIST, list);
  notifyChange();
}

export function getNetworkBlacklist(): string {
  return preferencesRepo.getString(KEY_NETWORK_BLACKLIST, DEFAULT_NETWORK_BLACKLIST);
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
