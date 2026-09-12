import {
  getPendingRequests,
  getDiscoveredDevices,
  getLocalDeviceInfo,
  getDeviceType,
  getDeviceModel,
  removePendingRequest
} from '../service/AppService';
import { PendingRequest, DiscoveredDevice, LocalDeviceInfo, TransferFileDescriptor } from '../model/Types';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.DISCOVERY, 'HandySend:MainTab', '主页');

// 处理入站接收请求路由（业务规则取自
// MainTabFloating）。
@ObservedV2
export class MainTabViewModel {
  @Trace public requestDismissed: Record<string, boolean> = {}

  // 处理所有待处理的接收请求。返回 TransferPage 导航
  // 当请求必须路由到传输页时的参数，否则为 undefined
  // 当无需导航时（已关闭）。自动确认请求（标记为
  // 事件层已自动确认的）也会被路由，因此传输页
  // 展示进度/完成而非静默后台保存。
  handlePendingRequests():
  Record<string, Object | string | number | boolean | Array<string> | Array<TransferFileDescriptor>> | undefined {
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
        // 事件层已自动接收；页面自动确认（不重复
        // 响应调用）并展示进度/完成。
        removePendingRequest(r.sessionId);
        logger.debug('auto-confirmed session routed to transfer page, session=' +
          r.sessionId.substring(0, 8) + ' alias=' + r.senderAlias);
        return this.buildReceiveParams(r, clipboardPreview, isClipboard, true, true);
      }
      return this.buildReceiveParams(r, clipboardPreview, isClipboard, isClipboard, false);
    }
    return undefined;
  }

  private buildReceiveParams(r: PendingRequest, clipboardPreview: string, isClipboard: boolean, autoConfirm: boolean,
    alreadyAccepted: boolean):
    Record<string, Object | string | number | boolean | Array<string> | Array<TransferFileDescriptor>> {
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
    let fileDescriptors: Array<TransferFileDescriptor> = [];
    for (let k = 0; k < r.files.length; k++) {
      totalSize = totalSize + r.files[k].size;
      allFileIds.push(r.files[k].fileId);
      fileDescriptors.push({
        fileId: r.files[k].fileId,
        fileName: r.files[k].fileName,
        size: r.files[k].size,
        fileType: r.files[k].fileType
      });
    }
    let params: Record<string, Object | string | number | boolean | Array<string> | Array<TransferFileDescriptor>> = {
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
      'fileDescriptors': fileDescriptors,
      'isClipboard': isClipboard,
      'clipboardContent': clipboardPreview,
      'acceptedFileIds': allFileIds
    };
    return params;
  }
}
