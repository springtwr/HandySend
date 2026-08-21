import { ConfigurationConstant } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { preferencesUtil, KEY_ENCRYPTED_TRANSFER, KEY_AUTO_CONFIRM_MODE, KEY_RECEIVE_PIN, KEY_AUTO_FINISH,
  KEY_SAVE_TO_HISTORY, KEY_SAVE_TO_GALLERY, KEY_DESTINATION, KEY_THEME,
  KEY_LOCALE, KEY_ENABLE_ANIMATIONS, KEY_HIDE_TAB_BAR_ON_SCROLL,
  KEY_CREATE_CHECKSUMS, KEY_VERIFY_CHECKSUMS, KEY_SEND_MODE,
  KEY_ADVANCED_SETTINGS, KEY_SHARE_VIA_LINK_AUTO_ACCEPT,
  KEY_RECEIVE_VIA_LINK_AUTO_ACCEPT, KEY_PORT, KEY_MULTICAST_GROUP,
  KEY_DISCOVERY_TIMEOUT, KEY_NETWORK_WHITELIST, KEY_NETWORK_BLACKLIST,
  KEY_AUTO_ACCEPT_WEB_DOWNLOAD } from '../../utils/PreferencesUtil';
import { AutoConfirmMode, SendMode } from '../../model/Types';
import { getAppContext, notifyChange } from './AppCore';

const logger = getLogger(LogDomains.SETTINGS, 'HandySend:SettingsRepository');
const DEFAULT_PORT = 53317;

// ── 设置状态（唯一事实来源；Preferences 负责持久化） ──

let httpsEnabled = true;
let autoConfirmMode: AutoConfirmMode = AutoConfirmMode.paired;
let receivePin: string = '';
let autoFinish: boolean = true;
let autoAcceptWebDownload: boolean = true;
let saveToHistory: boolean = true;
let saveToGallery: boolean = true;
let destination: string = '';
let theme: string = 'system';
let locale: string = '';
let enableAnimations: boolean = true;
let hideTabBarOnScroll: boolean = false;
let createChecksums: boolean = true;
let verifyChecksums: boolean = true;
let sendMode: SendMode = SendMode.single;
let advancedSettings: boolean = false;
let shareViaLinkAutoAccept: boolean = false;
let receiveViaLinkAutoAccept: boolean = false;
let port: number = DEFAULT_PORT;
let multicastGroup: string = '224.0.0.167';
let discoveryTimeout: number = 1000;
let serverNeedsRestart: boolean = false;

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
  httpsEnabled = preferencesUtil.getBoolean(KEY_ENCRYPTED_TRANSFER, true);

  let savedAutoConfirm: string = preferencesUtil.getString(KEY_AUTO_CONFIRM_MODE, 'paired');
  autoConfirmMode = (savedAutoConfirm === 'off' || savedAutoConfirm === 'paired' || savedAutoConfirm === 'on') ?
    savedAutoConfirm as AutoConfirmMode : AutoConfirmMode.paired;

  receivePin = preferencesUtil.getString(KEY_RECEIVE_PIN, '');
  autoFinish = preferencesUtil.getBoolean(KEY_AUTO_FINISH, true);
  autoAcceptWebDownload = preferencesUtil.getBoolean(KEY_AUTO_ACCEPT_WEB_DOWNLOAD, true);
  saveToHistory = preferencesUtil.getBoolean(KEY_SAVE_TO_HISTORY, true);
  saveToGallery = preferencesUtil.getBoolean(KEY_SAVE_TO_GALLERY, true);
  destination = preferencesUtil.getString(KEY_DESTINATION, '');
  theme = preferencesUtil.getString(KEY_THEME, 'system');
  locale = preferencesUtil.getString(KEY_LOCALE, '');
  enableAnimations = preferencesUtil.getBoolean(KEY_ENABLE_ANIMATIONS, true);
  hideTabBarOnScroll = preferencesUtil.getBoolean(KEY_HIDE_TAB_BAR_ON_SCROLL, false);
  createChecksums = preferencesUtil.getBoolean(KEY_CREATE_CHECKSUMS, true);
  verifyChecksums = preferencesUtil.getBoolean(KEY_VERIFY_CHECKSUMS, true);
  let savedSendMode: string = preferencesUtil.getString(KEY_SEND_MODE, 'single');
  sendMode = (savedSendMode === 'single' || savedSendMode === 'multiple' || savedSendMode === 'link') ?
    savedSendMode as SendMode : SendMode.single;
  advancedSettings = preferencesUtil.getBoolean(KEY_ADVANCED_SETTINGS, false);
  shareViaLinkAutoAccept = preferencesUtil.getBoolean(KEY_SHARE_VIA_LINK_AUTO_ACCEPT, false);
  receiveViaLinkAutoAccept = preferencesUtil.getBoolean(KEY_RECEIVE_VIA_LINK_AUTO_ACCEPT, false);
  port = preferencesUtil.getNumber(KEY_PORT, DEFAULT_PORT);
  multicastGroup = preferencesUtil.getString(KEY_MULTICAST_GROUP, '224.0.0.167');
  discoveryTimeout = preferencesUtil.getNumber(KEY_DISCOVERY_TIMEOUT, 1000);
}

// ── 加密 / HTTPS ──

export function setHttpsEnabled(enabled: boolean): void {
  logger.debug('[setHttpsEnabled] ' + httpsEnabled.toString() + ' → ' + enabled.toString());
  httpsEnabled = enabled;
  // 立即持久化，避免应用退出时丢失设置
  preferencesUtil.setBoolean(KEY_ENCRYPTED_TRANSFER, enabled);
  preferencesUtil.flushNow();
  logger.debug('[setHttpsEnabled] persisted: key=' + KEY_ENCRYPTED_TRANSFER + ' value=' + enabled.toString() + ' flushed');
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
  preferencesUtil.setString(KEY_AUTO_CONFIRM_MODE, mode);
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
  preferencesUtil.setString(KEY_RECEIVE_PIN, pin);
  // PIN 变更需要重启服务器
  markServerNeedsRestart();
  notifyChange();
}

export function setAutoFinish(enabled: boolean): void {
  autoFinish = enabled;
  preferencesUtil.setBoolean(KEY_AUTO_FINISH, enabled);
  notifyChange();
}

export function isAutoFinish(): boolean {
  return autoFinish;
}

export function setSaveToHistory(enabled: boolean): void {
  saveToHistory = enabled;
  preferencesUtil.setBoolean(KEY_SAVE_TO_HISTORY, enabled);
  notifyChange();
}

export function isSaveToHistory(): boolean {
  return saveToHistory;
}

export function setSaveToGallery(enabled: boolean): void {
  saveToGallery = enabled;
  preferencesUtil.setBoolean(KEY_SAVE_TO_GALLERY, enabled);
  notifyChange();
}

export function isSaveToGallery(): boolean {
  return saveToGallery;
}

export function setDestination(path: string): void {
  destination = path;
  preferencesUtil.setString(KEY_DESTINATION, path);
  notifyChange();
}

export function getDestination(): string {
  return destination;
}

// ── 主题 / 语言 / 外观 ──

export function setTheme(mode: string): void {
  theme = mode;
  preferencesUtil.setString(KEY_THEME, mode);
  // 根据主题设置应用系统颜色模式
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
    logger.warn('setTheme: applyColorMode failed');
  }
  notifyChange();
}

export function getTheme(): string {
  return theme;
}

export function setLocale(lang: string): void {
  locale = lang;
  preferencesUtil.setString(KEY_LOCALE, lang);
  // 通过 i18n API 应用语言设置
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
  notifyChange();
}

export function getLocale(): string {
  return locale;
}

export function setEnableAnimations(enabled: boolean): void {
  enableAnimations = enabled;
  preferencesUtil.setBoolean(KEY_ENABLE_ANIMATIONS, enabled);
  notifyChange();
}

export function isEnableAnimations(): boolean {
  return enableAnimations;
}

export function setHideTabBarOnScroll(enabled: boolean): void {
  hideTabBarOnScroll = enabled;
  preferencesUtil.setBoolean(KEY_HIDE_TAB_BAR_ON_SCROLL, enabled);
  notifyChange();
}

export function isHideTabBarOnScroll(): boolean {
  return hideTabBarOnScroll;
}

// ── 自动确认下载请求（仅 Web 分享下载生效） ──

export function setAutoAcceptWebDownload(enabled: boolean): void {
  autoAcceptWebDownload = enabled;
  preferencesUtil.setBoolean(KEY_AUTO_ACCEPT_WEB_DOWNLOAD, enabled);
  notifyChange();
}

export function getAutoAcceptWebDownload(): boolean {
  return autoAcceptWebDownload;
}

// ── 校验和设置 ──

export function setCreateChecksums(enabled: boolean): void {
  createChecksums = enabled;
  preferencesUtil.setBoolean(KEY_CREATE_CHECKSUMS, enabled);
  notifyChange();
}

export function isCreateChecksums(): boolean {
  return createChecksums;
}

export function setVerifyChecksums(enabled: boolean): void {
  verifyChecksums = enabled;
  preferencesUtil.setBoolean(KEY_VERIFY_CHECKSUMS, enabled);
  notifyChange();
}

export function isVerifyChecksums(): boolean {
  return verifyChecksums;
}

// ── 发送设置 ──

export function setSendMode(mode: SendMode): void {
  sendMode = mode;
  preferencesUtil.setString(KEY_SEND_MODE, mode);
  notifyChange();
}

export function getSendMode(): SendMode {
  return sendMode;
}

export function setAdvancedSettings(enabled: boolean): void {
  advancedSettings = enabled;
  preferencesUtil.setBoolean(KEY_ADVANCED_SETTINGS, enabled);
  notifyChange();
}

export function isAdvancedSettings(): boolean {
  return advancedSettings;
}

export function setShareViaLinkAutoAccept(enabled: boolean): void {
  shareViaLinkAutoAccept = enabled;
  preferencesUtil.setBoolean(KEY_SHARE_VIA_LINK_AUTO_ACCEPT, enabled);
  notifyChange();
}

export function getShareViaLinkAutoAccept(): boolean {
  return shareViaLinkAutoAccept;
}

export function setReceiveViaLinkAutoAccept(enabled: boolean): void {
  receiveViaLinkAutoAccept = enabled;
  preferencesUtil.setBoolean(KEY_RECEIVE_VIA_LINK_AUTO_ACCEPT, enabled);
  notifyChange();
}

export function getReceiveViaLinkAutoAccept(): boolean {
  return receiveViaLinkAutoAccept;
}

// ── 网络设置 ──

export function setPort(p: number): void {
  port = p;
  preferencesUtil.setNumber(KEY_PORT, p);
  markServerNeedsRestart();
  notifyChange();
}

export function getPort(): number {
  return port;
}

export function setMulticastGroup(group: string): void {
  multicastGroup = group;
  preferencesUtil.setString(KEY_MULTICAST_GROUP, group);
  markServerNeedsRestart();
  notifyChange();
}

export function getMulticastGroup(): string {
  return multicastGroup;
}

export function setDiscoveryTimeout(timeout: number): void {
  discoveryTimeout = timeout;
  preferencesUtil.setNumber(KEY_DISCOVERY_TIMEOUT, timeout);
  markServerNeedsRestart();
  notifyChange();
}

export function getDiscoveryTimeout(): number {
  return discoveryTimeout;
}

export function setNetworkWhitelist(list: string): void {
  preferencesUtil.setString(KEY_NETWORK_WHITELIST, list);
  markServerNeedsRestart();
  notifyChange();
}

export function getNetworkWhitelist(): string {
  return preferencesUtil.getString(KEY_NETWORK_WHITELIST, '');
}

export function setNetworkBlacklist(list: string): void {
  preferencesUtil.setString(KEY_NETWORK_BLACKLIST, list);
  markServerNeedsRestart();
  notifyChange();
}

export function getNetworkBlacklist(): string {
  return preferencesUtil.getString(KEY_NETWORK_BLACKLIST, '');
}

// ── 网络列表辅助（逗号分隔字符串 → Array<string>） ──

export function getNetworkListAsArray(key: string): Array<string> | undefined {
  let raw: string = preferencesUtil.getString(key, '');
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
