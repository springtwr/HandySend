import {
  getPendingRequests,
  getDiscoveredDevices,
  getLocalDeviceInfo,
  getDeviceType,
  getDeviceModel,
  isAutoFinish,
  peekRecvCompleted,
  peekRecvCancelled,
  consumeRecvCompleted,
  consumeRecvCancelled,
  removePendingRequest
} from '../service/AppService';
import { PendingRequest, DiscoveredDevice, LocalDeviceInfo } from '../model/Types';
import { getLogger, LogContext } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.DISCOVERY, 'HandySend:MainTab');

// 处理入站接收请求路由（业务规则取自
// MainTabFloating）+ 一次性传输事件浮层触发。
@ObservedV2
export class MainTabViewModel {
  @Trace public requestDismissed: Record<string, boolean> = {}
  @Trace public autoAcceptedSessions: Record<string, string> = {}
  // UIContext 边界的桥接：视图注入一个回调，用于
  // 展示完成/取消浮层。VM 文件不包含 UI 导入。
  public onTransferEvent: ((type: string, alias: string) => void) | undefined = undefined

  // 处理所有待处理的接收请求。返回 TransferPage 导航
  // 当请求必须路由到传输页时的参数，否则为 undefined
  // 当无需导航时（已关闭）。自动确认请求（标记为
  // 事件层已自动确认的）也会被路由，因此传输页
  // 展示进度/完成而非静默后台保存。
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
        // 事件层已自动接收；页面自动确认（不再
        // 重复响应调用）并展示进度/完成。
        removePendingRequest(r.sessionId);
        logger.debug('[diag] auto-confirmed session routed to transfer page, session=' +
          r.sessionId.substring(0, 8) + ' alias=' + r.senderAlias);
        return this.buildReceiveParams(r, clipboardPreview, isClipboard, true, true);
      }
      return this.buildReceiveParams(r, clipboardPreview, isClipboard, isClipboard, false);
    }
    return undefined;
  }

  private buildReceiveParams(r: PendingRequest, clipboardPreview: string, isClipboard: boolean,
    autoConfirm: boolean,
    alreadyAccepted: boolean): Record<string, Object | string | number | boolean | Array<string>> {
    let devices: Array<DiscoveredDevice> = getDiscoveredDevices();
    let senderDevice: DiscoveredDevice | undefined = undefined;
    for (let k = 0; k < devices.length; k++) {
      if (devices[k].fingerprint === r.senderFingerprint) {
        senderDevice = devices[k];
        break;
      }
    }
    // 优先使用 prepare_upload 事件携带的发送方身份；
    // 发现查找仅用于填补缺口（例如轮询回退路径）。
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

  // 检查一次性传输事件（自动接收的会话完成 /
  // 取消）并触发注入的回调，使视图显示其
  // 浮层。仅消费 autoAcceptedSessions 中记录的会话
  // 此处；自动确认的会话由传输页自身消费
  // （它们通过 handlePendingRequests 被路由到那里），以及手动会话
  // 始终留给传输页处理。
  checkTransferEvents(): void {
    let completed: string = peekRecvCompleted();
    if (completed.length > 0 && this.resolveAndClear(completed)) {
      consumeRecvCompleted();
      logger.debug('[transferEvent] completed id=' + completed.substring(0, 8));
      // 自动完成开启时接收在后台静默结束，不弹完成浮层
      if (!isAutoFinish() && this.onTransferEvent !== undefined) {
        this.onTransferEvent('completed', this.lastResolvedAlias);
      }
      return;
    }
    let cancelled: string = peekRecvCancelled();
    if (cancelled.length > 0 && this.resolveAndClear(cancelled)) {
      consumeRecvCancelled();
      logger.debug('[transferEvent] cancelled id=' + cancelled.substring(0, 8));
      // 自动完成开启时取消也在后台静默结束，不弹浮层
      if (!isAutoFinish() && this.onTransferEvent !== undefined) {
        this.onTransferEvent('cancelled', this.lastResolvedAlias);
      }
    }
  }

  private lastResolvedAlias: string = ''

  // 解析自动接收的会话记录。当存在记录时返回 true
  // 存在（且已清除）；会话未被自动接收时返回 false
  // （事件留给 TransferPage 轮询器消费）。
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
