/**
 * MtaAutoAcceptModels.ets — MTA 接收自动确认判定（纯函数）
 *
 * 与 LocalSend 的三档自动确认语义对齐：
 * - on：始终自动接收（含 MTA 原生文本消息）；
 * - paired：仅收藏的互传设备自动接收（按接收请求携带的发送者 ID 匹配）；
 * - off：不自动接收。
 *
 * 匹配失败、发送者 ID 缺失或收藏记录不属于互传来源时一律回退手动确认，
 * 不按昵称/BLE 地址做模糊匹配，避免把其他设备误判为收藏设备。
 */

import { AutoConfirmMode, FavoriteDevice } from '../Types';
import {
  isMtaFavorite,
  mtaSenderIdsMatch,
  normalizeSenderId,
  mtaFavoriteSenderId
} from '../DeviceIdentity';

/**
 * 判定一次 MTA 接收请求是否应自动接收（纯函数，无副作用、可单测）。
 *
 * @param mode 当前 MTA 自动确认模式
 * @param favorites 收藏设备快照
 * @param senderId 接收请求携带的发送者 ID（协议字段 senderId，可空）
 */
export function computeMtaShouldAutoAccept(mode: AutoConfirmMode, favorites: Array<FavoriteDevice>,
  senderId: string): boolean {
  if (mode === AutoConfirmMode.on) {
    return true;
  }
  if (mode !== AutoConfirmMode.paired) {
    return false;
  }
  let normalized: string = normalizeSenderId(senderId);
  if (normalized.length === 0) {
    // 无发送者 ID 无法与收藏记录建立可信匹配：回退手动确认
    return false;
  }
  for (let i = 0; i < favorites.length; i++) {
    let favorite: FavoriteDevice = favorites[i];
    if (!isMtaFavorite(favorite)) {
      continue;
    }
    // 对端可能只上报短设备 ID（如部分第三方实现 sendRequest.senderId = 完整 ID 前 2 字节），
    // 按前缀匹配模式兼容；短于 2 字节的前缀不参与匹配
    if (mtaSenderIdsMatch(normalized, mtaFavoriteSenderId(favorite))) {
      return true;
    }
  }
  return false;
}
