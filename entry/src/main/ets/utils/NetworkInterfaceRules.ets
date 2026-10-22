import { NetworkType } from '../model/Types';

// 网络接口分类与启用判定规则：类型推断、白/黑名单默认策略的唯一来源。
// AppCore（枚举）、DeviceRepository / ServerRepository（过滤）、NetworkSettingsViewModel（展示）共用。

// 容器网桥接口前缀：本机是网段网关、对端位于 NAT 之后，局域网设备无法主动访问，
// 用于容器/兼容环境的内部通信，默认关闭（用户仍可在网络接口弹窗中手动开启）。
// 不含 tun / tap：虚拟组网（EasyTier、ZeroTier、WireGuard 等）的隧道接口是跨网传输的
// 主要通道，必须保留并默认启用。
const CONTAINER_BRIDGE_PREFIXES: Array<string> = [
  'anco', 'docker', 'veth', 'br-', 'virbr', 'cni', 'flannel', 'kube'
];

// 隧道与虚拟组网接口前缀：对端位于同一虚拟网段且可主动互访，默认启用。
const TUNNEL_PREFIXES: Array<string> = [
  'tun', 'tap', 'utun', 'wg', 'zt', 'tailscale', 'ppp', 'ipsec', 'nebula', 'easytier', 'vpn'
];

function hasPrefix(lower: string, prefixes: Array<string>): boolean {
  for (let i = 0; i < prefixes.length; i++) {
    if (lower.startsWith(prefixes[i])) {
      return true;
    }
  }
  return false;
}

// 按接口名前缀推断网络类型。
// connection API 返回的是有 netId 的连接网络：SoftAP（热点）与次要 STA 没有 netId、
// 不注册 NetworkAgent，永远不会出现在该列表里，需要按接口名补判。
// 容器网桥放在最前判定，避免被无线前缀干扰（如 anco-wlan1）。
export function networkTypeFromName(name: string): NetworkType {
  let lower: string = name.toLowerCase();
  if (hasPrefix(lower, CONTAINER_BRIDGE_PREFIXES)) {
    return NetworkType.bridge;
  }
  if (hasPrefix(lower, TUNNEL_PREFIXES)) {
    return NetworkType.vpn;
  }
  if (lower.startsWith('wlan') || lower.startsWith('wifi') || lower.startsWith('p2p') ||
    lower.startsWith('ap')) {
    return NetworkType.wifi;
  }
  if (lower.startsWith('eth') || lower.startsWith('usb') || lower.startsWith('en')) {
    return NetworkType.ethernet;
  }
  if (lower.startsWith('rmnet') || lower.startsWith('ccmni') || lower.startsWith('wwan') ||
    lower.startsWith('seth')) {
    return NetworkType.cellular;
  }
  return NetworkType.unknown;
}

// 新接入接口（既不在白名单也不在黑名单）的默认启用状态：
// WiFi、以太网、隧道/虚拟组网放行；容器网桥、蜂窝、未知关闭。
export function isEnabledByDefault(type: NetworkType): boolean {
  return type === NetworkType.wifi || type === NetworkType.ethernet || type === NetworkType.vpn;
}

// 接口是否启用（参与发现与接收）。黑名单优先，其次白名单，两者都未列出时按类型取默认。
export function isInterfaceEnabled(name: string, type: NetworkType,
  whitelist: Array<string>, blacklist: Array<string>): boolean {
  for (let i = 0; i < blacklist.length; i++) {
    if (blacklist[i] === name) {
      return false;
    }
  }
  for (let i = 0; i < whitelist.length; i++) {
    if (whitelist[i] === name) {
      return true;
    }
  }
  return isEnabledByDefault(type);
}
