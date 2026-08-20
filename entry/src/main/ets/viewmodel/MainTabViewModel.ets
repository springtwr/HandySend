import { getPendingRequests, getDiscoveredDevices, getLocalDeviceInfo, getDeviceType, getDeviceModel,
  getSilentReceive, peekRecvCompleted, peekRecvCancelled,
  consumeRecvCompleted, consumeRecvCancelled, removePendingRequest } from '../service/AppService';
import { PendingRequest, DiscoveredDevice, LocalDeviceInfo } from '../model/Types';
import { getLogger, LogContext } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.DISCOVERY, 'HandySend:MainTab');

// Handles incoming receive-request routing (business rules extracted from
// MainTabFloating) + one-shot transfer-event overlay triggers.
@ObservedV2
export class MainTabViewModel {
  @Trace public requestDismissed: Record<string, boolean> = {}
  @Trace public autoAcceptedSessions: Record<string, string> = {}
  // Bridge for the UIContext boundary: the view injects a callback used to
  // show the completion/cancellation overlay. VM file has no UI imports.
  public onTransferEvent: ((type: string, alias: string) => void) | undefined = undefined

  // Processes all pending receive requests. Returns TransferPage navigation
  // params when a request must be routed to the transfer page, or undefined
  // when nothing needs navigation (dismissed). Auto-save requests (marked
  // autoConfirmed by the event layer) are routed too, so the transfer page
  // shows progress/completion instead of a silent background save.
  handlePendingRequests(): Record<string, Object | string | number | boolean | Array<string>> | undefined {
    let requests: Array<PendingRequest> = getPendingRequests();
    for (let i = 0; i < requests.length; i++) {
      let r: PendingRequest = requests[i];
      if (this.requestDismissed[r.sessionId] !== undefined) {
        continue;
      }
      this.requestDismissed[r.sessionId] = true;

      let clipboardPreview: string = '';
      if (r.files.length === 1 &&
        r.files[0].fileType === 'text/plain' &&
        r.files[0].preview !== undefined &&
        r.files[0].preview.length > 0) {
        clipboardPreview = r.files[0].preview;
      }
      let isClipboard: boolean = clipboardPreview.length > 0;

      if (r.autoConfirmed) {
        // Accepted at the event layer already; the page auto-confirms (no
        // repeat respond call) and shows progress/completion.
        removePendingRequest(r.sessionId);
        logger.info('[diag] auto-confirmed session routed to transfer page, session=' +
          r.sessionId.substring(0, 8) + ' alias=' + r.senderAlias);
        return this.buildReceiveParams(r, clipboardPreview, isClipboard, true, true);
      }
      return this.buildReceiveParams(r, clipboardPreview, isClipboard, isClipboard, false);
    }
    return undefined;
  }

  private buildReceiveParams(r: PendingRequest, clipboardPreview: string, isClipboard: boolean,
    autoConfirm: boolean, alreadyAccepted: boolean): Record<string, Object | string | number | boolean | Array<string>> {
    let devices: Array<DiscoveredDevice> = getDiscoveredDevices();
    let senderDevice: DiscoveredDevice | undefined = undefined;
    for (let k = 0; k < devices.length; k++) {
      if (devices[k].fingerprint === r.senderFingerprint) {
        senderDevice = devices[k];
        break;
      }
    }
    // Prefer sender identity carried by the prepare_upload event; the
    // discovery lookup only fills gaps (e.g. the poll fallback path).
    let senderIp: string = r.senderIp;
    let senderDeviceType: string = r.senderDeviceType;
    let senderDeviceModel: string = r.senderDeviceModel;
    if (senderDevice !== undefined) {
      if (senderIp.length === 0) {
        senderIp = senderDevice.ip;
      }
      if (senderDeviceType.length === 0) {
        senderDeviceType = senderDevice.deviceType;
      }
      if (senderDeviceModel.length === 0) {
        senderDeviceModel = senderDevice.deviceModel;
      }
    }
    if (senderDeviceType.length === 0) {
      senderDeviceType = 'mobile';
    }
    let localInfo: LocalDeviceInfo = getLocalDeviceInfo();
    let totalSize: number = 0;
    let allFileIds: Array<string> = [];
    for (let k = 0; k < r.files.length; k++) {
      totalSize = totalSize + r.files[k].size;
      allFileIds.push(r.files[k].fileId);
    }
    let params: Record<string, Object | string | number | boolean | Array<string>> = {
      'mode': 'receive',
      'sourceAlias': r.senderAlias,
      'sourceIp': senderIp,
      'sourceDeviceType': senderDeviceType,
      'sourceDeviceModel': senderDeviceModel,
      'targetAlias': localInfo.alias,
      'targetIp': localInfo.ip,
      'targetDeviceType': getDeviceType(),
      'targetDeviceModel': getDeviceModel(),
      'fileUris': new Array<string>(),
      'targetPort': 0,
      'targetFingerprint': r.senderFingerprint,
      'targetProtocol': senderDevice !== undefined ? senderDevice.protocol : '',
      'sessionId': r.sessionId,
      'autoConfirm': autoConfirm,
      'alreadyAccepted': alreadyAccepted,
      'fileCount': r.files.length,
      'totalSize': totalSize,
      'isClipboard': isClipboard,
      'clipboardContent': clipboardPreview,
      'acceptedFileIds': allFileIds
    };
    return params;
  }

  // Checks one-shot transfer events (auto-accepted session completion /
  // cancellation) and fires the injected callback so the view shows its
  // overlay. Only sessions recorded in autoAcceptedSessions are consumed
  // here; auto-confirmed sessions are consumed by the transfer page itself
  // (they are routed there via handlePendingRequests), and manual sessions
  // are always left for the transfer page.
  checkTransferEvents(): void {
    let completed: string = peekRecvCompleted();
    if (completed.length > 0 && this.resolveAndClear(completed)) {
      consumeRecvCompleted();
      logger.info('[transferEvent] completed id=' + completed.substring(0, 8));
      if (!getSilentReceive() && this.onTransferEvent !== undefined) {
        this.onTransferEvent('completed', this.lastResolvedAlias);
      }
      return;
    }
    let cancelled: string = peekRecvCancelled();
    if (cancelled.length > 0 && this.resolveAndClear(cancelled)) {
      consumeRecvCancelled();
      logger.info('[transferEvent] cancelled id=' + cancelled.substring(0, 8));
      if (!getSilentReceive() && this.onTransferEvent !== undefined) {
        this.onTransferEvent('cancelled', this.lastResolvedAlias);
      }
    }
  }

  private lastResolvedAlias: string = ''

  // Resolves an auto-accepted session record. Returns true when a record
  // exists (and was cleared); false when the session was not auto-accepted
  // (the event is left for the TransferPage poller to consume).
  private resolveAndClear(id: string): boolean {
    let alias: string | undefined = this.autoAcceptedSessions[id];
    if (alias === undefined || alias.length === 0) {
      return false;
    }
    this.autoAcceptedSessions[id] = '';
    this.lastResolvedAlias = alias;
    return true;
  }
}
