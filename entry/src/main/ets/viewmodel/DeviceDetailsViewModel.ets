import { getServerFingerprint } from '../service/AppService';
import { DiscoveredDevice } from '../model/Types';
import { isFavorite, addFavoriteFromDiscovered, removeFavorite } from '../service/repository/FavoritesService';
import { mtaBrandBadgeText } from '../model/mta/MtaMainModels';
import { resolveMtaPhoneBrandIcon } from '../model/mta/MtaBrandRegistry';
import { normalizeSenderId, MTA_FAVORITE_KEY_PREFIX } from '../model/DeviceIdentity';

@ObservedV2
export class DeviceDetailsViewModel {
  @Trace public deviceAlias: string = ''
  @Trace public deviceIp: string = ''
  @Trace public devicePort: number = 53317
  @Trace public deviceFingerprint: string = ''
  @Trace public deviceVersion: string = ''
  @Trace public deviceModel: string = ''
  @Trace public deviceType: string = ''
  @Trace public deviceProtocol: string = ''
  @Trace public localFingerprint: string = ''
  @Trace public isFavoriteDevice: boolean = false
  // 设备来源：'mta' 表示互传联盟收藏/发现设备，其余按 LocalSend 局域网设备展示
  @Trace public isMtaDevice: boolean = false
  @Trace public mtaSenderIdHex: string = ''
  @Trace public mtaBleAddress: string = ''
  @Trace public mtaBrandId: number = -1
  @Trace public mtaBrandName: string = ''

  loadDevice(alias: string, ip: string, port: number, fingerprint: string, version: string,
    deviceModel: string, deviceType: string, protocol: string, source: string = 'localsend',
    mtaSenderIdHex: string = '', mtaBleAddress: string = '', mtaBrandId: number = -1,
    mtaBrandName: string = ''): void {
    this.deviceAlias = alias;
    this.deviceIp = ip;
    this.devicePort = port;
    this.deviceFingerprint = fingerprint;
    this.deviceVersion = version;
    this.deviceModel = deviceModel;
    this.deviceType = deviceType;
    this.deviceProtocol = protocol;
    this.isMtaDevice = source === 'mta';
    this.mtaSenderIdHex = mtaSenderIdHex;
    this.mtaBleAddress = mtaBleAddress;
    this.mtaBrandId = mtaBrandId;
    this.mtaBrandName = mtaBrandName;
    this.localFingerprint = getServerFingerprint();
    this.isFavoriteDevice = isFavorite(this.favoriteKey());
  }

  /** 当前设备的收藏键：MTA 以发送者 ID 为准，其余沿用设备指纹 */
  private favoriteKey(): string {
    if (this.isMtaDevice) {
      let senderId: string = normalizeSenderId(this.mtaSenderIdHex);
      if (senderId.length > 0) {
        return MTA_FAVORITE_KEY_PREFIX + senderId;
      }
    }
    return this.deviceFingerprint;
  }

  /** MTA 品牌图标（仅 MTA 来源展示） */
  get mtaBrandIcon(): Resource {
    return resolveMtaPhoneBrandIcon(this.mtaBrandId);
  }

  /** MTA 品牌徽标文案（未知品牌回退固定文案） */
  get mtaBrandBadge(): string {
    return mtaBrandBadgeText(this.mtaBrandName);
  }

  /** 是否可收藏：互传设备必须有发送者 ID（BLE 地址会轮换，不能作稳定身份） */
  get canFavoriteDevice(): boolean {
    return !this.isMtaDevice || normalizeSenderId(this.mtaSenderIdHex).length > 0;
  }

  toggleFavorite(): void {
    let key: string = this.favoriteKey();
    if (this.isFavoriteDevice) {
      removeFavorite(key);
      this.isFavoriteDevice = false;
      return;
    }
    if (this.isMtaDevice && normalizeSenderId(this.mtaSenderIdHex).length === 0) {
      // 无发送者 ID 无法建立稳定收藏身份：不写入收藏（与附近列表口径一致）
      return;
    }
    let device: DiscoveredDevice = {
      alias: this.deviceAlias,
      ip: this.isMtaDevice ? '' : this.deviceIp,
      port: this.isMtaDevice ? 0 : this.devicePort,
      fingerprint: this.isMtaDevice ? this.mtaBleAddress : this.deviceFingerprint,
      version: this.isMtaDevice ? '' : this.deviceVersion,
      deviceModel: this.isMtaDevice ? '' : this.deviceModel,
      deviceType: this.deviceType,
      protocol: this.isMtaDevice ? 'mta' : this.deviceProtocol,
      lastSeen: Date.now(),
      channels: this.isMtaDevice ? [] : [{ host: this.deviceIp, port: this.devicePort, protocol: this.deviceProtocol }],
      mtaSenderIdHex: this.isMtaDevice ? this.mtaSenderIdHex : undefined,
      mtaBleAddress: this.isMtaDevice ? this.mtaBleAddress : undefined,
      mtaBrandId: this.isMtaDevice ? this.mtaBrandId : undefined,
      mtaBrandName: this.isMtaDevice ? this.mtaBrandName : undefined
    };
    addFavoriteFromDiscovered(device);
    this.isFavoriteDevice = isFavorite(key);
  }
}
