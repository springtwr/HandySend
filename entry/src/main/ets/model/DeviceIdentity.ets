/**
 * DeviceIdentity.ets — 跨协议设备身份与收藏键（纯函数）
 *
 * MTA 设备的 BLE 地址会轮换，不能作为收藏主键；发送者 ID（senderIdHex）才是跨会话
 * 稳定的身份（是否稳定由对端实现决定）。收藏键统一为 `mta:<senderId>`，与 LocalSend
 * 的指纹键区分，供收藏服务、附近列表与自动确认判定共用。
 */

import { DiscoveredDevice, FavoriteDevice } from './Types';
import { isMtaDevice } from './mta/MtaMainModels';

/** MTA 收藏键前缀（与 LocalSend 指纹键区分） */
export const MTA_FAVORITE_KEY_PREFIX: string = 'mta:';

/** 发送者 ID 规范化：去首尾空白并转小写（协议按无符号十六进制文本传输，大小写不敏感） */
export function normalizeSenderId(senderId: string): string {
  return senderId.trim().toLowerCase();
}

/**
 * 两个 MTA 发送者 ID 是否指向同一设备（纯函数）。
 *
 * 广播发现提供完整 16 字节设备 ID，而部分对端在 sendRequest 中只上报短设备 ID
 * （完整 ID 的前 2 字节）。此时允许较短一方作为较长一方的前缀匹配，
 * 但要求至少 4 个十六进制字符（2 字节），避免用过短前缀把其他设备误判为目标。
 */
export function mtaSenderIdsMatch(first: string, second: string): boolean {
  let a: string = normalizeSenderId(first);
  let b: string = normalizeSenderId(second);
  if (a.length === 0 || b.length === 0) {
    return false;
  }
  if (a === b) {
    return true;
  }
  let shorter: string = a.length <= b.length ? a : b;
  let longer: string = a.length <= b.length ? b : a;
  return shorter.length >= 4 && longer.startsWith(shorter);
}

/**
 * 设备收藏键（纯函数）：
 * - MTA：优先 `mta:<senderId>`；发送者 ID 缺失时回退 `mta:<BLE 地址>`（仅用于展示/兼容，
 *   调用方应先用 canFavoriteDevice 拦截无稳定身份的收藏）；
 * - LocalSend 等其它来源：沿用原 fingerprint。
 */
export function favoriteKeyOf(device: DiscoveredDevice): string {
  if (isMtaDevice(device)) {
    let senderId: string = normalizeSenderId(device.mtaSenderIdHex ?? '');
    if (senderId.length > 0) {
      return MTA_FAVORITE_KEY_PREFIX + senderId;
    }
    let address: string = normalizeSenderId(device.mtaBleAddress ?? device.fingerprint);
    return address.length > 0 ? MTA_FAVORITE_KEY_PREFIX + address : device.fingerprint;
  }
  return device.fingerprint;
}

/** 设备是否具备可收藏的稳定身份（纯函数）：MTA 必须有发送者 ID；其它来源沿用原规则 */
export function canFavoriteDevice(device: DiscoveredDevice): boolean {
  if (!isMtaDevice(device)) {
    return true;
  }
  return normalizeSenderId(device.mtaSenderIdHex ?? '').length > 0;
}

/** 收藏键是否属于 MTA 来源（纯函数） */
export function isMtaFavoriteKey(key: string): boolean {
  return key.startsWith(MTA_FAVORITE_KEY_PREFIX);
}

/**
 * 收藏记录是否属于 MTA 来源（纯函数）。
 * 新记录带 protocol='mta'；同时兼容以 `mta:` 前缀存储的键，避免历史数据因缺字段失效。
 */
export function isMtaFavorite(favorite: FavoriteDevice): boolean {
  return favorite.protocol === 'mta' || isMtaFavoriteKey(favorite.fingerprint);
}

/** MTA 收藏记录的发送者 ID（小写；旧记录/异常记录返回空串） */
export function mtaFavoriteSenderId(favorite: FavoriteDevice): string {
  let senderId: string = normalizeSenderId(favorite.mtaSenderIdHex ?? '');
  if (senderId.length > 0) {
    return senderId;
  }
  if (isMtaFavoriteKey(favorite.fingerprint)) {
    return favorite.fingerprint.substring(MTA_FAVORITE_KEY_PREFIX.length);
  }
  return '';
}
