import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME: string = 'nekoshare_settings';

// ── Settings key constants ──
export const KEY_ENCRYPTED_TRANSFER: string = 'encryptedTransfer';
export const KEY_CUSTOM_ALIAS: string = 'customAlias';
export const KEY_CUSTOM_DEVICE_TYPE: string = 'customDeviceType';
export const KEY_CUSTOM_DEVICE_MODEL: string = 'customDeviceModel';
export const KEY_HIDE_SHARE_BY_LINK: string = 'hideShareByLink';
export const KEY_SILENT_RECEIVE: string = 'silentReceive';
export const KEY_AUTO_SAVE_MODE: string = 'autoSaveMode';
export const KEY_FAVORITE_DEVICES: string = 'favoriteDevices';
export const KEY_RECEIVE_PIN: string = 'receivePin';
export const KEY_AUTO_FINISH: string = 'autoFinish';
export const KEY_SAVE_TO_HISTORY: string = 'saveToHistory';
export const KEY_SAVE_TO_GALLERY: string = 'saveToGallery';
export const KEY_DESTINATION: string = 'destination';
export const KEY_THEME: string = 'theme';
export const KEY_LOCALE: string = 'locale';
export const KEY_ENABLE_ANIMATIONS: string = 'enableAnimations';
export const KEY_CREATE_CHECKSUMS: string = 'createChecksums';
export const KEY_VERIFY_CHECKSUMS: string = 'verifyChecksums';
export const KEY_SEND_MODE: string = 'sendMode';
export const KEY_ADVANCED_SETTINGS: string = 'advancedSettings';
export const KEY_SHARE_VIA_LINK_AUTO_ACCEPT: string = 'shareViaLinkAutoAccept';
export const KEY_RECEIVE_VIA_LINK_AUTO_ACCEPT: string = 'receiveViaLinkAutoAccept';
export const KEY_PORT: string = 'port';
export const KEY_MULTICAST_GROUP: string = 'multicastGroup';
export const KEY_DISCOVERY_TIMEOUT: string = 'discoveryTimeout';
export const KEY_NETWORK_WHITELIST: string = 'networkWhitelist';
export const KEY_NETWORK_BLACKLIST: string = 'networkBlacklist';
export const KEY_RECEIVE_HISTORY: string = 'receiveHistory';
export const KEY_NEKOSHARE_FLOATING: string = 'nekoshare_floating';

export class PreferencesUtil {
  private pref: preferences.Preferences | null = null;

  init(context: common.UIAbilityContext): void {
    try {
      this.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
    } catch (e) {
      console.error('PreferencesUtil init error:', JSON.stringify(e));
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
    this.pref.flush();
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
    this.pref.flush();
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
    this.pref.flush();
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
    this.pref.flush();
  }
}

export const preferencesUtil: PreferencesUtil = new PreferencesUtil();
