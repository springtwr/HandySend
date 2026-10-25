/**
 * WebAddress.ets — 网页服务可用地址的纯函数
 *
 * 网页服务监听全部网卡；这里只负责从本机接口列表中筛出可展示的 IPv4 地址，
 * 按 Wi-Fi → 有线 → VPN → 网桥 → 其他排序，并处理用户筛选与上次选择。
 * 不依赖 UI、系统上下文或仓储状态，便于设备端单元测试。
 */

import { NetworkInterface, NetworkType } from './Types';
import { isInterfaceEnabled } from '../utils/NetworkInterfaceRules';

/** 可在二维码/地址中展示的网页地址。 */
export interface WebAddress {
  name: string
  ip: string
  type: NetworkType
  isDefault: boolean
}

/** 网页端口校验结果。 */
export enum WebPortError {
  none = 'none',
  invalid = 'invalid',
  conflict = 'conflict'
}

/** 是否为合法的点分十进制 IPv4。 */
function isIpv4(ip: string): boolean {
  let parts: Array<string> = ip.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (let i = 0; i < parts.length; i++) {
    let part: string = parts[i];
    if (part.length === 0) {
      return false;
    }
    let value: number = Number(part);
    if (!Number.isInteger(value) || value < 0 || value > 255) {
      return false;
    }
  }
  return true;
}

/** 地址排序权重：Wi-Fi → 有线 → VPN → 网桥 → 未知 → 蜂窝。 */
function typeRank(type: NetworkType): number {
  if (type === NetworkType.wifi) {
    return 0;
  }
  if (type === NetworkType.ethernet) {
    return 1;
  }
  if (type === NetworkType.vpn) {
    return 2;
  }
  if (type === NetworkType.bridge) {
    return 3;
  }
  if (type === NetworkType.unknown) {
    return 4;
  }
  return 5;
}

/** 接口是否具备可展示的网页地址（排除回环、链路本地、0.0.0.0 与非法 IPv4）。 */
export function isEligibleWebInterface(netIf: NetworkInterface): boolean {
  if (!isIpv4(netIf.ip)) {
    return false;
  }
  if (netIf.ip === '0.0.0.0' || netIf.ip.startsWith('127.') || netIf.ip.startsWith('169.254.')) {
    return false;
  }
  return true;
}

/**
 * 列出可展示的网页地址。
 * @param interfaces 本机接口（通常来自 updateLocalInterfaces）
 * @param whitelist 强制启用的接口名
 * @param blacklist 强制禁用的接口名；未列出的接口按类型取默认（Wi-Fi/有线/VPN 启用）
 */
export function listWebAddresses(interfaces: Array<NetworkInterface>,
  whitelist: Array<string>, blacklist: Array<string>): Array<WebAddress> {
  let candidates: Array<WebAddress> = [];
  for (let i = 0; i < interfaces.length; i++) {
    let netIf = interfaces[i];
    if (!isEligibleWebInterface(netIf)) {
      continue;
    }
    if (!isInterfaceEnabled(netIf.name, netIf.type, whitelist, blacklist)) {
      continue;
    }
    candidates.push({
      name: netIf.name,
      ip: netIf.ip,
      type: netIf.type,
      isDefault: netIf.isDefault
    });
  }
  candidates.sort((a: WebAddress, b: WebAddress): number => {
    let rank: number = typeRank(a.type) - typeRank(b.type);
    if (rank !== 0) {
      return rank;
    }
    if (a.isDefault !== b.isDefault) {
      return a.isDefault ? -1 : 1;
    }
    if (a.name < b.name) {
      return -1;
    }
    if (a.name > b.name) {
      return 1;
    }
    return 0;
  });
  // 同一 IP 可能出现在多个接口（如网桥与物理网卡），按排序保留优先级最高的一条
  let result: Array<WebAddress> = [];
  for (let i = 0; i < candidates.length; i++) {
    let duplicated: boolean = false;
    for (let k = 0; k < result.length; k++) {
      if (result[k].ip === candidates[i].ip) {
        duplicated = true;
        break;
      }
    }
    if (!duplicated) {
      result.push(candidates[i]);
    }
  }
  return result;
}

/** 按上次选择取地址；选择不存在时回退到排序后的第一个。 */
export function pickWebAddress(addresses: Array<WebAddress>,
  selectedIp: string): WebAddress | undefined {
  for (let i = 0; i < addresses.length; i++) {
    if (addresses[i].ip === selectedIp) {
      return addresses[i];
    }
  }
  return addresses.length > 0 ? addresses[0] : undefined;
}

/** 组装网页地址；ip 或 port 无效时返回空串。 */
export function buildWebUrl(https: boolean, ip: string, port: number): string {
  if (ip.length === 0 || port <= 0) {
    return '';
  }
  return (https ? 'https' : 'http') + '://' + ip + ':' + port;
}

/** 校验网页端口：1024-65535，且不得等于当前 LocalSend 端口。 */
export function validateWebPort(port: number, localSendPort: number): WebPortError {
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    return WebPortError.invalid;
  }
  if (port === localSendPort) {
    return WebPortError.conflict;
  }
  return WebPortError.none;
}

/** 实际端口与配置端口不一致且两者均有效时视为回退。 */
export function isWebPortFallback(configuredPort: number, actualPort: number): boolean {
  return configuredPort > 0 && actualPort > 0 && configuredPort !== actualPort;
}
