import { describe, it, expect } from '@ohos/hypium'
import { DeviceItemViewModel } from '../../../../main/ets/viewmodel/DeviceItemViewModel'
import { DiscoveredDevice } from '../../../../main/ets/model/Types'
import { MTA_PROTOCOL } from '../../../../main/ets/model/mta/MtaMainModels'

function localDevice(alias: string, fingerprint: string, ip: string): DiscoveredDevice {
  return {
    alias: alias,
    ip: ip,
    port: 53317,
    fingerprint: fingerprint,
    version: '2.2',
    deviceModel: 'Model',
    deviceType: 'mobile',
    protocol: 'https',
    lastSeen: Date.now(),
    channels: []
  };
}

function mtaDevice(alias: string, bleAddress: string, senderId: string, brandId: number = -1,
  brandName: string = '', is5Ghz: boolean = false): DiscoveredDevice {
  return {
    alias: alias,
    ip: '',
    port: 0,
    fingerprint: bleAddress,
    version: '',
    deviceModel: '',
    deviceType: 'mobile',
    protocol: MTA_PROTOCOL,
    lastSeen: Date.now(),
    channels: [],
    mtaBleAddress: bleAddress,
    mtaSenderIdHex: senderId,
    mtaBrandId: brandId,
    mtaBrandName: brandName,
    mtaIs5Ghz: is5Ghz
  };
}

export default function DeviceItemViewModelTest() {
  describe('DeviceItemViewModelTest', () => {
    it('keyAlias_uses_real_mta_name', 0, () => {
      let item: DeviceItemViewModel = new DeviceItemViewModel(mtaDevice('Phone A', 'AA:BB', 'sender-1'));
      expect(item.keyAlias).assertEqual('Phone A');
    });

    it('keyAlias_ignores_mta_address_fallback', 0, () => {
      let item: DeviceItemViewModel = new DeviceItemViewModel(mtaDevice('AA:BB', 'AA:BB', 'sender-1'));
      expect(item.keyAlias).assertEqual('');
    });

    it('keyAlias_tracks_mta_rename_without_changing_identity', 0, () => {
      let before: DeviceItemViewModel = new DeviceItemViewModel(mtaDevice('Phone A', 'AA:BB', 'sender-1'));
      let after: DeviceItemViewModel = new DeviceItemViewModel(mtaDevice('Phone B', 'AA:BB', 'sender-1'));
      expect(before.keyAlias === after.keyAlias).assertFalse();
      expect(before.identityKey).assertEqual(after.identityKey);
    });

    it('keyAlias_stays_empty_when_mta_address_rotates_without_name', 0, () => {
      let before: DeviceItemViewModel = new DeviceItemViewModel(mtaDevice('AA:BB', 'AA:BB', 'sender-1'));
      let after: DeviceItemViewModel = new DeviceItemViewModel(mtaDevice('CC:DD', 'CC:DD', 'sender-1'));
      expect(before.keyAlias).assertEqual('');
      expect(after.keyAlias).assertEqual('');
      // 别名段不重复承载回退地址；地址轮换由 keyMta 参与 key 并触发重建
      expect(before.keyMta === after.keyMta).assertFalse();
      expect(before.identityKey).assertEqual(after.identityKey);
    });

    it('keyMta_tracks_mta_ble_address', 0, () => {
      let before: DeviceItemViewModel = new DeviceItemViewModel(mtaDevice('Phone A', 'AA:BB', 'sender-1'));
      let after: DeviceItemViewModel = new DeviceItemViewModel(mtaDevice('Phone A', 'CC:DD', 'sender-1'));
      expect(before.keyAlias).assertEqual(after.keyAlias);
      expect(before.keyMta === after.keyMta).assertFalse();
      expect(before.identityKey).assertEqual(after.identityKey);
    });

    it('keyMta_tracks_brand_and_band', 0, () => {
      let before: DeviceItemViewModel = new DeviceItemViewModel(
        mtaDevice('Phone A', 'AA:BB', 'sender-1', 1, 'Brand A', false));
      let after: DeviceItemViewModel = new DeviceItemViewModel(
        mtaDevice('Phone A', 'AA:BB', 'sender-1', 2, 'Brand B', true));
      expect(before.keyAlias).assertEqual(after.keyAlias);
      expect(before.keyMta === after.keyMta).assertFalse();
    });

    it('keyMta_empty_for_localsend', 0, () => {
      let item: DeviceItemViewModel = new DeviceItemViewModel(localDevice('Name', 'fp-1', '192.168.1.2'));
      expect(item.keyMta).assertEqual('');
    });

    it('keyAlias_changes_when_mta_name_appears_or_disappears', 0, () => {
      let named: DeviceItemViewModel = new DeviceItemViewModel(mtaDevice('Phone A', 'AA:BB', 'sender-1'));
      let unnamed: DeviceItemViewModel = new DeviceItemViewModel(mtaDevice('AA:BB', 'AA:BB', 'sender-1'));
      expect(named.keyAlias === unnamed.keyAlias).assertFalse();
      expect(named.keyAlias).assertEqual('Phone A');
      expect(unnamed.keyAlias).assertEqual('');
    });

    it('keyAlias_tracks_localsend_rename', 0, () => {
      let before: DeviceItemViewModel = new DeviceItemViewModel(localDevice('Old Name', 'fp-1', '192.168.1.2'));
      let after: DeviceItemViewModel = new DeviceItemViewModel(localDevice('New Name', 'fp-1', '192.168.1.2'));
      expect(before.keyAlias).assertEqual('Old Name');
      expect(after.keyAlias).assertEqual('New Name');
      expect(before.identityKey).assertEqual(after.identityKey);
    });
  })
}
