import { describe, it, expect } from '@ohos/hypium'
import {
  addFavorite,
  removeFavorite,
  isFavorite,
  syncFavoriteFromDiscovery,
  addFavoriteFromDiscovered,
  subscribeFavorites,
  unsubscribeFavorites,
  getFavorites
} from '../../../../main/ets/service/repository/FavoritesService'
import { FavoriteDevice, DiscoveredDevice } from '../../../../main/ets/model/Types'

function makeFavorite(fingerprint: string, alias: string, customAlias: boolean): FavoriteDevice {
  let fav: FavoriteDevice = {
    id: 'id-' + fingerprint,
    fingerprint: fingerprint,
    ip: '192.168.1.10',
    port: 53317,
    alias: alias,
    customAlias: customAlias
  }
  return fav
}

function makeDiscovered(fingerprint: string, alias: string): DiscoveredDevice {
  let dev: DiscoveredDevice = {
    alias: alias,
    ip: '192.168.1.20',
    port: 53317,
    fingerprint: fingerprint,
    version: '1.18.1',
    deviceModel: 'TestModel',
    deviceType: 'phone',
    protocol: 'http',
    lastSeen: 1000,
    channels: [{ host: '192.168.1.20', port: 53317, protocol: 'http' }]
  }
  return dev
}

function findByFingerprint(fingerprint: string): FavoriteDevice | null {
  let list: Array<FavoriteDevice> = getFavorites()
  for (let i = 0; i < list.length; i++) {
    if (list[i].fingerprint === fingerprint) {
      return list[i]
    }
  }
  return null
}

function countByFingerprint(fingerprint: string): number {
  let list: Array<FavoriteDevice> = getFavorites()
  let count: number = 0
  for (let i = 0; i < list.length; i++) {
    if (list[i].fingerprint === fingerprint) {
      count = count + 1
    }
  }
  return count
}

export default function FavoritesServiceTest() {
  describe('FavoritesServiceTest', () => {
    it('addFavorite_adds_new_device', 0, () => {
      let before: number = getFavorites().length
      addFavorite(makeFavorite('fp-add-1', 'alias-1', false))
      expect(getFavorites().length).assertEqual(before + 1)
      expect(isFavorite('fp-add-1')).assertTrue()
    })

    it('addFavorite_duplicate_fingerprint_not_duplicated', 0, () => {
      addFavorite(makeFavorite('fp-dup', 'alias-dup-1', false))
      addFavorite(makeFavorite('fp-dup', 'alias-dup-2', true))
      expect(countByFingerprint('fp-dup')).assertEqual(1)
      let found: FavoriteDevice | null = findByFingerprint('fp-dup')
      if (found !== null) {
        expect(found.alias).assertEqual('alias-dup-2')
        expect(found.customAlias).assertTrue()
      }
    })

    it('removeFavorite_removes_device', 0, () => {
      addFavorite(makeFavorite('fp-rm', 'alias-rm', false))
      expect(isFavorite('fp-rm')).assertTrue()
      removeFavorite('fp-rm')
      expect(isFavorite('fp-rm')).assertFalse()
    })

    it('findByFingerprint_found_returns_match', 0, () => {
      addFavorite(makeFavorite('fp-find', 'alias-find', false))
      let found: FavoriteDevice | null = findByFingerprint('fp-find')
      expect(found !== null).assertTrue()
      if (found !== null) {
        expect(found.fingerprint).assertEqual('fp-find')
      }
    })

    it('findByFingerprint_not_found_returns_null', 0, () => {
      let found: FavoriteDevice | null = findByFingerprint('fp-ghost')
      expect(found === null).assertTrue()
    })


    it('syncFavoriteFromDiscovery_updates_when_custom_false', 0, () => {
      addFavorite(makeFavorite('fp-sync1', 'alias-a1', false))
      syncFavoriteFromDiscovery('fp-sync1', 'alias-a2')
      let found: FavoriteDevice | null = findByFingerprint('fp-sync1')
      if (found !== null) {
        expect(found.alias).assertEqual('alias-a2')
      }
    })

    it('syncFavoriteFromDiscovery_keeps_custom_alias', 0, () => {
      addFavorite(makeFavorite('fp-sync2', 'alias-b1', true))
      syncFavoriteFromDiscovery('fp-sync2', 'alias-b2')
      let found: FavoriteDevice | null = findByFingerprint('fp-sync2')
      if (found !== null) {
        expect(found.alias).assertEqual('alias-b1')
      }
    })

    it('syncFavoriteFromDiscovery_unknown_fingerprint_no_effect', 0, () => {
      let before: number = getFavorites().length
      syncFavoriteFromDiscovery('fp-ghost-sync', 'whatever')
      expect(getFavorites().length).assertEqual(before)
    })

    it('addFavoriteFromDiscovered_no_custom_alias', 0, () => {
      let dev: DiscoveredDevice = makeDiscovered('fp-disc1', 'disc-alias-1')
      addFavoriteFromDiscovered(dev)
      let found: FavoriteDevice | null = findByFingerprint('fp-disc1')
      if (found !== null) {
        expect(found.alias).assertEqual('disc-alias-1')
        expect(found.customAlias).assertFalse()
      }
    })

    it('addFavoriteFromDiscovered_with_custom_alias', 0, () => {
      let dev: DiscoveredDevice = makeDiscovered('fp-disc2', 'disc-alias-2')
      addFavoriteFromDiscovered(dev, 'my-custom-alias')
      let found: FavoriteDevice | null = findByFingerprint('fp-disc2')
      if (found !== null) {
        expect(found.alias).assertEqual('my-custom-alias')
        expect(found.customAlias).assertTrue()
      }
    })

    it('addFavoriteFromDiscovered_custom_alias_empty_keeps_device_alias', 0, () => {
      let dev: DiscoveredDevice = makeDiscovered('fp-disc3', 'disc-alias-3')
      addFavoriteFromDiscovered(dev, '')
      let found: FavoriteDevice | null = findByFingerprint('fp-disc3')
      if (found !== null) {
        expect(found.alias).assertEqual('disc-alias-3')
        expect(found.customAlias).assertFalse()
      }
    })

    it('addFavoriteFromDiscovered_custom_alias_same_as_device_alias', 0, () => {
      let dev: DiscoveredDevice = makeDiscovered('fp-disc4', 'disc-alias-4')
      addFavoriteFromDiscovered(dev, 'disc-alias-4')
      let found: FavoriteDevice | null = findByFingerprint('fp-disc4')
      if (found !== null) {
        expect(found.alias).assertEqual('disc-alias-4')
        expect(found.customAlias).assertFalse()
      }
    })

    it('subscribe_fires_callback_on_change', 0, () => {
      let count: number = 0
      let cb: () => void = () => {
        count = count + 1
      }
      subscribeFavorites(cb)
      addFavorite(makeFavorite('fp-cb1', 'alias-cb1', false))
      expect(count).assertEqual(1)
      unsubscribeFavorites(cb)
      addFavorite(makeFavorite('fp-cb2', 'alias-cb2', false))
      expect(count).assertEqual(1)
    })

    it('removeFavorite_nonexistent_no_effect', 0, () => {
      let before: number = getFavorites().length
      removeFavorite('fp-ghost-rm')
      expect(getFavorites().length).assertEqual(before)
    })

    it('syncFavoriteFromDiscovery_same_alias_no_change', 0, () => {
      addFavorite(makeFavorite('fp-sync3', 'alias-c1', false))
      syncFavoriteFromDiscovery('fp-sync3', 'alias-c1')
      let found: FavoriteDevice | null = findByFingerprint('fp-sync3')
      if (found !== null) {
        expect(found.alias).assertEqual('alias-c1')
      }
    })

    it('addFavoriteFromDiscovered_undefined_custom_alias', 0, () => {
      let dev: DiscoveredDevice = makeDiscovered('fp-disc5', 'disc-alias-5')
      addFavoriteFromDiscovered(dev, undefined)
      let found: FavoriteDevice | null = findByFingerprint('fp-disc5')
      if (found !== null) {
        expect(found.alias).assertEqual('disc-alias-5')
        expect(found.customAlias).assertFalse()
      }
    })

    it('max_favorites_removes_oldest', 0, () => {
      for (let i = 0; i < 101; i++) {
        addFavorite(makeFavorite('fp-max-' + i, 'alias-max-' + i, false))
      }
      expect(getFavorites().length).assertEqual(100)
      expect(isFavorite('fp-max-0')).assertFalse()
      expect(isFavorite('fp-max-100')).assertTrue()
    })
  })
}
