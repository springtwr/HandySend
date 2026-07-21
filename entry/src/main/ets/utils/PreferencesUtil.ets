import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME: string = 'nekoshare_settings';

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
}

export const preferencesUtil: PreferencesUtil = new PreferencesUtil();
