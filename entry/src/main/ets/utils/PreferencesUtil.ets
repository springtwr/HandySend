import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { getLogger } from './Logger';
import { LogDomains } from '../common/LogDomains';

// ── 偏好存储名 ──
// 应用设置（含设备身份、网络名单、收藏）与历史（任务历史、文件接收历史）
// 分文件存储：历史为高频写、体积随条目增长，与设置的低频小写入隔离，
// 避免历史落盘抖动影响设置可用性，也便于独立清理。
const SETTINGS_STORE_NAME: string = 'handysend_settings';
const SESSION_HISTORY_STORE_NAME: string = 'handysend_session_history';
const RECEIVE_HISTORY_STORE_NAME: string = 'handysend_receive_history';
const FLUSH_DELAY_MS: number = 500;

// ── 设置键常量 ──
export const KEY_ENCRYPTED_TRANSFER: string = 'encryptedTransfer';


export const KEY_AUTO_CONFIRM_MODE: string = 'autoConfirmMode';

export const KEY_RECEIVE_PIN: string = 'receivePin';

export const KEY_SAVE_TO_GALLERY: string = 'saveToGallery';

export const KEY_DESTINATION: string = 'destination';

// 接收文件保存目录 URI：空串表示默认 Download/<包名>/
export const KEY_RECEIVE_DIRECTORY_URI: string = 'receiveDirectoryUri';

export const KEY_THEME: string = 'theme';

export const KEY_LOCALE: string = 'locale';

export const KEY_HIDE_TAB_BAR_ON_SCROLL: string = 'hideTabBarOnScroll';

export const KEY_CREATE_CHECKSUMS: string = 'createChecksums';

export const KEY_VERIFY_CHECKSUMS: string = 'verifyChecksums';

export const KEY_ADVANCED_SETTINGS: string = 'advancedSettings';

export const KEY_PORT: string = 'port';

export const KEY_MULTICAST_GROUP: string = 'multicastGroup';

export const KEY_DISCOVERY_TIMEOUT: string = 'discoveryTimeout';

export const KEY_NETWORK_WHITELIST: string = 'networkWhitelist';

export const KEY_NETWORK_BLACKLIST: string = 'networkBlacklist';

export const KEY_CUSTOM_ALIAS: string = 'customAlias';

export const KEY_LOCALSEND_ENABLED: string = 'localSendEnabled';

export const KEY_MTA_ENABLED: string = 'mtaEnabled';

export const KEY_WEB_SEND_ENABLED: string = 'webSendEnabled';

export const KEY_WEB_RECEIVE_ENABLED: string = 'webReceiveEnabled';

export const KEY_WEB_HTTPS_ENABLED: string = 'webHttpsEnabled';


export const KEY_WEB_PORT: string = 'webPort';

export const KEY_WEB_INTERFACES: string = 'webInterfaces';

export const KEY_WEB_INTERFACE_BLACKLIST: string = 'webInterfaceBlacklist';

export const KEY_WEB_DISPLAY_ADDRESS: string = 'webDisplayAddress';

export const KEY_MTA_RECEIVE_ENABLED: string = 'mtaReceiveEnabled';

export const KEY_MTA_SIMULATED_BRAND: string = 'mtaSimulatedBrand';

export const KEY_MTA_CONNECTION_WARNINGS: string = 'mtaConnectionWarnings';

// 已提示过的协议关闭状态签名（非用户设置：用于「部分传输方式已关闭」提示只提示一次）
export const KEY_PROTOCOL_HINT_SIGNATURE: string = 'protocolHintSignature';

// 允许后台接收：无传输任务时退后台保留 5 分钟服务窗口
export const KEY_BACKGROUND_RECEIVE: string = 'backgroundReceiveEnabled';

export const KEY_AUTO_CLEAR_STAGED: string = 'autoClearStagedAfterSend';

// ── 在线服务站点 ──
// 用户添加的站点（不含预设）。
export const KEY_PORTAL_USER_SITES: string = 'portalUserSites';
// 预设的本地覆盖：用户编辑过的预设副本。
export const KEY_PORTAL_PRESET_OVERRIDES: string = 'portalPresetOverrides';
// 用户删除过的预设标识，逗号分隔；日常不复活，仅「恢复默认」清空。
export const KEY_PORTAL_DISMISSED: string = 'portalDismissedPresets';
// 是否已确认首次进入远程传输页的风险声明。
export const KEY_PORTAL_RISK_ACCEPTED: string = 'portalRiskAccepted';

const logger = getLogger(LogDomains.SETTINGS, 'HandySend:PreferencesUtil', '偏好');

export class PreferencesUtil {
  private storeName: string;
  private pref: preferences.Preferences | null = null;
  private flushTimer: number = 0;

  constructor(storeName: string) {
    this.storeName = storeName;
  }

  init(context: common.UIAbilityContext): void {
    try {
      this.pref = preferences.getPreferencesSync(context, { name: this.storeName });
    } catch (e) {
      logger.error('偏好存储初始化失败：' + JSON.stringify(e));
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
        let parsed: Object = JSON.parse(value);
        // 形状校验：数组默认值要求解析结果为数组，对象默认值要求为非数组对象；
        // 校验失败回退默认值，避免脏数据导致后续字段访问异常
        if (Array.isArray(defaultValue)) {
          return Array.isArray(parsed) ? parsed as T : defaultValue;
        }
        if (defaultValue !== null && typeof defaultValue === 'object') {
          if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
            return parsed as T;
          }
          return defaultValue;
        }
        return parsed as T;
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
   * 删除一个键（同步）。键不存在时静默返回。
   * 供分段存储淘汰整段使用——以空值占位无法与「已删除」区分。
   */
  delete(key: string): void {
    if (this.pref === null) {
      return;
    }
    if (!this.pref.hasSync(key)) {
      return;
    }
    this.pref.deleteSync(key);
    this.scheduleFlush();
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
    // 必须是同步落盘：调用点位于 onDestroy/onBackground 等进程终止前的同步回调，
    // 无法等待异步 flush 的 Promise，异步刷盘会在进程退出时丢失 pending 写入
    this.pref.flushSync();
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
        // 防抖刷盘为 fire-and-forget：捕获 rejection 避免未处理的 Promise 异常
        this.pref.flush().catch((e: Object): void => {
          logger.warn('偏好刷盘失败：' + String(e));
        });
      }
    }, FLUSH_DELAY_MS);
  }
}

/** 应用设置存储：设置项、设备身份、网络名单、收藏。 */
export const preferencesUtil: PreferencesUtil = new PreferencesUtil(SETTINGS_STORE_NAME);

/** 任务历史存储（会话归档）。 */
export const sessionHistoryPreferencesUtil: PreferencesUtil = new PreferencesUtil(SESSION_HISTORY_STORE_NAME);

/** 文件接收历史存储。 */
export const receiveHistoryPreferencesUtil: PreferencesUtil = new PreferencesUtil(RECEIVE_HISTORY_STORE_NAME);

/** 初始化全部偏好存储（幂等）；应用启动时调用一次。 */
export function initAllPreferences(context: common.UIAbilityContext): void {
  preferencesUtil.init(context);
  sessionHistoryPreferencesUtil.init(context);
  receiveHistoryPreferencesUtil.init(context);
}

/** 立即把全部偏好存储刷写到磁盘（进程终止前等必须持久化的时机）。 */
export function flushAllPreferences(): void {
  preferencesUtil.flushNow();
  sessionHistoryPreferencesUtil.flushNow();
  receiveHistoryPreferencesUtil.flushNow();
}
