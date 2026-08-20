import { deviceInfo } from '@kit.BasicServicesKit';
import { preferencesUtil } from '../../utils/PreferencesUtil';
import { generateAlias } from '../../utils/AliasGenerator';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { LocalDeviceInfo } from '../../model/Types';
import { getLocalIp, getLocalInterfaces, getServerFingerprint } from './AppCore';
import { markServerNeedsRestart } from './SettingsRepository';

const logger = getLogger(LogDomains.DISCOVERY, 'HandySend:DeviceRepository');

// ── 设备身份状态 ──

let alias = '';
let deviceModel = '';
let deviceType = 'mobile';

export function getDeviceAlias(): string {
  return alias;
}

export function getDeviceType(): string {
  return deviceType;
}

export function getDeviceModel(): string {
  return deviceModel;
}

function getSystemDeviceType(): string {
  let sysType: string = deviceInfo.deviceType;
  if (sysType === 'tablet') {
    return 'tablet';
  } else if (sysType === '2in1' || sysType === 'tv') {
    return 'desktop';
  }
  // 默认、手机、穿戴设备等
  return 'mobile';
}

export function refreshDeviceInfo(): void {
  let customAlias = preferencesUtil.getString('customAlias', '');
  let customDeviceType = preferencesUtil.getString('customDeviceType', '');
  let customDeviceModel = preferencesUtil.getString('customDeviceModel', '');

  let newAlias = customAlias || (deviceInfo.manufacture + ' ' + deviceInfo.productModel);
  let newDeviceType = customDeviceType || getSystemDeviceType();
  let newDeviceModel = customDeviceModel || deviceInfo.productModel;

  // 仅当设备身份实际变化时才标记服务器重启
  if (newAlias !== alias || newDeviceType !== deviceType || newDeviceModel !== deviceModel) {
    alias = newAlias;
    deviceType = newDeviceType;
    deviceModel = newDeviceModel;
    markServerNeedsRestart();
  }
}

export function initDeviceIdentity(): void {
  // 直接初始化设备身份（不经 refreshDeviceInfo，因为它会
  // 会误将模块级默认值 '' 到真实值的切换检测为"变化"）
  let customAlias = preferencesUtil.getString('customAlias', '');
  let customDeviceType = preferencesUtil.getString('customDeviceType', '');
  let customDeviceModel = preferencesUtil.getString('customDeviceModel', '');

  // 首次启动时自动生成随机昵称
  if (!preferencesUtil.has('customAlias') || customAlias === '') {
    customAlias = generateAlias();
    preferencesUtil.setString('customAlias', customAlias);
  }

  alias = customAlias;
  deviceType = customDeviceType || getSystemDeviceType();
  deviceModel = customDeviceModel || deviceInfo.productModel;
}

export function getLocalDeviceInfo(): LocalDeviceInfo {
  let info: LocalDeviceInfo = {
    alias: alias,
    fingerprint: getServerFingerprint(),
    ip: getLocalIp(),
    interfaces: getLocalInterfaces()
  };
  return info;
}
