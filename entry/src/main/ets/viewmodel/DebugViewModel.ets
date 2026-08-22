import { deviceInfo } from '@kit.BasicServicesKit';
import { getLocalDeviceInfo, isServerRunning, getHttpsEnabled, getServerFingerprint } from '../service/AppService';
import { getLocalSendProtocolVersion } from '../service/NativeBridge';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { NetworkInterface } from '../model/Types';

@ObservedV2
export class DebugViewModel {
  @Trace public appVersion: string = '1.0.0'
  @Trace public deviceModelInfo: string = ''
  @Trace public localIp: string = ''
  @Trace public localAlias: string = ''
  @Trace public serverRunning: boolean = false
  @Trace public serverPort: number = 53317
  @Trace public httpsEnabled: boolean = true
  @Trace public serverFingerprint: string = ''
  @Trace public localInterfaces: Array<NetworkInterface> = []
  @Trace public protocolVersion: string = ''

  loadInfo(): void {
    this.deviceModelInfo = deviceInfo.manufacture + ' ' + deviceInfo.productModel;
    let localInfo = getLocalDeviceInfo();
    this.localIp = localInfo.ip;
    this.localAlias = localInfo.alias;
    this.localInterfaces = localInfo.interfaces;
    this.serverRunning = isServerRunning();
    this.serverPort = preferencesUtil.getNumber('port', 53317);
    this.httpsEnabled = getHttpsEnabled();
    this.serverFingerprint = getServerFingerprint();
    this.protocolVersion = 'v' + getLocalSendProtocolVersion();
  }
}
