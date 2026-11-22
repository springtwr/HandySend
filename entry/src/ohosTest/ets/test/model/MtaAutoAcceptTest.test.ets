// MtaAutoAcceptTest：互传接收自动确认判定与收藏身份键纯逻辑测试
// 覆盖三档模式、发送者 ID 匹配、收藏来源过滤与 MTA 收藏键规范。
import { describe, it, expect } from '@ohos/hypium'
import { computeMtaShouldAutoAccept } from '../../../../main/ets/model/mta/MtaAutoAcceptModels'
import {
  canFavoriteDevice,
  favoriteKeyOf,
  isMtaFavorite,
  mtaFavoriteSenderId,
  mtaSenderIdsMatch
} from '../../../../main/ets/model/DeviceIdentity'
import { AutoConfirmMode, DiscoveredDevice, FavoriteDevice } from '../../../../main/ets/model/Types'

function makeMtaFavorite(senderId: string): FavoriteDevice {
  let favorite: FavoriteDevice = {
    id: 'mta-' + senderId,
    fingerprint: 'mta:' + senderId,
    ip: '',
    port: 0,
    alias: 'MTA Device',
    customAlias: false,
    protocol: 'mta',
    mtaSenderIdHex: senderId
  }
  return favorite
}

function makeLocalFavorite(fingerprint: string): FavoriteDevice {
  let favorite: FavoriteDevice = {
    id: 'local-' + fingerprint,
    fingerprint: fingerprint,
    ip: '192.168.1.20',
    port: 53317,
    alias: 'Local Device',
    customAlias: false
  }
  return favorite
}

function makeMtaDevice(senderId: string, bleAddress: string): DiscoveredDevice {
  let device: DiscoveredDevice = {
    alias: 'MTA Device',
    ip: '',
    port: 0,
    fingerprint: bleAddress,
    version: '',
    deviceModel: '',
    deviceType: 'mobile',
    protocol: 'mta',
    lastSeen: 1000,
    channels: [],
    mtaBleAddress: bleAddress,
    mtaSenderIdHex: senderId,
    mtaBrandId: 11,
    mtaBrandName: 'Realme'
  }
  return device
}

export default function MtaAutoAcceptTest() {
  describe('MtaAutoAcceptTest', () => {

    // ── 自动确认三档模式 ──

    it('off_mode_never_auto_accepts', 0, () => {
      let favorites: Array<FavoriteDevice> = [makeMtaFavorite('aabbccdd')]
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.off, favorites, 'aabbccdd')).assertFalse()
    })

    it('on_mode_auto_accepts_any_sender', 0, () => {
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.on, [], 'aabbccdd')).assertTrue()
      // 发送者 ID 缺失时，on 模式仍按「始终接收」处理
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.on, [], '')).assertTrue()
    })

    it('paired_mode_accepts_favorite_sender', 0, () => {
      let favorites: Array<FavoriteDevice> = [makeMtaFavorite('aabbccdd')]
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.paired, favorites, 'aabbccdd')).assertTrue()
      // 大小写与空白规范化后仍匹配
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.paired, favorites, ' AABBCCDD ')).assertTrue()
    })

    it('paired_mode_rejects_unknown_sender', 0, () => {
      let favorites: Array<FavoriteDevice> = [makeMtaFavorite('aabbccdd')]
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.paired, favorites, '11223344')).assertFalse()
    })

    it('paired_mode_rejects_empty_sender', 0, () => {
      let favorites: Array<FavoriteDevice> = [makeMtaFavorite('aabbccdd')]
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.paired, favorites, '')).assertFalse()
    })

    it('paired_mode_accepts_vendor_short_sender_id_prefix', 0, () => {
      // 部分对端 sendRequest.senderId 只携带完整设备 ID 的前 2 字节
      let favorites: Array<FavoriteDevice> = [makeMtaFavorite('0c9b0000000000000000000000000c9b')]
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.paired, favorites, '0c9b')).assertTrue()
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.paired, favorites, ' 0C9B ')).assertTrue()
      // 短于 2 字节的前缀不参与匹配，避免过短前缀误判
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.paired, favorites, '0c')).assertFalse()
      // 前缀不一致仍回退手动确认
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.paired, favorites, '5d6d')).assertFalse()
    })

    it('mta_sender_ids_match_variants', 0, () => {
      expect(mtaSenderIdsMatch('0c9b', '0c9b0000000000000000000000000c9b')).assertTrue()
      expect(mtaSenderIdsMatch('0C9B0000000000000000000000000C9B', '0c9b')).assertTrue()
      expect(mtaSenderIdsMatch('0c9b', '5d6d0000000000000000000000005d6d')).assertFalse()
      expect(mtaSenderIdsMatch('0c', '0c9b0000000000000000000000000c9b')).assertFalse()
      expect(mtaSenderIdsMatch('', '0c9b0000000000000000000000000c9b')).assertFalse()
    })

    it('paired_mode_ignores_localsend_favorites', 0, () => {
      let favorites: Array<FavoriteDevice> = [makeLocalFavorite('aabbccdd')]
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.paired, favorites, 'aabbccdd')).assertFalse()
    })

    it('paired_mode_accepts_favorite_by_sender_id_field', 0, () => {
      // 收藏记录指纹未带前缀但显式标记为 MTA 时，仍按发送者 ID 匹配
      let favorite: FavoriteDevice = {
        id: 'mta-legacy',
        fingerprint: 'legacy-key',
        ip: '',
        port: 0,
        alias: 'Legacy',
        customAlias: false,
        protocol: 'mta',
        mtaSenderIdHex: 'aabbccdd'
      }
      expect(computeMtaShouldAutoAccept(AutoConfirmMode.paired, [favorite], 'aabbccdd')).assertTrue()
    })

    // ── 收藏身份键 ──

    it('favorite_key_of_mta_uses_sender_id', 0, () => {
      let device: DiscoveredDevice = makeMtaDevice('AABBCCDD', '11:22:33:44:55:66')
      expect(favoriteKeyOf(device)).assertEqual('mta:aabbccdd')
      expect(canFavoriteDevice(device)).assertTrue()
    })

    it('favorite_key_of_mta_falls_back_to_ble_address', 0, () => {
      let device: DiscoveredDevice = makeMtaDevice('', '11:22:33:44:55:66')
      expect(favoriteKeyOf(device)).assertEqual('mta:11:22:33:44:55:66')
      // 无发送者 ID 时不可收藏（地址会轮换，不能作稳定身份）
      expect(canFavoriteDevice(device)).assertFalse()
    })

    it('favorite_key_of_localsend_uses_fingerprint', 0, () => {
      let device: DiscoveredDevice = {
        alias: 'Local',
        ip: '192.168.1.20',
        port: 53317,
        fingerprint: 'fp-local',
        version: '2.2',
        deviceModel: 'Model',
        deviceType: 'phone',
        protocol: 'http',
        lastSeen: 1000,
        channels: []
      }
      expect(favoriteKeyOf(device)).assertEqual('fp-local')
      expect(canFavoriteDevice(device)).assertTrue()
    })

    it('mta_favorite_helpers', 0, () => {
      let favorite: FavoriteDevice = makeMtaFavorite('aabbccdd')
      expect(isMtaFavorite(favorite)).assertTrue()
      expect(mtaFavoriteSenderId(favorite)).assertEqual('aabbccdd')
      let local: FavoriteDevice = makeLocalFavorite('fp-local')
      expect(isMtaFavorite(local)).assertFalse()
      expect(mtaFavoriteSenderId(local)).assertEqual('')
    })
  })
}
