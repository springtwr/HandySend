import { getSecurityContext, resetTlsCertificate } from '../service/AppService';

// 证书安全信息视图模型：加载本机证书/公钥/私钥 PEM，并提供重置证书能力。
// 由原 DebugViewModel 裁剪迁移，仅保留「安全信息」相关职责。
@ObservedV2
export class CertificateViewModel {
  // 证书 / 公钥 / 私钥 PEM
  @Trace public certPem: string = ''
  @Trace public publicKeyPem: string = ''
  @Trace public privateKeyPem: string = ''
  // 上次重置是否因「传输进行中」失败（弹窗据此选择 busy/一般失败提示）
  public resetBlockedByBusy: boolean = false

  // 读取安全上下文：证书尚未生成（从未启动过服务器）时为空值占位，不崩溃
  loadCertificate(): void {
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
   * 重置 TLS 证书：成功后重新加载并返回 true；异常返回 false。
   * 传输进行中导致的失败可通过 resetBlockedByBusy 区分。
   */
  async resetCertificate(): Promise<boolean> {
    this.resetBlockedByBusy = false;
    try {
      await resetTlsCertificate();
      this.loadCertificate();
      return true;
    } catch (e) {
      // 与 AppService.resetTlsCertificate 抛出的守卫错误标识对应
      this.resetBlockedByBusy = e.message.indexOf('ACTIVE_TRANSFERS') >= 0;
      return false;
    }
  }
}
