import { DiscoveredDevice } from '../model/Types';
import { mtaBrandBadgeText } from '../model/mta/MtaMainModels';
import { resolveMtaPhoneBrandIcon } from '../model/mta/MtaBrandRegistry';

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

  get protocol(): string {
    return this.item.protocol;
  }

  // 是否互传联盟（MTA）来源设备：用于列表条目变体与发送路由分流
  get isMta(): boolean {
    return this.item.protocol === 'mta';
  }

  // MTA 品牌名（仅 MTA 设备有效；未知品牌为空串）
  get mtaBrandName(): string {
    return this.item.mtaBrandName !== undefined ? this.item.mtaBrandName : '';
  }

  // MTA 品牌徽标文案：已知品牌返回品牌名，未知回退固定文案（与传输页设备卡共用）
  get mtaBrandBadge(): string {
    return mtaBrandBadgeText(this.item.mtaBrandName);
  }

  // MTA 对端手机品牌图标：按品牌标识解析（未知/无专属图标回退默认兜底），仅 MTA 设备消费
  get mtaPhoneBrandIcon(): Resource {
    return resolveMtaPhoneBrandIcon(this.item.mtaBrandId !== undefined ? this.item.mtaBrandId : -1);
  }
}
