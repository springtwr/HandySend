/**
 * MtaMainModels.ets — MTA 主流程模型与纯函数
 *
 * 仅包含主流程（发送页并入 MTA 设备、MTA 专用传输页）所需的数据视图类型、
 * 阶段文案与可单测纯函数（无系统 API 依赖），供 MtaRepository / SendViewModel /
 * MtaTransferViewModel / MtaTransferPage 共用。
 */

import { DiscoveredDevice, TransferFileDescriptor } from '../Types';
import { MTA_PARTIAL_COMPLETED_TEXT, MtaDiscoveredDevice, MtaSenderStage } from './MtaSendModels';
import { ReceiverStage } from './MtaProtocolModels';

// ── 传输页模式常量 ──

/** 发送模式 */
export const MTA_MODE_SEND: string = 'send';
/** 接收模式 */
export const MTA_MODE_RECEIVE: string = 'receive';

/** MTA 来源协议标识（用于发送路由分流与列表区分） */
export const MTA_PROTOCOL: string = 'mta';

/** 品牌未知时的回退徽标文案（附近设备列表与传输页设备卡共用） */
export const MTA_UNKNOWN_BRAND: string = 'Android';

// ── 页面路由参数 ──

/** MtaTransferPage 路由参数（经 MtaTransferPageBuilder 传入） */
export interface MtaTransferPageParams {
  /** 模式：send / receive */
  mode: string
  /** 对端展示别名 */
  targetAlias: string
  /** 对端设备类型（图标映射） */
  deviceType: string
  /** 对端设备型号（无则空串） */
  deviceModel: string
  /** 品牌徽标文本（品牌名；品牌未知时为固定回退文案） */
  badgeText: string
  /** 目标 MTA 设备的 BLE 标识 */
  bleAddress: string
  /** 目标 MTA 设备的发送者 ID 十六进制 */
  senderIdHex: string
  /** 目标品牌 ID（-1 表示未知） */
  brandId: number
  /** 目标是否支持 5GHz */
  is5Ghz: boolean
  /** 目标信号强度（dBm） */
  rssi: number
  /** 待发送文件 URI 清单（文本发送时为空） */
  fileUris: Array<string>
  /** 待发送文件元数据清单（用于展示） */
  fileDescriptors: Array<TransferFileDescriptor>
  /** 是否以 MTA 原生文本方式发送 */
  isTextSend: boolean
  /** 文本内容（isTextSend 为 true 时有效） */
  textContent: string
}

/** 构造空的传输页参数（接收模式使用） */
export function buildMtaReceivePageParams(): MtaTransferPageParams {
  return {
    mode: MTA_MODE_RECEIVE,
    targetAlias: '',
    deviceType: 'mobile',
    deviceModel: '',
    badgeText: '',
    bleAddress: '',
    senderIdHex: '',
    brandId: -1,
    is5Ghz: false,
    rssi: 0,
    fileUris: [],
    fileDescriptors: [],
    isTextSend: false,
    textContent: ''
  };
}

/**
 * 构造发送模式页面参数（纯函数，供发送页导航与单测使用）。
 * 文本发送时 fileUris 传空数组，仅携带 textContent。
 */
export function buildMtaSendPageParams(device: DiscoveredDevice, fileUris: Array<string>,
  fileDescriptors: Array<TransferFileDescriptor>, isTextSend: boolean, textContent: string): MtaTransferPageParams {
  let brandId: number = device.mtaBrandId !== undefined ? device.mtaBrandId : -1;
  let is5Ghz: boolean = device.mtaIs5Ghz !== undefined ? device.mtaIs5Ghz : false;
  let rssi: number = device.mtaRssi !== undefined ? device.mtaRssi : 0;
  return {
    mode: MTA_MODE_SEND,
    targetAlias: device.alias,
    deviceType: device.deviceType,
    deviceModel: device.deviceModel,
    badgeText: mtaBrandBadgeText(device.mtaBrandName),
    bleAddress: device.mtaBleAddress !== undefined ? device.mtaBleAddress : device.fingerprint,
    senderIdHex: device.mtaSenderIdHex !== undefined ? device.mtaSenderIdHex : '',
    brandId: brandId,
    is5Ghz: is5Ghz,
    rssi: rssi,
    fileUris: fileUris,
    fileDescriptors: fileDescriptors,
    isTextSend: isTextSend,
    textContent: textContent
  };
}

/** 由页面参数还原 MTA 目标设备（供 MtaSendService 发起发送，可单测） */
export function mtaDeviceFromParams(params: MtaTransferPageParams): MtaDiscoveredDevice {
  let device = new MtaDiscoveredDevice();
  device.bleAddress = params.bleAddress;
  device.deviceName = params.targetAlias;
  device.senderIdHex = params.senderIdHex;
  device.brandId = params.brandId;
  device.brandName = params.badgeText;
  device.is5Ghz = params.is5Ghz;
  device.rssi = params.rssi;
  return device;
}

// ── 纯函数：MTA 设备 → 统一设备形状 ──

/**
 * 把 MTA 扫描发现的设备映射为统一 `DiscoveredDevice` 形状（纯函数）。
 * fingerprint 取 BLE 设备标识，protocol 固定为 'mta'，无 IP/端口/型号。
 */
export function mtaDeviceToDiscoveredDevice(device: MtaDiscoveredDevice, now: number): DiscoveredDevice {
  let alias = device.deviceName.length > 0 ? device.deviceName : device.bleAddress;
  return {
    alias: alias,
    ip: '',
    port: 0,
    fingerprint: device.bleAddress,
    version: '',
    deviceModel: '',
    deviceType: 'mobile',
    protocol: MTA_PROTOCOL,
    lastSeen: now,
    channels: [],
    mtaBleAddress: device.bleAddress,
    mtaSenderIdHex: device.senderIdHex,
    mtaBrandId: device.brandId,
    mtaBrandName: device.brandName,
    mtaIs5Ghz: device.is5Ghz,
    mtaRssi: device.rssi
  };
}

/** 是否 MTA 来源设备（用于列表变体与发送路由分流） */
export function isMtaDevice(device: DiscoveredDevice): boolean {
  return device.protocol === MTA_PROTOCOL;
}

/**
 * 品牌徽标文本：已知品牌返回品牌名，未知（'未知'/'未知(x)'/空/undefined）返回固定回退文案 `Android`。
 * 附近设备列表与传输页设备卡共用此函数，保证两处徽标文案一致。
 */
export function mtaBrandBadgeText(brandName: string | undefined): string {
  if (brandName === undefined || brandName.length === 0) {
    return MTA_UNKNOWN_BRAND;
  }
  if (brandName.startsWith('未知')) {
    return MTA_UNKNOWN_BRAND;
  }
  return brandName;
}

// ── 纯函数：文本内容提取 ──

/** 合并多段文本内容（去空行后以换行连接）；无有效内容返回空串 */
export function combineTextContents(contents: Array<string>): string {
  let parts: Array<string> = [];
  for (let i = 0; i < contents.length; i++) {
    if (contents[i].length > 0) {
      parts.push(contents[i]);
    }
  }
  return parts.join('\n');
}

// ── 纯函数：阶段文案（会话级展示） ──

/** 发送阶段 → 会话级展示文本 */
export function mtaSendStageLabel(stage: MtaSenderStage): string {
  switch (stage) {
    case MtaSenderStage.IDLE:
      return '未开始';
    case MtaSenderStage.SCANNING:
      return '正在搜索设备';
    case MtaSenderStage.GATT_CONNECTING:
      return '正在连接设备';
    case MtaSenderStage.GROUP_CREATING:
      return '正在建立连接';
    case MtaSenderStage.SERVER_STARTING:
      return '正在准备传输';
    case MtaSenderStage.P2P_INFO_WRITTEN:
      return '正在等待对方加入';
    case MtaSenderStage.WAITING_WS:
      return '正在等待对方连接';
    case MtaSenderStage.NEGOTIATED:
      return '正在协商';
    case MtaSenderStage.REQUEST_SENT:
      return '已发送传输请求';
    case MtaSenderStage.TRANSFERRING:
      return '正在发送';
    case MtaSenderStage.COMPLETED:
      return '发送完成';
    case MtaSenderStage.PARTIAL:
      return MTA_PARTIAL_COMPLETED_TEXT;
    case MtaSenderStage.FAILED:
      return '发送失败';
    case MtaSenderStage.CANCEL_NOTIFYING:
      return '正在通知对方取消';
    case MtaSenderStage.CANCELLED:
      return '已取消';
    default:
      return '未知';
  }
}

/** 接收阶段 → 会话级展示文本 */
export function mtaReceiveStageLabel(stage: ReceiverStage): string {
  switch (stage) {
    case ReceiverStage.IDLE:
      return '未开始';
    case ReceiverStage.SERVICE_RUNNING:
      return '等待对方连接';
    case ReceiverStage.P2P_INFO_RECEIVED:
      return '已收到连接凭据';
    case ReceiverStage.P2P_CONNECTING:
      return '正在建立连接';
    case ReceiverStage.P2P_CONNECTED:
      return '已建立连接';
    case ReceiverStage.WS_CONNECTING:
      return '正在连接对方';
    case ReceiverStage.NEGOTIATED:
      return '正在协商';
    case ReceiverStage.REQUEST_RECEIVED:
      return '等待确认';
    case ReceiverStage.DOWNLOADING:
      return '正在接收';
    case ReceiverStage.SAVING:
      return '正在保存';
    case ReceiverStage.COMPLETED:
      return '接收完成';
    case ReceiverStage.FAILED:
      return '接收失败';
    default:
      return '未知';
  }
}

/** 文本条目固定文件名 */
export const MTA_SHARED_TEXT_FILE_NAME: string = 'sharedText.txt';

/** 网络数据已全部收完、本机仍在解压/落盘时的阶段文案（避免继续报告网络速率） */
export const MTA_RECEIVE_SAVING_TEXT: string = '解压/保存中';

/** 进度字节文案标签：分子为有效数据（发送已读源字节 / 接收已解压字节） */
export const MTA_PROGRESS_PROCESSED_LABEL: string = '已处理';
/** 进度字节文案标签：分母为声明总大小 */
export const MTA_PROGRESS_TOTAL_LABEL: string = '共';
