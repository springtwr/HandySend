import { getLogger, LogContext } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { DiscoveredDevice, DeviceChannel } from '../../model/Types';
import { NativeDiscoveredDevice, NativeDiscoveryUpdateEvent, NativeDeviceFoundEvent,
  NativeServerRegisterEvent, NativeRegisterInfo, NativeDeviceChannel, NativeRegisterResult } from '../../model/NativeTypes';
import { nativeDiscoveryDiscoverStaged, nativeDiscoveryScanSubnet,
  nativeDiscoveryGetDevice, nativeDiscoveryMulticastError,
  nativeDiscoveryAddDevice, nativeClientInfo, nativeRegisterDevice } from '../NativeBridge';
import { getFavorites, syncAliasFromDiscovery } from '../FavoritesService';
import { addLog, notifyChange, getLocalIp, getLocalInterfaces, getServerFingerprint } from './AppCore';
import { getHttpsEnabled, getPort } from './SettingsRepository';
import { getDeviceAlias, getDeviceModel, getDeviceType } from './DeviceRepository';

const logger = getLogger(LogDomains.DISCOVERY, 'HandySend:DiscoveryRepository');
const DEVICE_EXPIRY_MS = 120000;

// ── 已发现设备状态 ──

let discoveredDevices: Array<DiscoveredDevice> = [];

export function clearDiscoveryState(): void {
  discoveredDevices = [];
}

export function getDiscoveredDevices(): Array<DiscoveredDevice> {
  let now = Date.now();
  // 过滤掉过期设备（lastSeen 过旧）
  // 设备仅通过 handleDeviceFound 添加（真正的确认），
  // 因此 lastSeen 仅在设备真正响应时更新。
  let valid: Array<DiscoveredDevice> = [];
  let expired: Array<string> = [];
  for (let i = 0; i < discoveredDevices.length; i++) {
    let age = now - discoveredDevices[i].lastSeen;
    if (age < DEVICE_EXPIRY_MS) {
      valid.push(discoveredDevices[i]);
    } else {
      expired.push(discoveredDevices[i].alias + '(' + discoveredDevices[i].fingerprint.substring(0, 8) + ' age=' + age + 'ms)');
    }
  }
  if (expired.length > 0) {
    logger.info('[expired] ' + expired.join(', '));
  }
  discoveredDevices = valid;
  return discoveredDevices;
}

export function getMulticastError(): string {
  return nativeDiscoveryMulticastError();
}

export function getDeviceByFingerprint(fingerprint: string): DiscoveredDevice | undefined {
  return nativeDiscoveryGetDevice(fingerprint);
}

// ── 事件处理器（由 handleNativeEvent 路由） ──

// 处理单个设备发现事件（类似 LocalSend 的 RegisterDeviceAction）。
// Rust 只发送新发现/更新的设备，而非完整列表。
export function handleDeviceFound(event: NativeDeviceFoundEvent): void {
  let deviceObj: Record<string, Object> = event.device;
  let now = Date.now();

  // 解析设备字段
  let alias: string = (deviceObj['alias'] as string) || '';
  let fingerprint: string = (deviceObj['fingerprint'] as string) || '';
  let version: string = (deviceObj['version'] as string) || '';
  let deviceModel: string = (deviceObj['deviceModel'] as string) || '';
  let deviceType: string = (deviceObj['deviceType'] as string) || '';
  let download: boolean = (deviceObj['download'] as boolean) || false;
  let host: string = (deviceObj['host'] as string) || '';
  let devPort: number = (deviceObj['port'] as number) || 53317;
  let devProtocol: string = (deviceObj['protocol'] as string) || 'http';

  // 解析通道
  let channels: Array<DeviceChannel> = [];
  let channelsRaw: Object[] | undefined = deviceObj['channels'] as Object[] | undefined;
  if (channelsRaw !== undefined) {
    for (let j = 0; j < channelsRaw.length; j++) {
      let ch: Record<string, Object> = channelsRaw[j] as Record<string, Object>;
      channels.push({
        host: (ch['host'] as string) || '',
        port: (ch['port'] as number) || 53317,
        protocol: (ch['protocol'] as string) || 'http'
      });
    }
  }

  // 查找已有设备
  let existingDevice: DiscoveredDevice | undefined = undefined;
  for (let k = 0; k < discoveredDevices.length; k++) {
    if (discoveredDevices[k].fingerprint === fingerprint) {
      existingDevice = discoveredDevices[k];
      break;
    }
  }

  // 若已有设备使用 HTTPS 则保留
  if (existingDevice !== undefined && existingDevice.protocol === 'https' && devProtocol !== 'https') {
    devProtocol = 'https';
  }

  let updatedDevice: DiscoveredDevice = {
    alias: alias,
    ip: host,
    port: devPort,
    fingerprint: fingerprint,
    version: version,
    deviceModel: deviceModel,
    deviceType: deviceType,
    protocol: devProtocol,
    lastSeen: now,
    channels: channels,
    publicKey: existingDevice !== undefined ? existingDevice.publicKey : undefined
  };

  // 替换已有条目或追加新条目
  if (existingDevice !== undefined) {
    for (let k = 0; k < discoveredDevices.length; k++) {
      if (discoveredDevices[k].fingerprint === fingerprint) {
        discoveredDevices[k] = updatedDevice;
        break;
      }
    }
  } else {
    discoveredDevices.push(updatedDevice);
  }

  if (fingerprint.length > 0) {
    syncAliasFromDiscovery(fingerprint, alias);
  }

  notifyChange();
}

export function handleDiscoveryUpdate(event: NativeDiscoveryUpdateEvent): void {
  let devicesArray: Array<NativeDiscoveredDevice> = event.devices;
  let now = Date.now();
  // 从事件更新/新增设备
  for (let i = 0; i < devicesArray.length; i++) {
    let d: NativeDiscoveredDevice = devicesArray[i];
    let channels: Array<DeviceChannel> = [];
    if (d.channels !== undefined) {
      for (let j = 0; j < d.channels.length; j++) {
        let ch: NativeDeviceChannel = d.channels[j];
        channels.push({
          host: ch.host,
          port: ch.port,
          protocol: ch.protocol
        });
      }
    }
    let host: string = d.host;
    let devPort: number = d.port;
    let devProtocol: string = d.protocol;
    let fingerprint: string = d.fingerprint;
    let alias: string = d.alias;
    let version: string = d.version;
    let deviceModel: string = d.deviceModel;
    let deviceType: string = d.deviceType;

    let existingDevice: DiscoveredDevice | undefined = undefined;
    for (let k = 0; k < discoveredDevices.length; k++) {
      if (discoveredDevices[k].fingerprint === fingerprint) {
        existingDevice = discoveredDevices[k];
        break;
      }
    }

    // 设备已确认存在——将 lastSeen 更新为当前时间
    let lastSeen: number = now;

    // 若已有设备使用 HTTPS 则保留
    if (existingDevice !== undefined && existingDevice.protocol === 'https' && devProtocol !== 'https') {
      devProtocol = 'https';
    }

    let updatedDevice: DiscoveredDevice = {
      alias: alias,
      ip: host,
      port: devPort,
      fingerprint: fingerprint,
      version: version,
      deviceModel: deviceModel,
      deviceType: deviceType,
      protocol: devProtocol,
      lastSeen: lastSeen,
      channels: channels,
      publicKey: existingDevice !== undefined ? existingDevice.publicKey : undefined
    };

    // 替换已有条目或追加新条目
    if (existingDevice !== undefined) {
      for (let k = 0; k < discoveredDevices.length; k++) {
        if (discoveredDevices[k].fingerprint === fingerprint) {
          discoveredDevices[k] = updatedDevice;
          break;
        }
      }
    } else {
      discoveredDevices.push(updatedDevice);
    }

    if (fingerprint.length > 0) {
      syncAliasFromDiscovery(fingerprint, alias);
    }
  }
  // 不在此事件中的设备保持原有状态（包括 lastSeen）；
  // 当 lastSeen 过旧时，它们会通过 getDiscoveredDevices() 自然过期。
  notifyChange();
}

export function handleRegisterEventTyped(event: NativeServerRegisterEvent): void {
  let ip: string = event.ip;
  let info: NativeRegisterInfo = event.info;
  let deviceType: string = info.deviceType !== undefined ? info.deviceType : 'mobile';
  let fingerprint: string = info.fingerprint;
  let port: number = info.port;

  let nativeDevice: NativeDiscoveredDevice = {
    alias: info.alias,
    fingerprint: fingerprint,
    version: info.version,
    deviceModel: info.deviceModel !== undefined ? info.deviceModel : '',
    deviceType: deviceType,
    download: info.download,
    host: ip,
    port: port,
    // 使用远程设备的实际协议（来自其注册负载），
    // 而非本地服务器的设置。
    protocol: (info.protocol !== undefined && info.protocol !== null && info.protocol.length > 0) ?
      info.protocol : (getHttpsEnabled() ? 'https' : 'http'),
    channels: []
  };
  nativeDiscoveryAddDevice(nativeDevice).catch((e: Error) => {
    addLog('warn', 'Failed to add register device to discovery: ' + e.message);
  });
}

// ── 扫描 / 重新扫描 ──

// 辅助：使用当前配置 + 收藏设备触发分阶段发现
// 不包含子网扫描，以避免重复的 DISCOVER/REGISTER 消息
// 与 announce() 同时调用时。如需子网扫描请单独调用 scanSubnets()。
export function triggerStagedDiscover(): void {
  let favDevices = getFavorites();
  let channels: Array<NativeDeviceChannel> = [];
  let protocol = getHttpsEnabled() ? 'https' : 'http';
  let altProtocol = getHttpsEnabled() ? 'http' : 'https';
  for (let i = 0; i < favDevices.length; i++) {
    // 用两种协议探测收藏设备，以便找到使用不同加密模式的设备
    channels.push({
      host: favDevices[i].ip,
      port: favDevices[i].port,
      protocol: protocol
    });
    channels.push({
      host: favDevices[i].ip,
      port: favDevices[i].port,
      protocol: altProtocol
    });
  }
  let interfaceIps: Array<string> = [];
  let interfaces = getLocalInterfaces();
  for (let i = 0; i < interfaces.length; i++) {
    if (interfaces[i].ip !== '0.0.0.0') {
      interfaceIps.push(interfaces[i].ip);
    }
  }
  nativeDiscoveryDiscoverStaged(channels, interfaceIps, getPort(), protocol, 2000).then(() => {
    // 使用备用协议扫描，以发现使用不同加密模式的设备
    for (let i = 0; i < interfaceIps.length; i++) {
      nativeDiscoveryScanSubnet(interfaceIps[i], getPort(), altProtocol).catch((e: Error) => {
        logger.info('[alt-protocol scan] ' + altProtocol + ' scan for ' + interfaceIps[i] + ' failed: ' + e.message);
      });
    }
  }).catch((e: Error) => {
    addLog('warn', 'Staged discover failed: ' + e.message);
    // 即使主发现失败，仍尝试备用协议扫描
    for (let i = 0; i < interfaceIps.length; i++) {
      nativeDiscoveryScanSubnet(interfaceIps[i], getPort(), altProtocol).catch((_e: Error) => {
        // 忽略备用协议扫描失败
      });
    }
  });
}

// 辅助：扫描子网发现新设备（不与 announce 合并以避免重复）

export function rescanDevices(announce: boolean = true): void {
  let serverFingerprint: string = getServerFingerprint();
  if (serverFingerprint.length > 0) {
    // 匹配 LocalSend Flutter 的 StartSmartScan：
    // 1. 先清空设备列表（避免过期设备残留）
    // 2. 调用 discover_staged（内部包含 announce + 收藏设备探测 + 条件子网扫描）
    discoveredDevices = [];
    if (announce) {
      // discover_staged 内部已包含 announce，
      // 因此直接调用 triggerStagedDiscover——它等价于 StartSmartScan
      triggerStagedDiscover();
    } else {
      // 不广播（例如服务器重启），仅探测已知地址
      triggerStagedDiscover();
    }
    notifyChange();
  }
}

// ── 手动 IP 连接 ──

export async function connectByIp(targetIp: string, targetPort: number): Promise<DiscoveredDevice | undefined> {
  let protocol = getHttpsEnabled() ? 'https' : 'http';
  try {
    let resultStr = await nativeClientInfo(protocol, targetIp, targetPort);
    let data: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
    let deviceTypeRaw: Object | undefined = data['deviceType'];
    let deviceType: string = 'mobile';
    if (deviceTypeRaw !== undefined && deviceTypeRaw !== null) {
      deviceType = deviceTypeRaw as string;
    }
    let fingerprint: string = data['fingerprint'] !== undefined ? data['fingerprint'] as string : '';
    let dev: DiscoveredDevice = {
      alias: data['alias'] !== undefined ? data['alias'] as string : '',
      ip: targetIp,
      port: targetPort,
      fingerprint: fingerprint,
      version: data['version'] !== undefined ? data['version'] as string : '',
      deviceModel: data['deviceModel'] !== undefined ? data['deviceModel'] as string : '',
      deviceType: deviceType,
      protocol: data['protocol'] !== undefined ? data['protocol'] as string : protocol,
      lastSeen: Date.now(),
      channels: [{ host: targetIp, port: targetPort, protocol: protocol }]
    };
    let nativeDev: NativeDiscoveredDevice = {
      alias: dev.alias,
      fingerprint: dev.fingerprint,
      version: dev.version,
      deviceModel: dev.deviceModel,
      deviceType: dev.deviceType,
      download: data['download'] !== undefined ? data['download'] as boolean : false,
      host: targetIp,
      port: targetPort,
      protocol: dev.protocol,
      channels: [{ host: targetIp, port: targetPort, protocol: protocol }]
    };
    nativeDiscoveryAddDevice(nativeDev).catch((_e: Error) => {});
    return dev;
  } catch (e) {
    addLog('warn', 'Connect by IP failed: ' + e);
    return undefined;
  }
}

export async function registerToRemoteDevice(targetIp: string,
  targetPort: number): Promise<NativeRegisterResult | undefined> {
  let protocol = getHttpsEnabled() ? 'https' : 'http';
  try {
    let result = await nativeRegisterDevice(
      targetIp, targetPort,
      getDeviceAlias(), getServerFingerprint(), protocol,
      getDeviceModel(), getDeviceType(), getPort(),
      getLocalIp()
    );
    let nativeDev: NativeDiscoveredDevice = {
      alias: result.alias,
      fingerprint: result.fingerprint,
      version: result.version,
      deviceModel: result.deviceModel,
      deviceType: result.deviceType,
      download: false,
      host: targetIp,
      port: targetPort,
      protocol: result.protocol,
      channels: [{ host: targetIp, port: targetPort, protocol: protocol }]
    };
    nativeDiscoveryAddDevice(nativeDev).catch((_e: Error) => {});
    if (result.publicKey.length > 0 && result.fingerprint.length > 0) {
      for (let i = 0; i < discoveredDevices.length; i++) {
        if (discoveredDevices[i].fingerprint === result.fingerprint) {
          discoveredDevices[i].publicKey = result.publicKey;
          break;
        }
      }
    }
    return result;
  } catch (e) {
    addLog('warn', 'Register to remote failed: ' + e);
    return undefined;
  }
}
