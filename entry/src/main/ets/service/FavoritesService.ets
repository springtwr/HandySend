import { common } from '@kit.AbilityKit';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { FavoriteDevice, DiscoveredDevice } from '../model/Types';
import { NativeDeviceChannel } from '../model/NativeTypes';
import { preferencesUtil } from '../utils/PreferencesUtil';

const logger = getLogger(LogDomains.SETTINGS, 'HandySend:FavoritesService');
const FAVORITES_KEY = 'favoriteDevices';
const MAX_FAVORITES = 100;

let favorites: Array<FavoriteDevice> = [];
let changeCallbacks: Array<() => void> = [];

export function initFavorites(context: common.UIAbilityContext): void {
  logger.info('initFavorites');
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
  logger.info('initFavorites: loaded ' + favorites.length + ' favorites');
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
  logger.info('migrateFromOldFormat: migrated ' + result.length + ' favorites');
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
  logger.info('addFavorite: added ' + device.alias);
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
  logger.info('removeFavorite: removed fp=' + fingerprint.substring(0, 10));
}



export function isFavorite(fingerprint: string): boolean {
  for (let i = 0; i < favorites.length; i++) {
    if (favorites[i].fingerprint === fingerprint) {
      return true;
    }
  }
  return false;
}

export function syncAliasFromDiscovery(fingerprint: string, newAlias: string, protocol?: string): void {
  for (let i = 0; i < favorites.length; i++) {
    if (favorites[i].fingerprint === fingerprint && !favorites[i].customAlias) {
      if (favorites[i].alias !== newAlias) {
        favorites[i].alias = newAlias;
      }
      // 更新收藏设备的上次成功协议
      if (protocol !== undefined && protocol.length > 0) {
        favorites[i].lastProtocol = protocol;
      }
      saveFavorites();
      notifyChange();
      return;
    }
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
    customAlias: hasCustomAlias
  };
  addFavorite(fav);
}

export function subscribeFavorites(callback: () => void): void {
  changeCallbacks.push(callback);
}

export function unsubscribeFavorites(callback: () => void): void {
  let idx = -1;
  for (let i = 0; i < changeCallbacks.length; i++) {
    if (changeCallbacks[i] === callback) {
      idx = i;
      break;
    }
  }
  if (idx >= 0) {
    let last = changeCallbacks.length - 1;
    changeCallbacks[idx] = changeCallbacks[last];
    changeCallbacks.pop();
  }
}

function notifyChange(): void {
  for (let i = 0; i < changeCallbacks.length; i++) {
    changeCallbacks[i]();
  }
}

function saveFavorites(): void {
  preferencesUtil.setString(FAVORITES_KEY, JSON.stringify(favorites));
}

/**
 * 将收藏设备转换为 NativeDeviceChannel 数组，供 Rust 发现 discover_staged 使用。
 */
