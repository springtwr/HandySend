import { deviceInfo } from '@kit.BasicServicesKit';
import { preferencesUtil } from '../../utils/PreferencesUtil';
import { generateAlias, getSystemDeviceName } from '../../utils/AliasGenerator';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { LocalDeviceInfo, NetworkInterface } from '../../model/Types';
import { getLocalInterfaces, getServerFingerprint } from './AppCore';
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
  // 白名单/黑名单存储接口名（如 wlan0,eth0），按接口名过滤：
  // 黑名单中的接口排除；白名单非空时只保留白名单中的接口。
  // 白名单为空时不保留任何接口（与 computeDiscoveryWhitelist 语义一致：
  // 白名单空 = 不扫描任何接口），避免子网扫描使用被排除的接口。
  let whitelistText = getNetworkWhitelist();
  let blacklistText = getNetworkBlacklist();
  let whitelistedNames: Array<string> = [];
  let blacklistedNames: Array<string> = [];
  if (whitelistText.length > 0) {
    let parts = whitelistText.split(',');
    for (let i = 0; i < parts.length; i++) {
      let trimmed = parts[i].trim();
      if (trimmed.length > 0) {
        whitelistedNames.push(trimmed);
      }
    }
  }
  if (blacklistText.length > 0) {
    let parts = blacklistText.split(',');
    for (let i = 0; i < parts.length; i++) {
      let trimmed = parts[i].trim();
      if (trimmed.length > 0) {
        blacklistedNames.push(trimmed);
      }
    }
  }
  let filtered: Array<NetworkInterface> = [];
  for (let i = 0; i < allInterfaces.length; i++) {
    let iface = allInterfaces[i];
    // 黑名单优先排除
    let isBlacklisted = false;
    for (let j = 0; j < blacklistedNames.length; j++) {
      if (blacklistedNames[j] === iface.name) {
        isBlacklisted = true;
        break;
      }
    }
    if (isBlacklisted) {
      continue;
    }
    // 白名单为空时不保留任何接口（与 computeDiscoveryWhitelist 语义一致）
    if (whitelistedNames.length > 0) {
      let isWhitelisted = false;
      for (let j = 0; j < whitelistedNames.length; j++) {
        if (whitelistedNames[j] === iface.name) {
          isWhitelisted = true;
          break;
        }
      }
      if (!isWhitelisted) {
        continue;
      }
    } else {
      // 白名单为空 → 不扫描任何接口
      continue;
    }
    filtered.push(iface);
  }

  // 从过滤后的接口列表中选取 IP：优先 WiFi，其次默认网络，最后第一个
  let primaryIp = '0.0.0.0';
  for (let i = 0; i < filtered.length; i++) {
    if (filtered[i].type === 'wifi') {
      primaryIp = filtered[i].ip;
      break;
    }
  }
  if (primaryIp === '0.0.0.0') {
    for (let i = 0; i < filtered.length; i++) {
      if (filtered[i].isDefault) {
        primaryIp = filtered[i].ip;
        break;
      }
    }
  }
  if (primaryIp === '0.0.0.0' && filtered.length > 0) {
    primaryIp = filtered[0].ip;
  }

  let info: LocalDeviceInfo = {
    alias: alias,
    fingerprint: getServerFingerprint(),
    ip: primaryIp,
    interfaces: filtered
  };
  logger.debug('[getLocalDeviceInfo] 全部: [' + allInterfaces.map((i: NetworkInterface) => i.name).join(', ') +
    '] 过滤后: [' + filtered.map((i: NetworkInterface) => i.name).join(', ') +
    '] primaryIp=' + primaryIp);
  return info;
}
