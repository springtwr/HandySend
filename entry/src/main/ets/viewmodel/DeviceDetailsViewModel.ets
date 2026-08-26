import { getServerFingerprint } from '../service/AppService';
import { DiscoveredDevice } from '../model/Types';
import { isFavorite, addFavoriteFromDiscovered, removeFavorite } from '../service/repository/FavoritesService';

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

  loadDevice(alias: string, ip: string, port: number, fingerprint: string, version: string,
    deviceModel: string, deviceType: string, protocol: string): void {
    this.deviceAlias = alias;
    this.deviceIp = ip;
    this.devicePort = port;
    this.deviceFingerprint = fingerprint;
    this.deviceVersion = version;
    this.deviceModel = deviceModel;
    this.deviceType = deviceType;
    this.deviceProtocol = protocol;
    this.localFingerprint = getServerFingerprint();
    this.isFavoriteDevice = isFavorite(this.deviceFingerprint);
  }

  toggleFavorite(): void {
    if (this.isFavoriteDevice) {
      removeFavorite(this.deviceFingerprint);
      this.isFavoriteDevice = false;
    } else {
      let device: DiscoveredDevice = {
        alias: this.deviceAlias,
        ip: this.deviceIp,
        port: this.devicePort,
        fingerprint: this.deviceFingerprint,
        version: this.deviceVersion,
        deviceModel: this.deviceModel,
        deviceType: this.deviceType,
        protocol: this.deviceProtocol,
        lastSeen: Date.now(),
        channels: [{ host: this.deviceIp, port: this.devicePort, protocol: this.deviceProtocol }]
      };
      addFavoriteFromDiscovered(device);
      this.isFavoriteDevice = true;
    }
  }
}
