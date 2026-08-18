import { getServerFingerprint } from '../service/AppService';
import { DiscoveredDevice } from '../model/Types';
import { isFavorite, addFavoriteFromDiscovered, removeFavorite } from '../service/FavoritesService';

@Observed
export class DeviceDetailsViewModel {
  public deviceAlias: string = ''
  public deviceIp: string = ''
  public devicePort: number = 53317
  public deviceFingerprint: string = ''
  public deviceVersion: string = ''
  public deviceModel: string = ''
  public deviceType: string = ''
  public deviceProtocol: string = ''
  public localFingerprint: string = ''
  public isFavoriteDevice: boolean = false

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
