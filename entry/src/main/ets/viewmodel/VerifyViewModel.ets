import { toIcons, getCombinedFingerprint } from '../utils/FingerprintIcons';

// VerifyViewModel：持有 VerifyPage 的指纹验证状态。
// 组合指纹与图标序列完全由以下内容派生：
// 从路由参数传入的本地 + 远端指纹；派生
// 算法本身位于 FingerprintIcons（纯工具），本 VM 仅负责编排。
@ObservedV2
export class VerifyViewModel {
  @Trace public localFingerprint: string = '';
  @Trace public remoteFingerprint: string = '';
  @Trace public combinedFingerprint: string = '';
  @Trace public combinedIcons: Array<string> = [];
  @Trace public showHex: boolean = false;

  loadFingerprints(localFingerprint: string, remoteFingerprint: string): void {
    this.localFingerprint = localFingerprint;
    this.remoteFingerprint = remoteFingerprint;
    this.combinedFingerprint = getCombinedFingerprint(localFingerprint, remoteFingerprint);
    this.combinedIcons = toIcons(this.combinedFingerprint);
  }

  setDisplayMode(showHex: boolean): void {
    this.showHex = showHex;
  }
}
