import { NetworkType } from '../model/Types';

// 网络类型文案、图标与 IP 短码展示的唯一来源。
// 各处（NetworkSettingsSection/WebSettingsSection/DeviceDetailsPage/设置本机信息）共用。

export function networkTypeLabel(type: NetworkType): ResourceStr {
  if (type === NetworkType.wifi) {
    return $r('app.string.network_type_wifi');
  } else if (type === NetworkType.cellular) {
    return $r('app.string.network_type_cellular');
  } else if (type === NetworkType.ethernet) {
    return $r('app.string.network_type_ethernet');
  } else if (type === NetworkType.vpn) {
    return $r('app.string.network_type_vpn');
  } else if (type === NetworkType.bridge) {
    return $r('app.string.network_type_bridge');
  }
  return $r('app.string.network_type_unknown');
}

// 网络类型图标：网络接口列表行首标识。
export function networkTypeSymbol(type: NetworkType): Resource {
  if (type === NetworkType.wifi) {
    return $r('sys.symbol.wifi');
  } else if (type === NetworkType.cellular) {
    return $r('sys.symbol.signal');
  } else if (type === NetworkType.vpn) {
    return $r('sys.symbol.lock_shield_fill');
  } else if (type === NetworkType.bridge) {
    return $r('sys.symbol.square_stack_3d_fill');
  } else if (type === NetworkType.unknown) {
    return $r('sys.symbol.questionmark_circle_fill');
  } else {
    // 以太网使用通用设备图标
    return $r('sys.symbol.computer_fill');
  }
}

// IP 短码：'192.168.1.24' → '#24'
export function ipShortCode(ip: string): string {
  let parts: Array<string> = ip.split('.');
  return '#' + parts[parts.length - 1];
}
