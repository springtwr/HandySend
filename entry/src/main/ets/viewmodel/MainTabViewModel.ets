import { hilog } from '@kit.PerformanceAnalysisKit';
import { getPendingRequests, getDiscoveredDevices, respondToRequest, getLocalDeviceInfo, getDeviceType, getDeviceModel,
  getAutoSaveMode, getSilentReceive, peekRecvCompleted, peekRecvCancelled,
  consumeRecvCompleted, consumeRecvCancelled } from '../service/AppService';
import { getFavorites as getFavoritesService } from '../service/FavoritesService';
import { PendingRequest, DiscoveredDevice, LocalDeviceInfo, FavoriteDevice } from '../model/Types';

// Handles incoming receive-request routing (business rules extracted from
// MainTabFloating) + one-shot transfer-event overlay triggers.
@Observed
export class MainTabViewModel {
  public requestDismissed: Record<string, boolean> = {}
  public autoAcceptedSessions: Record<string, string> = {}
  // Bridge for the UIContext boundary: the view injects a callback used to
  // show the completion/cancellation overlay. VM file has no UI imports.
  public onTransferEvent: ((type: string, alias: string) => void) | undefined = undefined

  // Processes all pending receive requests. Returns TransferPage navigation
  // params when a request must be routed to the transfer page, or undefined
  // when nothing needs navigation (auto-accepted, clipboard preview, dismissed).
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

      let autoSave: boolean = false;
      if (!isClipboard) {
        let autoSaveMode: string = getAutoSaveMode() as string;
        if (autoSaveMode === 'on') {
          autoSave = true;
        } else if (autoSaveMode === 'paired') {
          try {
            let favs: Array<FavoriteDevice> = getFavoritesService();
            for (let j = 0; j < favs.length; j++) {
              if (r.senderFingerprint === favs[j].fingerprint) {
                autoSave = true;
                break;
              }
            }
          } catch (_e) {}
        }
      }

      if (autoSave) {
        this.autoAcceptedSessions[r.sessionId] = r.senderAlias;
        hilog.info(0x0001, 'LocalSend:MainTabFloating',
          '[diag] auto-accept session=%{public}s alias=%{public}s', r.sessionId, r.senderAlias);
        let allFileIds: Array<string> = [];
        for (let j = 0; j < r.files.length; j++) {
          allFileIds.push(r.files[j].fileId);
        }
        respondToRequest(r.sessionId, true, allFileIds);
      } else {
        let devices: Array<DiscoveredDevice> = getDiscoveredDevices();
        let senderDevice: DiscoveredDevice | undefined = undefined;
        for (let k = 0; k < devices.length; k++) {
          if (devices[k].fingerprint === r.senderFingerprint) {
            senderDevice = devices[k];
            break;
          }
        }
        let senderIp: string = '';
        let senderDeviceType: string = 'mobile';
        let senderDeviceModel: string = '';
        if (senderDevice !== undefined) {
          senderIp = senderDevice.ip;
          senderDeviceType = senderDevice.deviceType;
          senderDeviceModel = senderDevice.deviceModel;
        }
        let localInfo: LocalDeviceInfo = getLocalDeviceInfo();
        let totalSize: number = 0;
        let allFileIds: Array<string> = [];
        for (let k = 0; k < r.files.length; k++) {
          totalSize = totalSize + r.files[k].size;
          if (!isClipboard) {
            allFileIds.push(r.files[k].fileId);
          }
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
          'autoConfirm': isClipboard,
          'fileCount': r.files.length,
          'totalSize': totalSize,
          'isClipboard': isClipboard,
          'clipboardContent': clipboardPreview,
          'acceptedFileIds': allFileIds
        };
        return params;
      }
    }
    return undefined;
  }

  // Checks one-shot transfer events (auto-accepted session completion /
  // cancellation) and fires the injected callback so the view shows its
  // overlay. Non-auto-accepted events are left unconsumed for TransferPage.
  checkTransferEvents(): void {
    let completed: string = peekRecvCompleted();
    if (completed.length > 0 && this.resolveAndClear(completed)) {
      consumeRecvCompleted();
      hilog.info(0x0001, 'LocalSend:MainTab', '[transferEvent] completed id=%{public}s', completed.substring(0, 8));
      if (!getSilentReceive() && this.onTransferEvent !== undefined) {
        this.onTransferEvent('completed', this.lastResolvedAlias);
      }
      return;
    }
    let cancelled: string = peekRecvCancelled();
    if (cancelled.length > 0 && this.resolveAndClear(cancelled)) {
      consumeRecvCancelled();
      hilog.info(0x0001, 'LocalSend:MainTab', '[transferEvent] cancelled id=%{public}s', cancelled.substring(0, 8));
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
