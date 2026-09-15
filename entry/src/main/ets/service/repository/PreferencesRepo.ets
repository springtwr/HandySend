import {
  preferencesUtil,
  KEY_CUSTOM_ALIAS,
  KEY_CUSTOM_DEVICE_TYPE
} from '../../utils/PreferencesUtil';

/**
 * PreferencesRepo
 * 应用偏好读写的唯一数据访问层。基于 PreferencesUtil 单例。
 * ViewModel 不直接调 PreferencesUtil，统一通过 AppService 门面 → SettingsRepository → PreferencesRepo 间接访问。
 *
 * 基础方法委托 PreferencesUtil；类型化方法内部使用统一 KEY 常量，避免裸字符串键散落各处。
 */
export class PreferencesRepo {
  // ── 基础方法（委托 PreferencesUtil） ──

  getString(key: string, defaultValue: string): string {
    return preferencesUtil.getString(key, defaultValue);
  }

  setString(key: string, value: string): void {
    preferencesUtil.setString(key, value);
  }

  getBoolean(key: string, defaultValue: boolean): boolean {
    return preferencesUtil.getBoolean(key, defaultValue);
  }

  setBoolean(key: string, value: boolean): void {
    preferencesUtil.setBoolean(key, value);
  }

  getNumber(key: string, defaultValue: number): number {
    return preferencesUtil.getNumber(key, defaultValue);
  }

  setNumber(key: string, value: number): void {
    preferencesUtil.setNumber(key, value);
  }

  /**
   * 立即刷写到磁盘（数据必须立刻持久化时调用，如设置关闭加密前）。
   */
  flushNow(): void {
    preferencesUtil.flushNow();
  }

  // ── 类型化便捷方法（内部使用 KEY 常量） ──

  getCustomAlias(): string {
    return preferencesUtil.getString(KEY_CUSTOM_ALIAS, '');
  }

  setCustomAlias(alias: string): void {
    preferencesUtil.setString(KEY_CUSTOM_ALIAS, alias);
  }

  getCustomDeviceType(): string {
    return preferencesUtil.getString(KEY_CUSTOM_DEVICE_TYPE, '');
  }

  setCustomDeviceType(deviceType: string): void {
    preferencesUtil.setString(KEY_CUSTOM_DEVICE_TYPE, deviceType);
  }
}

export const preferencesRepo: PreferencesRepo = new PreferencesRepo();
