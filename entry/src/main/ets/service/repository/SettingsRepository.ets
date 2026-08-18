import { ConfigurationConstant } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferencesUtil, KEY_ENCRYPTED_TRANSFER, KEY_AUTO_SAVE_MODE, KEY_RECEIVE_PIN, KEY_AUTO_FINISH,
  KEY_SAVE_TO_HISTORY, KEY_SAVE_TO_GALLERY, KEY_DESTINATION, KEY_THEME,
  KEY_LOCALE, KEY_ENABLE_ANIMATIONS,
  KEY_CREATE_CHECKSUMS, KEY_VERIFY_CHECKSUMS, KEY_SEND_MODE,
  KEY_ADVANCED_SETTINGS, KEY_SHARE_VIA_LINK_AUTO_ACCEPT,
  KEY_RECEIVE_VIA_LINK_AUTO_ACCEPT, KEY_PORT, KEY_MULTICAST_GROUP,
  KEY_DISCOVERY_TIMEOUT, KEY_NETWORK_WHITELIST, KEY_NETWORK_BLACKLIST,
  KEY_HIDE_SHARE_BY_LINK, KEY_SILENT_RECEIVE } from '../../utils/PreferencesUtil';
import { QuickSaveMode, SendMode } from '../../model/Types';
import { getAppContext, notifyChange } from './AppCore';

const TAG = 'LocalSend:SettingsRepository';
const DOMAIN = 0x0001;
const DEFAULT_PORT = 53317;

// ── Settings state (single source of truth; Preferences is the persistence) ──

let httpsEnabled = true;
let quickSaveMode: QuickSaveMode = QuickSaveMode.paired;
let receivePin: string = '';
let autoFinish: boolean = false;
let saveToHistory: boolean = true;
let saveToGallery: boolean = true;
let destination: string = '';
let theme: string = 'system';
let locale: string = '';
let enableAnimations: boolean = true;
let createChecksums: boolean = true;
let verifyChecksums: boolean = true;
let sendMode: SendMode = SendMode.single;
let advancedSettings: boolean = false;
let shareViaLinkAutoAccept: boolean = false;
let receiveViaLinkAutoAccept: boolean = false;
let port: number = DEFAULT_PORT;
let multicastGroup: string = '224.0.0.167';
let discoveryTimeout: number = 3000;
let serverNeedsRestart: boolean = false;

// ── Server-restart flag (shared with ServerRepository) ──

export function markServerNeedsRestart(): void {
  serverNeedsRestart = true;
}

export function clearServerNeedsRestart(): void {
  serverNeedsRestart = false;
}

export function doesServerNeedRestart(): boolean {
  return serverNeedsRestart;
}

// ── Load all settings from Preferences (called once at app startup) ──

export function loadFromPreferences(): void {
  httpsEnabled = preferencesUtil.getBoolean(KEY_ENCRYPTED_TRANSFER, true);

  let savedQuickSave: string = preferencesUtil.getString(KEY_AUTO_SAVE_MODE, 'paired');
  quickSaveMode = (savedQuickSave === 'off' || savedQuickSave === 'paired' || savedQuickSave === 'on') ?
    savedQuickSave as QuickSaveMode : QuickSaveMode.paired;

  receivePin = preferencesUtil.getString(KEY_RECEIVE_PIN, '');
  autoFinish = preferencesUtil.getBoolean(KEY_AUTO_FINISH, false);
  saveToHistory = preferencesUtil.getBoolean(KEY_SAVE_TO_HISTORY, true);
  saveToGallery = preferencesUtil.getBoolean(KEY_SAVE_TO_GALLERY, true);
  destination = preferencesUtil.getString(KEY_DESTINATION, '');
  theme = preferencesUtil.getString(KEY_THEME, 'system');
  locale = preferencesUtil.getString(KEY_LOCALE, '');
  enableAnimations = preferencesUtil.getBoolean(KEY_ENABLE_ANIMATIONS, true);
  createChecksums = preferencesUtil.getBoolean(KEY_CREATE_CHECKSUMS, true);
  verifyChecksums = preferencesUtil.getBoolean(KEY_VERIFY_CHECKSUMS, true);
  let savedSendMode: string = preferencesUtil.getString(KEY_SEND_MODE, 'single');
  sendMode = (savedSendMode === 'single' || savedSendMode === 'multiple' || savedSendMode === 'link') ?
    savedSendMode as SendMode : SendMode.single;
  // If persisted mode is 'link' but link sharing is hidden, fall back to 'single'
  if (sendMode === SendMode.link && preferencesUtil.getBoolean(KEY_HIDE_SHARE_BY_LINK, false)) {
    sendMode = SendMode.single;
    preferencesUtil.setString(KEY_SEND_MODE, SendMode.single);
  }
  advancedSettings = preferencesUtil.getBoolean(KEY_ADVANCED_SETTINGS, false);
  shareViaLinkAutoAccept = preferencesUtil.getBoolean(KEY_SHARE_VIA_LINK_AUTO_ACCEPT, false);
  receiveViaLinkAutoAccept = preferencesUtil.getBoolean(KEY_RECEIVE_VIA_LINK_AUTO_ACCEPT, false);
  port = preferencesUtil.getNumber(KEY_PORT, DEFAULT_PORT);
  multicastGroup = preferencesUtil.getString(KEY_MULTICAST_GROUP, '224.0.0.167');
  discoveryTimeout = preferencesUtil.getNumber(KEY_DISCOVERY_TIMEOUT, 3000);
}

// ── Encryption / HTTPS ──

export function setHttpsEnabled(enabled: boolean): void {
  hilog.info(DOMAIN, TAG, '[DBG-HTTPS] setHttpsEnabled: %{public}s → %{public}s', httpsEnabled.toString(), enabled.toString());
  httpsEnabled = enabled;
  // Persist immediately to avoid losing the setting on app exit
  preferencesUtil.setBoolean(KEY_ENCRYPTED_TRANSFER, enabled);
  preferencesUtil.flushNow();
  hilog.info(DOMAIN, TAG, '[DBG-HTTPS]   persisted: key=%{public}s value=%{public}s flushed', KEY_ENCRYPTED_TRANSFER, enabled.toString());
  markServerNeedsRestart();
  notifyChange();
}

export function getHttpsEnabled(): boolean {
  return httpsEnabled;
}

export function getEncryptedTransfer(): boolean {
  return httpsEnabled;
}

// ── QuickSave / receive settings ──

export function setQuickSaveMode(mode: QuickSaveMode): void {
  quickSaveMode = mode;
  preferencesUtil.setString(KEY_AUTO_SAVE_MODE, mode);
  notifyChange();
}

export function getAutoSaveMode(): QuickSaveMode {
  return quickSaveMode;
}

export function getReceivePin(): string {
  return receivePin;
}

export function setReceivePin(pin: string): void {
  receivePin = pin;
  preferencesUtil.setString(KEY_RECEIVE_PIN, pin);
  // PIN change requires server restart
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

// ── Theme / locale / appearance ──

export function setTheme(mode: string): void {
  theme = mode;
  preferencesUtil.setString(KEY_THEME, mode);
  // Apply system color mode based on theme setting
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
    hilog.warn(DOMAIN, TAG, 'setTheme: applyColorMode failed');
  }
  notifyChange();
}

export function getTheme(): string {
  return theme;
}

export function setLocale(lang: string): void {
  locale = lang;
  preferencesUtil.setString(KEY_LOCALE, lang);
  // Apply locale via i18n API
  try {
    if (lang === 'system' || lang === '') {
      // Explicitly set system language instead of 'default' for immediate effect
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
    hilog.warn(DOMAIN, TAG, 'setAppPreferredLanguage failed');
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

export function getHideShareByLink(): boolean {
  return preferencesUtil.getBoolean(KEY_HIDE_SHARE_BY_LINK, false);
}

export function getSilentReceive(): boolean {
  return preferencesUtil.getBoolean(KEY_SILENT_RECEIVE, true);
}

// ── Checksum settings ──

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

// ── Send settings ──

export function setSendMode(mode: SendMode): void {
  sendMode = mode;
  preferencesUtil.setString(KEY_SEND_MODE, mode);
  notifyChange();
}

export function getSendMode(): SendMode {
  // If current mode is 'link' but link sharing is hidden, fall back to 'single'
  if (sendMode === SendMode.link) {
    let hideShareByLink: boolean = preferencesUtil.getBoolean(KEY_HIDE_SHARE_BY_LINK, false);
    if (hideShareByLink) {
      sendMode = SendMode.single;
      preferencesUtil.setString(KEY_SEND_MODE, SendMode.single);
    }
  }
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

// ── Network settings ──

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

// ── Network list helper (comma-separated string → Array<string>) ──

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
