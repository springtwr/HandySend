import { deviceInfo } from '@kit.BasicServicesKit';
import { preferencesRepo } from './PreferencesRepo';
import { generateAlias, getSystemDeviceName } from '../../utils/AliasGenerator';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { LocalDeviceInfo, NetworkInterface } from '../../model/Types';
import { getLocalInterfaces, getServerFingerprint, notifyChange } from './AppCore';
import { getNetworkListAsArray, markServerNeedsRestart } from './SettingsRepository';
import { KEY_NETWORK_WHITELIST, KEY_NETWORK_BLACKLIST } from '../../utils/PreferencesUtil';
import { isInterfaceEnabled } from '../../utils/NetworkInterfaceRules';

const logger = getLogger(LogDomains.DISCOVERY, 'HandySend:DeviceRepository', '设备');

// ── 设备身份状态 ──

let alias = '';
let deviceModel = '';
let deviceType = 'mobile';
// 上一次打印的网卡过滤结果签名：仅在结果变化时输出，避免稳态高频调用刷屏
let lastLoggedInterfaceSignature = '';

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
  let customAlias = preferencesRepo.getCustomAlias();

  let newAlias = customAlias || getSystemDeviceName();
  // 设备类型只取系统检测结果，不提供用户自定义
  let newDeviceType = getSystemDeviceType();
  let newDeviceModel = deviceInfo.productModel;

  // 仅当设备身份实际变化时才标记服务器重启
  if (newAlias !== alias || newDeviceType !== deviceType || newDeviceModel !== deviceModel) {
    alias = newAlias;
    deviceType = newDeviceType;
    deviceModel = newDeviceModel;
    markServerNeedsRestart();
    // 通知 UI 刷新，让重启横幅立即显示（与 SettingsRepository 各 setter 的模式一致）
    notifyChange();
  }
}

export function initDeviceIdentity(): void {
  // 直接初始化设备身份（不经 refreshDeviceInfo，因为它会
  // 会误将模块级默认值 '' 到真实值的切换检测为"变化"）
  let customAlias = preferencesRepo.getCustomAlias();

  // 首次启动时自动生成随机昵称
  if (customAlias === '') {
    customAlias = generateAlias();
    preferencesRepo.setCustomAlias(customAlias);
  }

  alias = customAlias;
  deviceType = getSystemDeviceType();
  deviceModel = deviceInfo.productModel;
}

export function getLocalDeviceInfo(): LocalDeviceInfo {
  let allInterfaces = getLocalInterfaces();
  // 白名单/黑名单存储接口名（如 wlan0,eth0），按接口名决定启用状态：
  // 黑名单优先排除；白名单放行；两者都未列出的接口按类型取默认（WiFi/以太网放行）。
  // 判定规则见 utils/NetworkInterfaceRules，与网络接口弹窗的开关、发现网段计算同源。
  let whitelistedNames = getNetworkListAsArray(KEY_NETWORK_WHITELIST);
  let blacklistedNames = getNetworkListAsArray(KEY_NETWORK_BLACKLIST);
  if (whitelistedNames === undefined) {
    whitelistedNames = [];
  }
  if (blacklistedNames === undefined) {
    blacklistedNames = [];
  }
  let filtered: Array<NetworkInterface> = [];
  for (let i = 0; i < allInterfaces.length; i++) {
    let iface = allInterfaces[i];
    if (!isInterfaceEnabled(iface.name, iface.type, whitelistedNames, blacklistedNames)) {
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
  let allNames = allInterfaces.map((i: NetworkInterface) => i.name).join(', ');
  let filteredNames = filtered.map((i: NetworkInterface) => i.name).join(', ');
  let signature = allNames + '|' + filteredNames + '|' + primaryIp;
  if (signature !== lastLoggedInterfaceSignature) {
    lastLoggedInterfaceSignature = signature;
    logger.debug('全部: [' + allNames +
      '] 过滤后: [' + filteredNames +
      '] primaryIp=' + primaryIp);
  }
  return info;
}
