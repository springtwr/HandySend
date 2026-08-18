import { toIcons, getCombinedFingerprint } from '../utils/FingerprintIcons';

// VerifyViewModel: holds the fingerprint verification state for VerifyPage.
// The combined fingerprint and icon sequence are derived purely from the
// local + remote fingerprints passed in from route params; the derivation
// itself lives in FingerprintIcons (pure util), this VM only orchestrates it.
@Observed
export class VerifyViewModel {
  public localFingerprint: string = '';
  public remoteFingerprint: string = '';
  public combinedFingerprint: string = '';
  public combinedIcons: Array<string> = [];
  public showHex: boolean = false;

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
