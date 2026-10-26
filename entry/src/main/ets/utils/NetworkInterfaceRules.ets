import { NetworkType } from '../model/Types';

// 网络接口分类与启用判定规则：类型推断、白/黑名单默认策略的唯一来源。
// AppCore（枚举）、DeviceRepository / ServerRepository（过滤）、NetworkSettingsViewModel（展示）共用。

// 容器网桥接口前缀：本机是网段网关、对端位于 NAT 之后，局域网设备无法主动访问，
// 用于容器/兼容环境的内部通信，默认关闭（用户仍可在网络接口弹窗中手动开启）。
// 不含 tun / tap：VPN 与隧道接口（EasyTier、ZeroTier、WireGuard 等）是跨网传输的
// 主要通道，必须保留并默认启用。
const CONTAINER_BRIDGE_PREFIXES: Array<string> = [
  'anco', 'docker', 'veth', 'virbr', 'cni', 'flannel', 'kube'
];

// Docker 动态网桥接口名为 br-<12 位十六进制网络 ID>；br0、br-lan 等普通桥接不匹配，
// 按以太网处理。
const DOCKER_BRIDGE_PREFIX: string = 'br-';
const DOCKER_BRIDGE_ID_LENGTH: number = 12;

// VPN 与隧道接口前缀：对端位于同一虚拟网段且可主动互访，默认启用。
// 不含 ppp：PPP 拨号链路（3G/4G 模块）与 PPTP/L2TP 的 ppp 接口同名，无法区分，
// 归为未知类型、默认关闭，需要时由用户手动开启。
const TUNNEL_PREFIXES: Array<string> = [
  'tun', 'tap', 'utun', 'wg', 'zt', 'tailscale', 'ipsec', 'nebula', 'easytier', 'vpn'
];

function hasPrefix(lower: string, prefixes: Array<string>): boolean {
  for (let i = 0; i < prefixes.length; i++) {
    if (lower.startsWith(prefixes[i])) {
      return true;
    }
  }
  return false;
}

// 是否为 Docker 动态网桥：br- 后固定 12 位十六进制字符。
function isDockerBridgeName(lower: string): boolean {
  if (!lower.startsWith(DOCKER_BRIDGE_PREFIX) ||
    lower.length !== DOCKER_BRIDGE_PREFIX.length + DOCKER_BRIDGE_ID_LENGTH) {
    return false;
  }
  for (let i = DOCKER_BRIDGE_PREFIX.length; i < lower.length; i++) {
    let c: string = lower.charAt(i);
    let isHex: boolean = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    if (!isHex) {
      return false;
    }
  }
  return true;
}

// 按接口名前缀推断网络类型。
// connection API 返回的是有 netId 的连接网络：SoftAP（热点）与次要 STA 没有 netId、
// 不注册 NetworkAgent，永远不会出现在该列表里，需要按接口名补判。
// 容器网桥放在最前判定，避免被无线前缀干扰（如 anco-wlan1）。
export function networkTypeFromName(name: string): NetworkType {
  let lower: string = name.toLowerCase();
  if (hasPrefix(lower, CONTAINER_BRIDGE_PREFIXES) || isDockerBridgeName(lower)) {
    return NetworkType.bridge;
  }
  if (hasPrefix(lower, TUNNEL_PREFIXES)) {
    return NetworkType.vpn;
  }
  if (lower.startsWith('wlan') || lower.startsWith('wifi') || lower.startsWith('p2p') ||
    lower.startsWith('ap')) {
    return NetworkType.wifi;
  }
  if (lower.startsWith('eth') || lower.startsWith('usb') || lower.startsWith('en') ||
    lower.startsWith('br')) {
    return NetworkType.ethernet;
  }
  if (lower.startsWith('rmnet') || lower.startsWith('ccmni') || lower.startsWith('wwan') ||
    lower.startsWith('seth')) {
    return NetworkType.cellular;
  }
  return NetworkType.unknown;
}

// 新接入接口（既不在白名单也不在黑名单）的默认启用状态：
// WiFi、以太网、VPN/隧道放行；容器网桥、蜂窝、未知关闭。
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
