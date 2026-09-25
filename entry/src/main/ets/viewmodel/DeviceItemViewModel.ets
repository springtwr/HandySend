import { DiscoveredDevice } from '../model/Types';
import { mtaBrandBadgeText, isMtaDevice } from '../model/mta/MtaMainModels';
import { resolveMtaPhoneBrandIcon } from '../model/mta/MtaBrandRegistry';

// 设备列表项的展示层 ViewModel（@ObservedV2 精准观测）。
// 包装 DiscoveredDevice 的展示字段，使 View 层不直接 import model/Types；
// 底层设备数据经 item 属性供事件上抛（发送/详情导航）使用。
@ObservedV2
export class DeviceItemViewModel {
  // 底层设备数据（发送/详情等事件上抛使用）
  item: DiscoveredDevice
  // 自定义别名覆盖：收藏面板重命名后，附近列表对同一设备显示自定义别名
  //（空串表示用设备广播别名，由发送页按收藏记录回填）
  @Trace public aliasOverride: string = ''

  constructor(device: DiscoveredDevice) {
    this.item = device;
  }

  get alias(): string {
    return this.aliasOverride.length > 0 ? this.aliasOverride : this.item.alias;
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

  // 列表复用的稳定身份键：MTA 设备的广播地址会轮换、不能作身份，故以发送者 ID 为身份
  //（与 MtaRepository 的去重键 mtaDeviceIdentityKey 口径一致，去重后同一列表不会有重复身份）；
  // 无发送者 ID 时回退广播地址；其它来源仍用 fingerprint
  get identityKey(): string {
    if (!this.isMta) {
      return this.item.fingerprint;
    }
    let senderId = this.item.mtaSenderIdHex !== undefined ? this.item.mtaSenderIdHex.trim().toLowerCase() : '';
    if (senderId.length > 0) {
      return 'mta:' + senderId;
    }
    let address = this.item.mtaBleAddress !== undefined ? this.item.mtaBleAddress.trim().toLowerCase() : '';
    return address.length > 0 ? 'mta:' + address : this.item.fingerprint;
  }

  // 是否互传联盟（MTA）来源设备：用于列表条目变体与发送路由分流
  get isMta(): boolean {
    return isMtaDevice(this.item);
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
