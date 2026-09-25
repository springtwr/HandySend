import { NetworkType } from '../model/Types';

// 网络类型文案与 IP 短码展示的唯一来源。
// 各处（NetworkSettingsSection/DeviceDetailsPage/设置本机信息）共用。

export function networkTypeLabel(type: NetworkType): ResourceStr {
  if (type === NetworkType.wifi) {
    return $r('app.string.network_type_wifi');
  } else if (type === NetworkType.cellular) {
    return $r('app.string.network_type_cellular');
  } else if (type === NetworkType.ethernet) {
    return $r('app.string.network_type_ethernet');
  }
  return $r('app.string.network_type_unknown');
}

// IP 短码：'192.168.1.24' → '#24'
export function ipShortCode(ip: string): string {
  let parts: Array<string> = ip.split('.');
  return '#' + parts[parts.length - 1];
}
