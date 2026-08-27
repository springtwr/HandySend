import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { getLogger } from './Logger';
import { LogDomains } from '../common/LogDomains';

const PREF_NAME: string = 'handysend_settings';
const FLUSH_DELAY_MS: number = 500;

// ── 设置键常量 ──
export const KEY_ENCRYPTED_TRANSFER: string = 'encryptedTransfer';

export const KEY_AUTO_ACCEPT_WEB_DOWNLOAD: string = 'autoAcceptWebDownload';

export const KEY_AUTO_CONFIRM_MODE: string = 'autoConfirmMode';

export const KEY_RECEIVE_PIN: string = 'receivePin';

export const KEY_AUTO_FINISH: string = 'autoFinish';

export const KEY_SAVE_TO_HISTORY: string = 'saveToHistory';

export const KEY_SAVE_TO_GALLERY: string = 'saveToGallery';

export const KEY_DESTINATION: string = 'destination';

export const KEY_THEME: string = 'theme';

export const KEY_LOCALE: string = 'locale';

export const KEY_ENABLE_ANIMATIONS: string = 'enableAnimations';

export const KEY_HIDE_TAB_BAR_ON_SCROLL: string = 'hideTabBarOnScroll';

export const KEY_CREATE_CHECKSUMS: string = 'createChecksums';

export const KEY_VERIFY_CHECKSUMS: string = 'verifyChecksums';

export const KEY_SEND_MODE: string = 'sendMode';

export const KEY_ADVANCED_SETTINGS: string = 'advancedSettings';

export const KEY_PORT: string = 'port';

export const KEY_MULTICAST_GROUP: string = 'multicastGroup';

export const KEY_DISCOVERY_TIMEOUT: string = 'discoveryTimeout';

export const KEY_NETWORK_WHITELIST: string = 'networkWhitelist';

export const KEY_NETWORK_BLACKLIST: string = 'networkBlacklist';

export const KEY_CUSTOM_ALIAS: string = 'customAlias';

export const KEY_CUSTOM_DEVICE_TYPE: string = 'customDeviceType';

const logger = getLogger(LogDomains.SETTINGS, 'HandySend:PreferencesUtil');

export class PreferencesUtil {
  private pref: preferences.Preferences | null = null;
  private flushTimer: number = 0;

  init(context: common.UIAbilityContext): void {
    try {
      this.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
    } catch (e) {
      logger.error('PreferencesUtil init error: ' + JSON.stringify(e));
    }
  }

  getBoolean(key: string, defaultValue: boolean): boolean {
    if (this.pref === null) {
      return defaultValue;
    }
    let value: preferences.ValueType = this.pref.getSync(key, defaultValue);
    return typeof value === 'boolean' ? value : defaultValue;
  }

  setBoolean(key: string, value: boolean): void {
    if (this.pref === null) {
      return;
    }
    this.pref.putSync(key, value);
    this.scheduleFlush();
  }

  getString(key: string, defaultValue: string): string {
    if (this.pref === null) {
      return defaultValue;
    }
    let value: preferences.ValueType = this.pref.getSync(key, defaultValue);
    return typeof value === 'string' ? value : defaultValue;
  }

  setString(key: string, value: string): void {
    if (this.pref === null) {
      return;
    }
    this.pref.putSync(key, value);
    this.scheduleFlush();
  }

  getNumber(key: string, defaultValue: number): number {
    if (this.pref === null) {
      return defaultValue;
    }
    let value: preferences.ValueType = this.pref.getSync(key, defaultValue);
    return typeof value === 'number' ? value : defaultValue;
  }

  setNumber(key: string, value: number): void {
    if (this.pref === null) {
      return;
    }
    this.pref.putSync(key, value);
    this.scheduleFlush();
  }

  getObject<T>(key: string, defaultValue: T): T {
    if (this.pref === null) {
      return defaultValue;
    }
    let value: preferences.ValueType = this.pref.getSync(key, '');
    if (typeof value === 'string' && value.length > 0) {
      try {
        return JSON.parse(value) as T;
      } catch (_e) {
        return defaultValue;
      }
    }
    return defaultValue;
  }

  setObject<T>(key: string, value: T): void {
    if (this.pref === null) {
      return;
    }
    this.pref.putSync(key, JSON.stringify(value));
    this.scheduleFlush();
  }

  has(key: string): boolean {
    if (this.pref === null) {
      return false;
    }
    return this.pref.hasSync(key);
  }

  /**
   * 立即刷写到磁盘。当数据必须立刻持久化时调用
   * （例如在执行破坏性操作或应用挂起之前）。
   */
  flushNow(): void {
    if (this.pref === null) {
      return;
    }
    if (this.flushTimer !== 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = 0;
    }
    this.pref.flush();
  }

  /**
   * 防抖刷新：将 FLUSH_DELAY_MS 内的多次写入合并为
   * 一次性批量写入，降低连续快速更新时的 I/O 开销。
   */
  private scheduleFlush(): void {
    if (this.flushTimer !== 0) {
      return;
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = 0;
      if (this.pref !== null) {
        this.pref.flush();
      }
    }, FLUSH_DELAY_MS);
  }
}

export const preferencesUtil: PreferencesUtil = new PreferencesUtil();
