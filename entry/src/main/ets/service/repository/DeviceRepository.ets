import { deviceInfo } from '@kit.BasicServicesKit';
import { preferencesUtil } from '../../utils/PreferencesUtil';
import { generateAlias, getSystemDeviceName } from '../../utils/AliasGenerator';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { LocalDeviceInfo, NetworkInterface } from '../../model/Types';
import { getLocalIp, getLocalInterfaces, getServerFingerprint } from './AppCore';
import { getNetworkWhitelist, getNetworkBlacklist, markServerNeedsRestart } from './SettingsRepository';

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
  } else if (sysType === '2in1') {
    return 'desktop';
  }
  // 默认、手机、穿戴、tv 等设备
  return 'mobile';
}

export function refreshDeviceInfo(): void {
  let customAlias = preferencesUtil.getString('customAlias', '');
  let customDeviceType = preferencesUtil.getString('customDeviceType', '');

  let newAlias = customAlias || getSystemDeviceName();
  let newDeviceType = customDeviceType || getSystemDeviceType();
  let newDeviceModel = deviceInfo.productModel;

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

  // 首次启动时自动生成随机昵称
  if (!preferencesUtil.has('customAlias') || customAlias === '') {
    customAlias = generateAlias();
    preferencesUtil.setString('customAlias', customAlias);
  }

  alias = customAlias;
  deviceType = customDeviceType || getSystemDeviceType();
  deviceModel = deviceInfo.productModel;
}

export function getLocalDeviceInfo(): LocalDeviceInfo {
  let allInterfaces = getLocalInterfaces();
  // 白名单/黑名单存储网络类型（如 wifi,ethernet），按类型过滤接口：
  // 黑名单类型中的接口排除；白名单非空时只保留白名单类型中的接口。
  // 两者都为空时允许所有接口。
  let whitelistText = getNetworkWhitelist();
  let blacklistText = getNetworkBlacklist();
  let whitelistedTypes: Array<string> = [];
  let blacklistedTypes: Array<string> = [];
  if (whitelistText.length > 0) {
    let parts = whitelistText.split(',');
    for (let i = 0; i < parts.length; i++) {
      let trimmed = parts[i].trim();
      if (trimmed.length > 0) {
        whitelistedTypes.push(trimmed);
      }
    }
  }
  if (blacklistText.length > 0) {
    let parts = blacklistText.split(',');
    for (let i = 0; i < parts.length; i++) {
      let trimmed = parts[i].trim();
      if (trimmed.length > 0) {
        blacklistedTypes.push(trimmed);
      }
    }
  }
  let filtered: Array<NetworkInterface> = [];
  for (let i = 0; i < allInterfaces.length; i++) {
    let iface = allInterfaces[i];
    // 黑名单类型优先排除
    let isBlacklisted = false;
    for (let j = 0; j < blacklistedTypes.length; j++) {
      if (blacklistedTypes[j] === iface.type) {
        isBlacklisted = true;
        break;
      }
    }
    if (isBlacklisted) {
      continue;
    }
    // 白名单为空时全部允许；非空时只保留白名单类型中的
    if (whitelistedTypes.length > 0) {
      let isWhitelisted = false;
      for (let j = 0; j < whitelistedTypes.length; j++) {
        if (whitelistedTypes[j] === iface.type) {
          isWhitelisted = true;
          break;
        }
      }
      if (!isWhitelisted) {
        continue;
      }
    }
    filtered.push(iface);
  }

  let info: LocalDeviceInfo = {
    alias: alias,
    fingerprint: getServerFingerprint(),
    ip: getLocalIp(),
    interfaces: filtered
  };
  return info;
}
