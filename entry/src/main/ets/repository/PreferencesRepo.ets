import { preferencesUtil, KEY_LOCALE } from '../utils/PreferencesUtil';

/**
 * PreferencesRepo
 * 持久化偏好的 Model 层封装。基于 PreferencesUtil 单例。
 * ViewModel 不直接调 PreferencesUtil，统一通过 PreferencesRepo 间接访问。
 *
 * 注：当前仅暴露 getLocale。setLocale 的写入路径仍在 AppService.setLocale
 * （内部已调 preferencesUtil.setString）。待 AppService 整改时迁移写入逻辑到此。
 */
export class PreferencesRepo {
  getLocale(): string {
    return preferencesUtil.getString(KEY_LOCALE, '');
  }
}

export const preferencesRepo: PreferencesRepo = new PreferencesRepo();
