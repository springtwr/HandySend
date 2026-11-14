/**
 * NetworkInterfaceSelection.ets — 按对端 IP 选择承载会话的本机接口
 *
 * 会话详情展示「本机 IP / 接口」时需反映本次传输实际使用的网卡：
 * 优先取与对端 IP 同网段且前缀最长的接口；对端 IP 不可用或无匹配时，
 * 由调用方决定留空或回退默认网络接口/本机主接口。
 * 纯函数，不依赖 UI、系统上下文或仓储状态，便于设备端单元测试。
 */

import { NetworkInterface } from '../model/Types';

/** 解析点分十进制 IPv4 为四段数值；格式非法时返回空数组。 */
function parseIpv4(ip: string): Array<number> {
  let parts: Array<string> = ip.split('.');
  if (parts.length !== 4) {
    return [];
  }
  let result: Array<number> = [];
  for (let i = 0; i < parts.length; i++) {
    let part: string = parts[i];
    let value: number = Number(part);
    // 要求规范十进制：拒绝空段、前导零、正负号、空白与非数字
    if (!Number.isInteger(value) || value < 0 || value > 255 || part !== String(value)) {
      return [];
    }
    result.push(value);
  }
  return result;
}

/**
 * 接口 IP 是否可参与网段匹配：排除未配置（0.x）与回环（127.x）。
 * 链路本地地址（169.254.x）是直连链路的有效地址，保留参与匹配。
 */
function isMatchableLocalIp(ip: string): boolean {
  let parts: Array<number> = parseIpv4(ip);
  if (parts.length !== 4) {
    return false;
  }
  return parts[0] !== 0 && parts[0] !== 127;
}

/** 是否为合法的点分十进制 IPv4 地址（仅做语法校验，不代表该地址可路由）。 */
export function isIpv4Address(ip: string): boolean {
  return parseIpv4(ip).length === 4;
}

/**
 * 判断 IPv4 地址是否落在指定网段内。
 * @param ip 待判断地址
 * @param networkIp 网段内的任一地址（通常为接口自身 IP）
 * @param prefixLength 前缀长度 1-32（0 或越界视为不可判定）
 */
export function isIpv4InSubnet(ip: string, networkIp: string, prefixLength: number): boolean {
  if (!Number.isInteger(prefixLength) || prefixLength < 1 || prefixLength > 32) {
    return false;
  }
  let ipParts: Array<number> = parseIpv4(ip);
  let netParts: Array<number> = parseIpv4(networkIp);
  if (ipParts.length !== 4 || netParts.length !== 4) {
    return false;
  }
  let fullBytes: number = Math.floor(prefixLength / 8);
  for (let i = 0; i < fullBytes; i++) {
    if (ipParts[i] !== netParts[i]) {
      return false;
    }
  }
  let remainingBits: number = prefixLength % 8;
  if (remainingBits === 0) {
    return true;
  }
  let mask: number = (0xFF << (8 - remainingBits)) & 0xFF;
  return (ipParts[fullBytes] & mask) === (netParts[fullBytes] & mask);
}

/**
 * 选择默认路由所在的网络接口（用于跨网段对端：本机源地址由默认路由决定）。
 * 调用方传入启停过滤后的接口列表；无默认标记或地址不可用时返回 undefined。
 */
export function selectDefaultRouteInterface(interfaces: Array<NetworkInterface>): NetworkInterface | undefined {
  for (let i = 0; i < interfaces.length; i++) {
    if (interfaces[i].isDefault && isMatchableLocalIp(interfaces[i].ip)) {
      return interfaces[i];
    }
  }
  return undefined;
}

/**
 * 选择承载对端会话的本机接口：对端 IP 落在接口网段内时取前缀最长者，
 * 前缀相同时优先默认网络接口。对端 IP 缺失、非法或无可匹配接口时返回 undefined。
 */
export function selectInterfaceForPeer(interfaces: Array<NetworkInterface>,
  peerIp: string): NetworkInterface | undefined {
  if (!isIpv4Address(peerIp)) {
    return undefined;
  }
  let selected: NetworkInterface | undefined = undefined;
  let selectedPrefix: number = -1;
  for (let i = 0; i < interfaces.length; i++) {
    let netIf = interfaces[i];
    if (!isMatchableLocalIp(netIf.ip)) {
      continue;
    }
    if (!isIpv4InSubnet(peerIp, netIf.ip, netIf.prefixLength)) {
      continue;
    }
    let better: boolean = netIf.prefixLength > selectedPrefix;
    if (!better && netIf.prefixLength === selectedPrefix && selected !== undefined &&
      !selected.isDefault && netIf.isDefault) {
      better = true;
    }
    if (better) {
      selected = netIf;
      selectedPrefix = netIf.prefixLength;
    }
  }
  return selected;
}
