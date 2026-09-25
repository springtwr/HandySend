import { common } from '@kit.AbilityKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { FavoriteDevice, DiscoveredDevice } from '../../model/Types';
import { nativeDiscoveryGetDevice } from '../NativeBridge';
import { preferencesUtil } from '../../utils/PreferencesUtil';
import { EventBus } from '../../utils/EventBus';

const logger = getLogger(LogDomains.SETTINGS, 'HandySend:FavoritesService', '收藏');
const FAVORITES_KEY = 'favoriteDevices';
const MAX_FAVORITES = 100;

let favorites: Array<FavoriteDevice> = [];
const changeBus: EventBus = new EventBus();

export function initFavorites(context: common.UIAbilityContext): void {
  logger.debug('initFavorites');
  // 确保读写前 preferences 已初始化
  preferencesUtil.init(context);
  let raw: string = preferencesUtil.getString(FAVORITES_KEY, '[]');
  try {
    let parsed: Object = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      // 区分旧格式（字符串数组）与新格式（对象数组）
      let needsMigration = false;
      if (parsed.length > 0 && typeof parsed[0] === 'string') {
        needsMigration = true;
      }
      if (needsMigration) {
        favorites = migrateFromOldFormat(parsed as Array<string>);
        saveFavorites();
      } else {
        favorites = parsed as Array<FavoriteDevice>;
      }
    } else {
      favorites = [];
    }
  } catch (_e) {
    favorites = [];
  }
  logger.debug('loaded ' + favorites.length + ' favorites');
  notifyChange();
}

function migrateFromOldFormat(oldList: Array<string>): Array<FavoriteDevice> {
  let result: Array<FavoriteDevice> = [];
  for (let i = 0; i < oldList.length; i++) {
    let fp: string = oldList[i];
    result.push({
      id: Date.now().toString() + '_' + i,
      fingerprint: fp,
      ip: '',
      port: 53317,
      alias: fp.substring(0, Math.min(fp.length, 12)),
      customAlias: false
    });
  }
  logger.debug('migrated ' + result.length + ' favorites');
  return result;
}

export function getFavorites(): Array<FavoriteDevice> {
  return favorites;
}

export function addFavorite(device: FavoriteDevice): void {
  // 按指纹检查重复
  for (let i = 0; i < favorites.length; i++) {
    if (favorites[i].fingerprint === device.fingerprint) {
      // 更新已有设备
      favorites[i] = device;
      saveFavorites();
      notifyChange();
      return;
    }
  }
  if (favorites.length >= MAX_FAVORITES) {
    favorites.shift();
  }
  favorites.push(device);
  saveFavorites();
  notifyChange();
  logger.debug('added ' + device.alias);
}


export function removeFavorite(fingerprint: string): void {
  let updated: Array<FavoriteDevice> = [];
  for (let i = 0; i < favorites.length; i++) {
    if (favorites[i].fingerprint !== fingerprint) {
      updated.push(favorites[i]);
    }
  }
  favorites = updated;
  saveFavorites();
  notifyChange();
  logger.debug('removed fp=' + fingerprint.substring(0, 10));
}


export function isFavorite(fingerprint: string): boolean {
  for (let i = 0; i < favorites.length; i++) {
    if (favorites[i].fingerprint === fingerprint) {
      return true;
    }
  }
  return false;
}

// 重命名收藏设备别名：写入自定义别名并置 customAlias，持久化并通知订阅者；
// 空白（或纯空白）别名不处理，保持原别名不变。
export function renameFavorite(fingerprint: string, alias: string): void {
  let trimmed: string = alias.trim();
  if (trimmed.length === 0) {
    return;
  }
  for (let i = 0; i < favorites.length; i++) {
    if (favorites[i].fingerprint === fingerprint) {
      favorites[i].alias = trimmed;
      favorites[i].customAlias = true;
      saveFavorites();
      notifyChange();
      logger.debug('renamed fp=' + fingerprint.substring(0, 10));
      return;
    }
  }
}

// 恢复默认别名：将别名还原为最近一次广播别名并清除自定义标记；
// broadcastAlias 不可得（历史记录尚未在线同步过）时不处理。
export function restoreDefaultAlias(fingerprint: string): void {
  for (let i = 0; i < favorites.length; i++) {
    if (favorites[i].fingerprint === fingerprint) {
      let broadcast: string | undefined = favorites[i].broadcastAlias;
      if (broadcast === undefined || broadcast.length === 0) {
        return;
      }
      favorites[i].alias = broadcast;
      favorites[i].customAlias = false;
      saveFavorites();
      notifyChange();
      logger.debug('restored default alias fp=' + fingerprint.substring(0, 10));
      return;
    }
  }
}

// 是否可恢复默认别名（broadcastAlias 非空）；供视图对「恢复默认别名」置灰。
export function canRestoreDefaultAlias(fingerprint: string): boolean {
  for (let i = 0; i < favorites.length; i++) {
    if (favorites[i].fingerprint === fingerprint) {
      let broadcast: string | undefined = favorites[i].broadcastAlias;
      return broadcast !== undefined && broadcast.length > 0;
    }
  }
  return false;
}

// 按指纹集合批量移除收藏，持久化并通知一次；集合为空或无命中时不产生变更。
export function removeFavorites(fingerprints: Array<string>): void {
  if (fingerprints.length === 0) {
    return;
  }
  let updated: Array<FavoriteDevice> = [];
  let removedCount: number = 0;
  for (let i = 0; i < favorites.length; i++) {
    if (fingerprints.indexOf(favorites[i].fingerprint) >= 0) {
      removedCount++;
    } else {
      updated.push(favorites[i]);
    }
  }
  if (removedCount === 0) {
    return;
  }
  favorites = updated;
  saveFavorites();
  notifyChange();
  logger.debug('removed ' + removedCount + ' favorites');
}

// 从发现信息同步整条收藏记录：已收藏设备上线被 device_found 命中时，
// 随实时发现快照刷新其全部可变属性——别名（受自定义保护）/协议/型号/类型/版本/IP/端口。
export function syncFavoriteFromDiscovery(fingerprint: string, newAlias: string, protocol?: string): void {
  for (let i = 0; i < favorites.length; i++) {
    // 命中指纹即处理并返回；alias 的 !customAlias 保护只作用于别名字段，
    // 型号/类型/版本的刷新不受 customAlias 影响
    if (favorites[i].fingerprint === fingerprint) {
      // 别名同步维持既有保护规则：自定义别名不被广播别名覆盖
      if (!favorites[i].customAlias && favorites[i].alias !== newAlias) {
        favorites[i].alias = newAlias;
      }
      // 广播别名始终记录（与 customAlias 保护无关，非空才覆盖）：
      // 供设备离线时执行「恢复默认别名」
      if (newAlias.length > 0) {
        favorites[i].broadcastAlias = newAlias;
      }
      // 更新收藏设备的上次成功协议
      if (protocol !== undefined && protocol.length > 0) {
        favorites[i].lastProtocol = protocol;
      }
      // 型号/类型/版本是对端客观属性：无条件尝试从实时发现快照刷新，
      // 但仅当快照对应字段为非空字符串时才覆盖，
      // 防止偶发缺字段的广播把已存数据清洗为空
      let snapshot: DiscoveredDevice | undefined = queryDiscoverySnapshotSafely(fingerprint);
      if (snapshot !== undefined) {
        if (snapshot.deviceModel.length > 0) {
          favorites[i].deviceModel = snapshot.deviceModel;
        }
        if (snapshot.deviceType.length > 0) {
          favorites[i].deviceType = snapshot.deviceType;
        }
        if (snapshot.version.length > 0) {
          favorites[i].version = snapshot.version;
        }
        // IP/端口是对端网络属性：快照字段有效才覆盖（ip 非空字符串、port 大于 0），
        // 异常广播缺字段时不清洗已存地址，保证离线徽标与定向探测始终使用最新可达地址
        if (snapshot.ip.length > 0) {
          favorites[i].ip = snapshot.ip;
        }
        if (snapshot.port > 0) {
          favorites[i].port = snapshot.port;
        }
      }
      saveFavorites();
      notifyChange();
      return;
    }
  }
}

// 从原生发现缓存查询实时设备快照；任何失败（如原生层未就绪）都返回 undefined，
// 保证收藏同步流程不被阻塞。
function queryDiscoverySnapshotSafely(fingerprint: string): DiscoveredDevice | undefined {
  try {
    return nativeDiscoveryGetDevice(fingerprint);
  } catch (_e) {
    return undefined;
  }
}

export function addFavoriteFromDiscovered(device: DiscoveredDevice, customAlias?: string): void {
  let aliasToUse: string = device.alias;
  let hasCustomAlias: boolean = false;
  if (customAlias !== undefined && customAlias.length > 0 && customAlias !== device.alias) {
    aliasToUse = customAlias;
    hasCustomAlias = true;
  }
  let fav: FavoriteDevice = {
    id: Date.now().toString() + '_' + Math.floor(Math.random() * 10000),
    fingerprint: device.fingerprint,
    ip: device.ip,
    port: device.port,
    alias: aliasToUse,
    customAlias: hasCustomAlias,
    // 收藏时刻的广播别名即设备当前广播名，作为「恢复默认别名」的还原目标
    broadcastAlias: device.alias,
    // 型号/类型/版本来自发现快照（DiscoveredDevice 中为必填 string），随收藏记录持久化，
    // 供设备离线后渲染型号徽标/类型图标及详情页版本号
    deviceModel: device.deviceModel,
    deviceType: device.deviceType,
    version: device.version
  };
  addFavorite(fav);
}

export function subscribeFavorites(callback: () => void): void {
  changeBus.subscribe(callback);
}

export function unsubscribeFavorites(callback: () => void): void {
  changeBus.unsubscribe(callback);
}

function notifyChange(): void {
  changeBus.notifyChange();
}

function saveFavorites(): void {
  preferencesUtil.setString(FAVORITES_KEY, JSON.stringify(favorites));
}
