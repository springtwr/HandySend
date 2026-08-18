import { deviceInfo } from '@kit.BasicServicesKit';
import { getLocalDeviceInfo, getLocalInterfaces, isServerRunning, getHttpsEnabled, getServerFingerprint } from '../service/AppService';
import { getLocalSendProtocolVersion } from '../service/NativeBridge';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { NetworkInterface } from '../model/Types';

@Observed
export class DebugViewModel {
  public appVersion: string = '1.0.0'
  public deviceModelInfo: string = ''
  public localIp: string = ''
  public localAlias: string = ''
  public serverRunning: boolean = false
  public serverPort: number = 53317
  public httpsEnabled: boolean = true
  public serverFingerprint: string = ''
  public localInterfaces: Array<NetworkInterface> = []
  public protocolVersion: string = ''

  loadInfo(): void {
    this.deviceModelInfo = deviceInfo.manufacture + ' ' + deviceInfo.productModel;
    let localInfo = getLocalDeviceInfo();
    this.localIp = localInfo.ip;
    this.localAlias = localInfo.alias;
    this.localInterfaces = getLocalInterfaces();
    this.serverRunning = isServerRunning();
    this.serverPort = preferencesUtil.getNumber('port', 53317);
    this.httpsEnabled = getHttpsEnabled();
    this.serverFingerprint = getServerFingerprint();
    this.protocolVersion = getLocalSendProtocolVersion();
  }
}
