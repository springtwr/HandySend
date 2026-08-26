import { getLogger, LogContext } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { DiscoveredDevice, DeviceChannel } from '../../model/Types';
import {
  NativeDiscoveredDevice,
  NativeDiscoveryUpdateEvent,
  NativeDeviceFoundEvent,
  NativeServerRegisterEvent,
  NativeRegisterInfo,
  NativeDeviceChannel,
  NativeRegisterResult
} from '../../model/NativeTypes';
import {
  nativeDiscoveryDiscoverStaged,
  nativeDiscoveryScanSubnet,
  nativeDiscoveryGetDevice,
  nativeDiscoveryMulticastError,
  nativeDiscoveryAddDevice,
  nativeClientInfo,
  nativeRegisterDevice,
  nativePollDebugLog
} from '../NativeBridge';
import { getFavorites, syncFavoriteFromDiscovery } from '../FavoritesService';
import { addLog, notifyChange, getServerFingerprint } from './AppCore';
import { getHttpsEnabled, getPort } from './SettingsRepository';
import { getDeviceAlias, getDeviceModel, getDeviceType, getLocalDeviceInfo } from './DeviceRepository';

const logger = getLogger(LogDomains.DISCOVERY, 'HandySend:DiscoveryRepository');

// ── 已发现设备状态 ──

let discoveredDevices: Array<DiscoveredDevice> = [];
let scanStartTime: number = 0; // 本次扫描的起始时间戳（离线判定基准 + debug 日志）
let isScanning: boolean = false; // 是否正在扫描（防并发）
let pendingRescan: boolean = false; // 扫描中收到新刷新请求的待补扫标志（合并排队，最多补扫一次）

export function clearDiscoveryState(): void {
  discoveredDevices = [];
}

// 重置扫描状态：discovery 被 stop 后旧的 discover_staged promise 会失效，
// 不会再走到 finishScan()，需手动清理以避免遗留的 isScanning/pendingRescan
// 干扰后续 triggerStagedDiscover()。
export function resetScanState(): void {
  isScanning = false;
  pendingRescan = false;
  scanStartTime = 0;
}

export function getDiscoveredDevices(): Array<DiscoveredDevice> {
  // 离线设备的移除由刷新确认窗口负责（removeUnconfirmedDevices），此处不做 TTL 过期过滤
  return discoveredDevices;
}

export function getMulticastError(): string {
  return nativeDiscoveryMulticastError();
}

export function getDeviceByFingerprint(fingerprint: string): DiscoveredDevice | undefined {
  return nativeDiscoveryGetDevice(fingerprint);
}

// ── 设备响应监听（发现调试页使用） ──
// 对端回应广播/探测后，Rust 发出 device_found 事件，handleDeviceFound 在此通知监听者。
// 所有回应路径（组播 register、子网扫描、收藏探测）都汇聚到 device_found，此处不会重复计数。

// 对端设备响应信息
export interface DeviceResponseInfo {
  isNew: boolean
  alias: string
  ip: string
  port: number
  protocol: string
}

type DeviceResponseListener = (info: DeviceResponseInfo) => void;

let deviceResponseListeners: Array<DeviceResponseListener> = [];

export function subscribeDeviceResponses(listener: DeviceResponseListener): void {
  deviceResponseListeners.push(listener);
}

export function unsubscribeDeviceResponses(listener: DeviceResponseListener): void {
  let idx = deviceResponseListeners.indexOf(listener);
  if (idx >= 0) {
    deviceResponseListeners.splice(idx, 1);
  }
}

function notifyDeviceResponse(info: DeviceResponseInfo): void {
  for (let i = 0; i < deviceResponseListeners.length; i++) {
    deviceResponseListeners[i](info);
  }
}

// ── 事件处理器（由 handleNativeEvent 路由） ──

// 统一设备合并函数：将设备信息合并到 discoveredDevices 列表中。
// 若已有设备使用 HTTPS 则保留；替换已有条目或追加新条目；同步别名。
function mergeDeviceIntoList(device: DiscoveredDevice): void {
  let fingerprint: string = device.fingerprint;
  let existingDevice: DiscoveredDevice | undefined = undefined;
  for (let k = 0; k < discoveredDevices.length; k++) {
    if (discoveredDevices[k].fingerprint === fingerprint) {
      existingDevice = discoveredDevices[k];
      break;
    }
  }

  // 若已有设备使用 HTTPS 则保留
  let devProtocol: string = device.protocol;
  if (existingDevice !== undefined && existingDevice.protocol === 'https' && devProtocol !== 'https') {
    devProtocol = 'https';
  }

  let updatedDevice: DiscoveredDevice = {
    alias: device.alias,
    ip: device.ip,
    port: device.port,
    fingerprint: fingerprint,
    version: device.version,
    deviceModel: device.deviceModel,
    deviceType: device.deviceType,
    protocol: devProtocol,
    lastSeen: device.lastSeen,
    channels: device.channels,
    publicKey: existingDevice !== undefined ? existingDevice.publicKey : device.publicKey
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
    syncFavoriteFromDiscovery(fingerprint, device.alias, device.protocol);
  }
}

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
  let host: string = (deviceObj['host'] as string) || '';
  let devPort: number = (deviceObj['port'] as number) || 53317;
  let devProtocol: string = (deviceObj['protocol'] as string) || 'http';

  logger.debug('[device_found] 收到事件: alias=' + alias + ' fp=' + fingerprint.substring(0, 8) +
    ' host=' + host + ':' + devPort + ' protocol=' + devProtocol +
    ' now=' + now + ' scanStartTime=' + scanStartTime +
    ' isScanning=' + isScanning + ' listSize=' + discoveredDevices.length);

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

  let device: DiscoveredDevice = {
    alias: alias,
    ip: host,
    port: devPort,
    fingerprint: fingerprint,
    version: version,
    deviceModel: deviceModel,
    deviceType: deviceType,
    protocol: devProtocol,
    lastSeen: now,
    channels: channels
  };

  // 判断是否新设备（merge 前快照）
  let isNew: boolean = true;
  for (let k = 0; k < discoveredDevices.length; k++) {
    if (discoveredDevices[k].fingerprint === fingerprint) {
      isNew = false;
      break;
    }
  }

  mergeDeviceIntoList(device);
  notifyDeviceResponse({
    isNew: isNew,
    alias: alias,
    ip: host,
    port: devPort,
    protocol: devProtocol
  });
  let sinceScan = isScanning ? (now - scanStartTime) : -1;
  logger.debug('[device_found] 合并完成: alias=' + alias + ' fp=' + fingerprint.substring(0, 8) +
    ' host=' + host + ':' + devPort + ' protocol=' + devProtocol +
    ' lastSeen=' + now + ' 距扫描开始=' + sinceScan + 'ms' +
    ' isScanning=' + isScanning + ' listSize=' + discoveredDevices.length);
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

    let device: DiscoveredDevice = {
      alias: d.alias,
      ip: d.host,
      port: d.port,
      fingerprint: d.fingerprint,
      version: d.version,
      deviceModel: d.deviceModel,
      deviceType: d.deviceType,
      protocol: d.protocol,
      lastSeen: now,
      channels: channels
    };

    mergeDeviceIntoList(device);
  }
  // 不在此事件中的设备保持原有状态（包括 lastSeen）；
  // 离线设备的移除由刷新确认窗口负责（removeUnconfirmedDevices），此事件不做移除。
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
  // 本地合并：register 路径感知到的设备必须同步合入 ArkTS discoveredDevices 列表
  // （UI 数据源）并通知刷新，否则仅写入 Rust store 时该设备在界面上不可见。
  // protocol 直接复用 nativeDevice 已按既有口径算好的值
  // （info.protocol 有效则用之，否则 getHttpsEnabled() ? 'https' : 'http'）。
  let device: DiscoveredDevice = {
    alias: info.alias,
    ip: ip,
    port: port,
    fingerprint: fingerprint,
    version: info.version,
    deviceModel: info.deviceModel !== undefined ? info.deviceModel : '',
    deviceType: deviceType,
    protocol: nativeDevice.protocol,
    lastSeen: Date.now(),
    channels: []
  };
  mergeDeviceIntoList(device);
  notifyChange();

  nativeDiscoveryAddDevice(nativeDevice).catch((e: Error) => {
    addLog('warn', 'Failed to add register device to discovery: ' + e.message);
  });
}

// ── 扫描 / 重新扫描 ──

// 防并发/排队外壳：扫描进行中时合并排队（最多补扫一次），不静默丢弃刷新请求
export function triggerStagedDiscover(): void {
  if (isScanning) {
    logger.debug('[scan] 扫描进行中（scanStartTime=' + scanStartTime + '），合并排队等待补扫');
    pendingRescan = true;
    return;
  }
  runStagedDiscover();
}

// 扫描主体：向已知设备发送确认请求 + 组播广播发现新设备，
// 3 秒确认窗口结束后移除未确认（离线）设备。
function runStagedDiscover(): void {
  isScanning = true;
  // 记录本次扫描发起时刻，作为离线判定基准（handleDeviceFound 必然更新 lastSeen ≥ scanStartTime）
  scanStartTime = Date.now();
  logger.debug('[scan] 开始 scanStartTime=' + scanStartTime + ' 已知设备=' + discoveredDevices.length +
    ' 收藏=' + getFavorites().length);

  let favDevices = getFavorites();
  let channels: Array<NativeDeviceChannel> = [];
  let protocol = getHttpsEnabled() ? 'https' : 'http';
  let altProtocol = getHttpsEnabled() ? 'http' : 'https';
  // 按 host:port:protocol 去重（收藏设备与已知设备快照可能重叠）
  let seenKeys: Set<string> = new Set<string>();
  for (let i = 0; i < favDevices.length; i++) {
    // 收藏设备探测：若 lastProtocol 存在则仅推送该协议 channel，否则双协议
    if (favDevices[i].lastProtocol !== undefined && favDevices[i].lastProtocol !== null &&
      favDevices[i].lastProtocol!.length > 0) {
      let key = favDevices[i].ip + ':' + favDevices[i].port + ':' + favDevices[i].lastProtocol!;
      if (!seenKeys.has(key)) {
        seenKeys.add(key);
        channels.push({
          host: favDevices[i].ip,
          port: favDevices[i].port,
          protocol: favDevices[i].lastProtocol!
        });
      }
    } else {
      let keyPrimary = favDevices[i].ip + ':' + favDevices[i].port + ':' + protocol;
      if (!seenKeys.has(keyPrimary)) {
        seenKeys.add(keyPrimary);
        channels.push({
          host: favDevices[i].ip,
          port: favDevices[i].port,
          protocol: protocol
        });
      }
      let keyAlt = favDevices[i].ip + ':' + favDevices[i].port + ':' + altProtocol;
      if (!seenKeys.has(keyAlt)) {
        seenKeys.add(keyAlt);
        channels.push({
          host: favDevices[i].ip,
          port: favDevices[i].port,
          protocol: altProtocol
        });
      }
    }
  }
  // 追加当前已知设备快照：按记录协议 + 备用协议双通道探测（提高确认成功率）。
  // 记录协议可能不准（如 announce 回应记录为 http 而设备实际仅支持 https），
  // 双协议探测避免"probe 失败 → 确认窗口误判离线移除"。
  for (let i = 0; i < discoveredDevices.length; i++) {
    let dev = discoveredDevices[i];
    let key = dev.ip + ':' + dev.port + ':' + dev.protocol;
    if (!seenKeys.has(key)) {
      seenKeys.add(key);
      channels.push({
        host: dev.ip,
        port: dev.port,
        protocol: dev.protocol
      });
    }
    // 备用协议通道（与记录协议不同才追加）
    if (dev.protocol !== altProtocol) {
      let altKey = dev.ip + ':' + dev.port + ':' + altProtocol;
      if (!seenKeys.has(altKey)) {
        seenKeys.add(altKey);
        channels.push({
          host: dev.ip,
          port: dev.port,
          protocol: altProtocol
        });
      }
    }
  }
  // 子网扫描兜底：组播不可靠时（AP 禁组播/WiFi 隔离）通过 HTTP 探测 /24 子网发现设备。
  // discover_staged 仅在 3 秒确认窗口内无任何确认时才触发子网扫描，
  // 组播正常时（有设备回应）不扫描，刷新速度不受影响。
  // 白名单/黑名单存储接口名（如 wlan0,eth0），按接口名过滤后取允许的接口 IP 做子网扫描
  let interfaceIps: Array<string> = [];
  let localInfo = getLocalDeviceInfo();
  for (let i = 0; i < localInfo.interfaces.length; i++) {
    let iface = localInfo.interfaces[i];
    if (iface.ip !== '0.0.0.0') {
      interfaceIps.push(iface.ip);
    }
  }
  let port = getPort();
  // 确认窗口 3 秒：探测完成后的确认收集期
  let graceMs = 3000;

  logger.debug('[staged] probe channels=' + channels.length + ': [' +
    channels.map((c) => c.host + ':' + c.port + ':' + c.protocol).join(', ') + ']' +
    ' interfaceIps=' + JSON.stringify(interfaceIps) + ' protocol=' + protocol +
    ' graceMs=' + graceMs + ' altProtocol=' + altProtocol);

  let t0 = Date.now();
  flushRustLogs();
  nativeDiscoveryDiscoverStaged(channels, interfaceIps, port, protocol, graceMs).then(async () => {
    let elapsed = Date.now() - t0;
    flushRustLogs();
    logger.debug('[scan] discover_staged 完成，耗时=' + elapsed + 'ms（含 announce+probe+grace+子网扫描）' +
      ' 此时列表=' + discoveredDevices.length + ' 台');
    // 备用协议子网扫描兜底：主协议（如 http）无法探测仅支持另一种协议的设备
    // （标准 LocalSend 默认 https，HandySend 用 http 时子网扫描探测不到 https-only 设备）。
    // 仅当主协议扫描未确认任何新设备时执行，避免无条件双倍扫描。
    if (!hasConfirmedSince(scanStartTime)) {
      logger.debug('[scan] 主协议无新确认，备用协议子网扫描兜底: ' + altProtocol);
      for (let i = 0; i < interfaceIps.length; i++) {
        try {
          await nativeDiscoveryScanSubnet(interfaceIps[i], port, altProtocol);
        } catch (e) {
          logger.warn('[scan] 备用协议子网扫描失败 ' + interfaceIps[i] + ': ' + (e as Error).message);
        }
      }
      flushRustLogs();
    }
    // 确认窗口结束：移除本次未确认的离线设备
    removeUnconfirmedDevices(scanStartTime);
    finishScan();
  }).catch((e: Error) => {
    let elapsed = Date.now() - t0;
    flushRustLogs();
    logger.warn('[scan] discover_staged 失败（耗时=' + elapsed + 'ms）: ' + e.message);
    // 扫描失败/网络异常：保持设备列表不变（不清空），仅记录日志
    addLog('warn', 'Staged discover failed: ' + e.message);
    finishScan();
  });
}

// 自 scanStartTime 以来是否有设备被确认（lastSeen >= scanStartTime）
function hasConfirmedSince(scanStartTime: number): boolean {
  for (let i = 0; i < discoveredDevices.length; i++) {
    if (discoveredDevices[i].lastSeen >= scanStartTime) {
      return true;
    }
  }
  return false;
}

// 扫描收尾（then/catch 共用）：复位扫描状态；若期间收到排队请求则补扫一次
function finishScan(): void {
  isScanning = false;
  if (pendingRescan) {
    pendingRescan = false;
    logger.debug('[scan] 消费排队请求，立即补扫一次（列表=' + discoveredDevices.length + ' 台）');
    runStagedDiscover();
  } else {
    logger.debug('[scan] 收尾完成（无排队），列表=' + discoveredDevices.length + ' 台');
  }
  notifyChange();
}

// 确认窗口结束：移除 lastSeen < scanStartTime 的未确认设备并记录日志
function removeUnconfirmedDevices(scanStartTime: number): void {
  let confirmed: Array<DiscoveredDevice> = [];
  let removed: Array<string> = [];
  for (let i = 0; i < discoveredDevices.length; i++) {
    let dev = discoveredDevices[i];
    if (dev.lastSeen >= scanStartTime) {
      confirmed.push(dev);
    } else {
      let age = Date.now() - dev.lastSeen;
      removed.push(dev.alias + '(fp=' + dev.fingerprint.substring(0, 8) + ' age=' + age + 'ms)');
    }
  }
  if (removed.length > 0) {
    logger.debug('[remove_unconfirmed] 移除 ' + removed.length + ' 台未确认（离线）设备: [' + removed.join(', ') + ']');
  }
  discoveredDevices = confirmed;
}

// 当前是否正在扫描（供 UI 显示扫描中状态）
export function isScanningStatus(): boolean {
  return isScanning;
}

// 轮询 Rust 侧日志缓冲并输出到 hilog（Rust 的 log crate 经缓冲转发到这里）
function flushRustLogs(): void {
  try {
    let rustLogs: Array<string> = nativePollDebugLog();
    for (let i = 0; i < rustLogs.length; i++) {
      logger.debug('[rust] ' + rustLogs[i]);
    }
  } catch (_e) {
  }
}

// 触发一次完整扫描流程（scanStartTime 与离线移除由 runStagedDiscover 内部处理）
export function rescanDevices(): void {
  let serverFingerprint: string = getServerFingerprint();
  if (serverFingerprint.length > 0) {
    logger.debug('[scan] rescanDevices 被调用（isScanning=' + isScanning + '）');
    triggerStagedDiscover();
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
    nativeDiscoveryAddDevice(nativeDev).catch((_e: Error) => {
    });
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
      getLocalDeviceInfo().ip
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
    nativeDiscoveryAddDevice(nativeDev).catch((_e: Error) => {
    });
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
