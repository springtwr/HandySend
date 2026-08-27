import { deviceInfo } from '@kit.BasicServicesKit';
import {
  getLocalDeviceInfo,
  isServerRunning,
  getHttpsEnabled,
  getServerFingerprint,
  getPort,
  getSecurityContext,
  resetTlsCertificate
} from '../service/AppService';
import { getLocalSendProtocolVersion } from '../service/NativeBridge';
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
  // 证书 / 公钥 / 私钥 PEM（安全信息展示区）
  @Trace public certPem: string = ''
  @Trace public publicKeyPem: string = ''
  @Trace public privateKeyPem: string = ''
  // 上次重置是否因「传输进行中」失败（页面据此选择 busy/一般失败提示）
  public resetBlockedByBusy: boolean = false

  loadInfo(): void {
    this.deviceModelInfo = deviceInfo.manufacture + ' ' + deviceInfo.productModel;
    let localInfo = getLocalDeviceInfo();
    this.localIp = localInfo.ip;
    this.localAlias = localInfo.alias;
    this.localInterfaces = localInfo.interfaces;
    this.serverRunning = isServerRunning();
    this.serverPort = getPort();
    this.httpsEnabled = getHttpsEnabled();
    this.serverFingerprint = getServerFingerprint();
    this.protocolVersion = 'v' + getLocalSendProtocolVersion();
    // 安全上下文：证书尚未生成（从未启动过服务器）时为空值占位，不崩溃
    try {
      let securityCtx = getSecurityContext();
      this.certPem = securityCtx.certificate;
      this.publicKeyPem = securityCtx.publicKey;
      this.privateKeyPem = securityCtx.privateKey;
    } catch (_e) {
      // 原生安全上下文不可用——保持空值占位
    }
  }

  /**
   * 重置 TLS 证书：成功后重刷页面信息并返回 true；异常返回 false。
   * 传输进行中导致的失败可通过 resetBlockedByBusy 区分。
   */
  async resetCertificate(): Promise<boolean> {
    this.resetBlockedByBusy = false;
    try {
      await resetTlsCertificate();
      this.loadInfo();
      return true;
    } catch (e) {
      // 与 AppService.resetTlsCertificate 抛出的守卫错误标识对应
      this.resetBlockedByBusy = e.message.indexOf('ACTIVE_TRANSFERS') >= 0;
      return false;
    }
  }
}
