import { describe, it, expect } from '@ohos/hypium'
import {
  DeviceTypePartition,
  partitionDevicesByType,
  hasAnyMtaDevice
} from '../../../../main/ets/model/SendDeviceGrouping'
import { DiscoveredDevice } from '../../../../main/ets/model/Types'

// 构造局域网（LocalSend）来源设备样本
function localDevice(fingerprint: string): DiscoveredDevice {
  return {
    alias: 'local-' + fingerprint,
    ip: '192.168.1.10',
    port: 53317,
    fingerprint: fingerprint,
    version: '2.0',
    deviceModel: 'X',
    deviceType: 'desktop',
    protocol: 'https',
    lastSeen: 0,
    channels: []
  };
}

// 构造互传联盟（MTA）来源设备样本
function mtaDevice(fingerprint: string): DiscoveredDevice {
  return {
    alias: 'mta-' + fingerprint,
    ip: '',
    port: 0,
    fingerprint: fingerprint,
    version: '',
    deviceModel: '',
    deviceType: 'mobile',
    protocol: 'mta',
    lastSeen: 0,
    channels: []
  };
}

// 发送页设备分组纯函数测试：拆分正确性、顺序保持、空集合、入参不变与 MTA 存在性判定。
export default function SendDeviceGroupingTest() {
  describe('SendDeviceGroupingTest', () => {
    it('partition_all_local', 0, () => {
      let input: Array<DiscoveredDevice> = [localDevice('a'), localDevice('b')];
      let result: DeviceTypePartition = partitionDevicesByType(input);
      expect(result.local.length).assertEqual(2);
      expect(result.mta.length).assertEqual(0);
      expect(result.local[0].fingerprint).assertEqual('a');
      expect(hasAnyMtaDevice(input)).assertFalse();
    })

    it('partition_all_mta', 0, () => {
      let input: Array<DiscoveredDevice> = [mtaDevice('m1'), mtaDevice('m2')];
      let result: DeviceTypePartition = partitionDevicesByType(input);
      expect(result.local.length).assertEqual(0);
      expect(result.mta.length).assertEqual(2);
      expect(result.mta[1].fingerprint).assertEqual('m2');
      expect(hasAnyMtaDevice(input)).assertTrue();
    })

    it('partition_mixed_preserves_order', 0, () => {
      let input: Array<DiscoveredDevice> = [localDevice('a'), mtaDevice('m1'), localDevice('b'), mtaDevice('m2')];
      let result: DeviceTypePartition = partitionDevicesByType(input);
      expect(result.local.length).assertEqual(2);
      expect(result.mta.length).assertEqual(2);
      expect(result.local[0].fingerprint).assertEqual('a');
      expect(result.local[1].fingerprint).assertEqual('b');
      expect(result.mta[0].fingerprint).assertEqual('m1');
      expect(result.mta[1].fingerprint).assertEqual('m2');
      expect(hasAnyMtaDevice(input)).assertTrue();
    })

    it('partition_empty', 0, () => {
      let input: Array<DiscoveredDevice> = [];
      let result: DeviceTypePartition = partitionDevicesByType(input);
      expect(result.local.length).assertEqual(0);
      expect(result.mta.length).assertEqual(0);
      expect(hasAnyMtaDevice(input)).assertFalse();
    })

    it('partition_does_not_mutate_input', 0, () => {
      let first = localDevice('a');
      let input: Array<DiscoveredDevice> = [first, mtaDevice('m1')];
      let result: DeviceTypePartition = partitionDevicesByType(input);
      expect(input.length).assertEqual(2);
      expect(input[0].fingerprint).assertEqual('a');
      expect(input[1].fingerprint).assertEqual('m1');
      // 分组结果复用输入元素引用（只读语义），输入顺序未被改写
      expect(result.local[0].fingerprint).assertEqual('a');
      expect(result.mta[0].fingerprint).assertEqual('m1');
    })

    it('has_any_mta_device_only_local', 0, () => {
      expect(hasAnyMtaDevice([localDevice('a'), localDevice('b')])).assertFalse();
      expect(hasAnyMtaDevice([])).assertFalse();
    })
  })
}
