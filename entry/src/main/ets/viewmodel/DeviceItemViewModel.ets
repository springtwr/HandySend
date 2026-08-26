import { DiscoveredDevice } from '../model/Types';

// 设备列表项的展示层 ViewModel（@ObservedV2 精准观测）。
// 包装 DiscoveredDevice 的展示字段，使 View 层不直接 import model/Types；
// 底层设备数据经 item 属性供事件上抛（发送/详情导航）使用。
@ObservedV2
export class DeviceItemViewModel {
  // 底层设备数据（发送/详情等事件上抛使用）
  item: DiscoveredDevice

  constructor(device: DiscoveredDevice) {
    this.item = device;
  }

  get alias(): string {
    return this.item.alias;
  }

  get ip(): string {
    return this.item.ip;
  }

  get deviceType(): string {
    return this.item.deviceType;
  }

  get deviceModel(): string {
    return this.item.deviceModel;
  }

  get fingerprint(): string {
    return this.item.fingerprint;
  }
}
