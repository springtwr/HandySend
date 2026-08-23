import { fileIo as fs } from '@kit.CoreFileKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { NetworkInterface, NetworkType } from '../../model/Types';
import { NativeServerHandle, NativeDiscoveryConfig } from '../../model/NativeTypes';
import {
  nativeCreateServer,
  nativeStopServer,
  nativeGetServerStatus,
  nativeStartDiscoveryV2,
  nativeDiscoverySetAnswerAnnouncements,
  nativeDiscoveryStop
} from '../NativeBridge';
import {
  getAppContext,
  addLog,
  notifyChange,
  updateLocalInterfaces,
  getLocalInterfaces,
  getServerFingerprint as getServerFingerprintValue,
  setServerFingerprint
} from './AppCore';
import {
  getHttpsEnabled,
  getPort,
  getReceivePin,
  getMulticastGroup,
  getDiscoveryTimeout,
  getNetworkListAsArray,
  clearServerNeedsRestart,
  isVerifyChecksums
} from './SettingsRepository';
import { KEY_NETWORK_WHITELIST, KEY_NETWORK_BLACKLIST } from '../../utils/PreferencesUtil';
import { getDeviceAlias, getDeviceModel, getDeviceType, getLocalDeviceInfo } from './DeviceRepository';
import { triggerStagedDiscover, clearDiscoveryState } from './DiscoveryRepository';
import { getShareLink, stopShareLink } from './WebShareRepository';

const logger = getLogger(LogDomains.SERVER, 'HandySend:ServerRepository');

// 网络黑名单解析：读取用户配置的黑名单接口名（如 wlan0,ancowlan0），
// 对匹配接口名的本地接口生成精确 IP 列表，传给 Rust 层 InterfaceFilter。
// 无黑名单配置时返回 undefined（Rust 层不排除）。
function resolveNetworkBlacklist(): Array<string> | undefined {
  let blacklistedNames = getNetworkListAsArray(KEY_NETWORK_BLACKLIST);
  if (blacklistedNames === undefined || blacklistedNames.length === 0) {
    return undefined;
  }
  let result: Array<string> = [];
  let interfaces = getLocalInterfaces();
  for (let i = 0; i < interfaces.length; i++) {
    let iface = interfaces[i];
    if (iface.ip === '0.0.0.0') {
      continue;
    }
    for (let j = 0; j < blacklistedNames.length; j++) {
      if (blacklistedNames[j] === iface.name) {
        result.push(iface.ip);
        break;
      }
    }
  }
  if (result.length > 0) {
    logger.debug('[blacklist] 黑名单: [' + blacklistedNames.join(', ') + '] -> IP 列表: [' + result.join(', ') + ']');
    return result;
  }
  return undefined;
}

// 根据接口 IP 与前缀长度生成网段通配（IPv4 点分 4 段）：
// prefixLength >= 24 生成 a.b.c.*，否则生成 a.b.*（宁多勿漏，保证包含当前接口 IP）；
// ip 不足 4 段时返回空串。
function subnetPattern(ip: string, prefixLength: number): string {
  let parts = ip.split('.');
  if (parts.length < 4) {
    return '';
  }
  if (prefixLength >= 24) {
    return parts[0] + '.' + parts[1] + '.' + parts[2] + '.*';
  }
  return parts[0] + '.' + parts[1] + '.*';
}

// 计算 discovery 网络白名单：
// 用户白名单存储接口名（如 wlan0,eth0），将匹配接口名的接口映射为网段通配，
// 使 Rust 只在这些局域网接口上绑定组播 socket。
// 白名单为空时不扫描任何接口（返回 undefined）；黑名单接口始终排除。
function computeDiscoveryWhitelist(): Array<string> | undefined {
  let whitelistedNames = getNetworkListAsArray(KEY_NETWORK_WHITELIST);
  let blacklistedNames = getNetworkListAsArray(KEY_NETWORK_BLACKLIST);
  // 白名单为空 → 不扫描任何接口
  if (whitelistedNames === undefined || whitelistedNames.length === 0) {
    logger.debug('[whitelist] 白名单为空，不扫描任何接口');
    return undefined;
  }
  let result: Array<string> = [];
  let interfaces = getLocalInterfaces();
  let detail: Array<string> = [];
  for (let i = 0; i < interfaces.length; i++) {
    let iface = interfaces[i];
    detail.push(iface.name + '(' + iface.ip + '/' + iface.prefixLength + ', ' + iface.type + ')');

    // 黑名单接口优先排除（即使同时出现在白名单中）
    let isBlacklisted = false;
    if (blacklistedNames !== undefined) {
      for (let j = 0; j < blacklistedNames.length; j++) {
        if (blacklistedNames[j] === iface.name) {
          isBlacklisted = true;
          break;
        }
      }
    }
    if (isBlacklisted) {
      continue;
    }

    // 按白名单接口名匹配
    let shouldInclude = false;
    for (let j = 0; j < whitelistedNames.length; j++) {
      if (whitelistedNames[j] === iface.name) {
        shouldInclude = true;
        break;
      }
    }
    if (!shouldInclude) {
      continue;
    }
    let pattern = subnetPattern(iface.ip, iface.prefixLength);
    if (pattern.length > 0 && result.indexOf(pattern) < 0) {
      result.push(pattern);
    }
  }
  logger.debug(
    '[whitelist] 接口列表: ' + detail.join(', ') + ' -> whitelist([' + whitelistedNames.join(', ') + ']): [' +
      result.join(', ') + ']');
  if (result.length > 0) {
    return result;
  }
  return undefined;
}

// ── 服务器运行时状态 ──

let serverRunning = false;
let serverErrorMsg: string = '';
let noWifiWarning: boolean = false;
let allInterfacesDisabled: boolean = false;
let isReloading = false;

export function isServerRunning(): boolean {
  return serverRunning;
}

export function getServerError(): string {
  return serverErrorMsg;
}

export function getNoWifiWarning(): boolean {
  return noWifiWarning;
}

export function getAllInterfacesDisabled(): boolean {
  return allInterfacesDisabled;
}

export function getServerFingerprint(): string {
  return getServerFingerprintValue();
}

// 刷新本地网卡 + 重新计算局域网警告（由
// 在 AppService 门面中注册的网络变化监听器）。
// 两种不可发现的情况：
// 1. 没有 WiFi/以太网物理接口（noWifiWarning）
// 2. 所有接口都被用户关闭（allInterfacesDisabled）
export function refreshWifiWarning(): void {
  updateLocalInterfaces();
  let hasLan = getLocalInterfaces().some((iface: NetworkInterface) =>
  iface.type === NetworkType.wifi || iface.type === NetworkType.ethernet);
  noWifiWarning = !hasLan;
  // 检查用户是否关闭了所有接口（过滤后列表为空）
  let localInfo = getLocalDeviceInfo();
  allInterfacesDisabled = localInfo.interfaces.length === 0;
  notifyChange();
}

// 重启发现（不停 HTTP 服务器）：刷新接口列表 → 重算白/黑名单 → stop + start discovery。
// 用于网络接口变化后让组播 socket 绑定适配新接口，无需中断 HTTP 服务。
export async function restartDiscovery(): Promise<void> {
  if (!serverRunning) {
    logger.debug('[restartDiscovery] 服务器未运行，跳过');
    return;
  }

  logger.debug('[restartDiscovery] 开始重启 discovery');
  updateLocalInterfaces();
  // 更新警告状态（白/黑名单变化可能影响 allInterfacesDisabled）
  let hasLan = getLocalInterfaces().some((iface: NetworkInterface) =>
  iface.type === NetworkType.wifi || iface.type === NetworkType.ethernet);
  noWifiWarning = !hasLan;
  let localInfo = getLocalDeviceInfo();
  allInterfacesDisabled = localInfo.interfaces.length === 0;

  try {
    nativeDiscoverySetAnswerAnnouncements(false);
    nativeDiscoveryStop();
  } catch (_e) {
  }

  let protocol = getHttpsEnabled() ? 'https' : 'http';
  try {
    let whitelist = computeDiscoveryWhitelist();
    let blacklist = resolveNetworkBlacklist();
    let discoveryConfig: NativeDiscoveryConfig = {
      port: getPort(),
      protocol: protocol,
      multicastGroup: getMulticastGroup(),
      networkWhitelist: whitelist,
      networkBlacklist: blacklist,
      discoveryTimeoutMs: getDiscoveryTimeout(),
      download: true
    };
    logger.debug('[restartDiscovery] config: port=' + discoveryConfig.port +
      ' protocol=' + discoveryConfig.protocol +
      ' whitelist=' + JSON.stringify(discoveryConfig.networkWhitelist) +
      ' blacklist=' + JSON.stringify(discoveryConfig.networkBlacklist));
    await nativeStartDiscoveryV2(discoveryConfig);
    nativeDiscoverySetAnswerAnnouncements(true);
    addLog('info', 'Discovery restarted with updated network interfaces');
  } catch (e) {
    addLog('error', 'Discovery restart failed: ' + e);
  }

  // 立即通知 UI 更新警告状态（allInterfacesDisabled/noWifiWarning 可能已变化）
  notifyChange();
  triggerStagedDiscover();
}

// 查询原生层的实际服务器状态并同步到模块状态
function syncServerState(): boolean {
  try {
    let status = nativeGetServerStatus();
    serverRunning = status.running;
    if (status.fingerprint !== undefined && status.fingerprint.length > 0) {
      setServerFingerprint(status.fingerprint);
    }
  } catch (_e) {
    // 原生查询失败——保留当前 JS 状态
  }
  return serverRunning;
}

export async function startServer(): Promise<string> {
  // 如果原生服务器报告正在运行，先干净地停止
  try {
    let status = nativeGetServerStatus();
    if (status.running) {
      await stopLocalServer();
    }
  } catch (_e) {
  }
  return await startLocalServer();
}

export async function stopServer(): Promise<void> {
  await stopLocalServer();
  syncServerState();
}

export async function restartServer(): Promise<void> {
  clearServerNeedsRestart();
  // 始终执行完整的停止 + 启动以确保状态干净
  await stopLocalServer();
  try {
    await startLocalServer();
  } catch (_e) {
    // 启动失败——同步真实状态
    syncServerState();
  }
}

export async function restartServerFromSettings(): Promise<void> {
  clearServerNeedsRestart();
  await stopLocalServer();
  try {
    await startLocalServer();
  } catch (_e) {
    syncServerState();
  }
}

export async function reloadServerSettings(): Promise<void> {
  if (!serverRunning || isReloading) {
    return;
  }

  isReloading = true;

  // 刷新本地接口列表，确保自动 whitelist 基于最新接口信息（如 DHCP 更换 IP 后无需重启）
  updateLocalInterfaces();

  let appContext = getAppContext();
  let savedAlias: string = getDeviceAlias();
  let savedDeviceType: string = getDeviceType();
  let savedDeviceModel: string = getDeviceModel();
  let savedHttps: boolean = getHttpsEnabled();
  let protocol: string = savedHttps ? 'https' : 'http';

  try {
    nativeDiscoverySetAnswerAnnouncements(false);
    nativeDiscoveryStop();
  } catch (_e) {
  }

  try {
    await nativeStopServer();
  } catch (_e) {
  }

  if (appContext === undefined) {
    isReloading = false;
    return;
  }
  let saveDir: string = appContext.filesDir + '/LocalSend/';

  try {
    let handle = await nativeCreateServer({
      alias: savedAlias,
      deviceModel: savedDeviceModel,
      deviceType: savedDeviceType,
      port: getPort(),
      saveDir: saveDir,
      useHttps: savedHttps,
      pin: getReceivePin().length > 0 ? getReceivePin() : undefined
    });
    setServerFingerprint(handle.fingerprint);
    serverRunning = true;

    let discoveryConfig: NativeDiscoveryConfig = {
      port: getPort(),
      protocol: protocol,
      multicastGroup: getMulticastGroup(),
      networkWhitelist: computeDiscoveryWhitelist(),
      networkBlacklist: resolveNetworkBlacklist(),
      discoveryTimeoutMs: getDiscoveryTimeout(),
      download: true
    };
    await nativeStartDiscoveryV2(discoveryConfig);
    nativeDiscoverySetAnswerAnnouncements(true);
    addLog('info', 'Server reloaded with new settings');
  } catch (e) {
    addLog('error', 'Reload failed: ' + e + ', rolling back');
    protocol = savedHttps ? 'https' : 'http';

    try {
      let handle = await nativeCreateServer({
        alias: savedAlias,
        deviceModel: savedDeviceModel,
        deviceType: savedDeviceType,
        port: getPort(),
        saveDir: saveDir,
        useHttps: savedHttps,
        pin: getReceivePin().length > 0 ? getReceivePin() : undefined
      });
      setServerFingerprint(handle.fingerprint);
      serverRunning = true;
      let discoveryConfig: NativeDiscoveryConfig = {
        port: getPort(),
        protocol: protocol,
        multicastGroup: getMulticastGroup(),
        networkWhitelist: computeDiscoveryWhitelist(),
        networkBlacklist: resolveNetworkBlacklist(),
        discoveryTimeoutMs: getDiscoveryTimeout(),
        download: true
      };
      await nativeStartDiscoveryV2(discoveryConfig);
      nativeDiscoverySetAnswerAnnouncements(true);
      addLog('warn', 'Rollback OK, server running with previous settings');
    } catch (rollbackError) {
      serverRunning = false;
      addLog('error', 'Rollback also failed, server offline: ' + rollbackError);
    }
  } finally {
    isReloading = false;
  }
}

// ── 服务器生命周期 ──

export async function startLocalServer(): Promise<string> {
  let appContext = getAppContext();
  if (appContext === undefined) {
    addLog('error', 'AppService not initialized');
    return '';
  }

  // 更新本地网卡列表
  updateLocalInterfaces();
  addLog('info', `Local interfaces: ${getLocalInterfaces().map(i => `${i.ip}(${i.type})`).join(', ')}`);

  // 检查局域网可用性——仅在没有 WiFi 和以太网时给出警告
  let hasLan = getLocalInterfaces().some((iface: NetworkInterface) =>
  iface.type === NetworkType.wifi || iface.type === NetworkType.ethernet);
  noWifiWarning = !hasLan;
  // 检查用户是否关闭了所有接口
  let localInfo = getLocalDeviceInfo();
  allInterfacesDisabled = localInfo.interfaces.length === 0;

  let saveDir = appContext.filesDir + '/LocalSend/';
  try {
    fs.mkdirSync(saveDir);
  } catch (_e) {
  }
  let protocol = getHttpsEnabled() ? 'https' : 'http';
  let handle: NativeServerHandle;
  try {
    handle = await nativeCreateServer({
      alias: getDeviceAlias(),
      deviceModel: getDeviceModel(),
      deviceType: getDeviceType(),
      port: getPort(),
      saveDir: saveDir,
      useHttps: getHttpsEnabled(),
      verifyChecksums: isVerifyChecksums(),
      pin: getReceivePin().length > 0 ? getReceivePin() : undefined
    });
  } catch (e) {
    serverRunning = false;
    let errorMsg = String(e);
    // 检测端口占用错误并提供用户友好的提示
    if (errorMsg.indexOf('in use') >= 0 || errorMsg.indexOf('EADDRINUSE') >= 0 ||
      errorMsg.indexOf('Address already') >= 0) {
      let portMsg = appContext !== undefined ?
        appContext.resourceManager.getStringSync($r('app.string.port_in_use_error').id)
          .replace('%d', String(getPort())) :
        'Port ' + getPort() + ' is already in use';
      serverErrorMsg = portMsg;
      addLog('error', portMsg);
    } else {
      serverErrorMsg = errorMsg;
      addLog('error', 'Server start failed: ' + errorMsg);
    }
    return '';
  }
  // 清除之前的错误
  serverErrorMsg = '';
  setServerFingerprint(handle.fingerprint);
  serverRunning = true;
  // 服务器以当前设置运行——无需重启
  clearServerNeedsRestart();
  addLog('info', 'Server started, fingerprint=' + handle.fingerprint.substring(0, 10) + '...');

  // 启动 Rust 核心发现
  try {
    let discoveryConfig: NativeDiscoveryConfig = {
      port: getPort(),
      protocol: protocol,
      multicastGroup: getMulticastGroup(),
      networkWhitelist: computeDiscoveryWhitelist(),
      networkBlacklist: resolveNetworkBlacklist(),
      discoveryTimeoutMs: getDiscoveryTimeout(),
      download: true
    };
    logger.debug('[discovery] start v2: port=' + discoveryConfig.port + ' protocol=' + discoveryConfig.protocol +
      ' whitelist=' + JSON.stringify(discoveryConfig.networkWhitelist) +
      ' blacklist=' + JSON.stringify(discoveryConfig.networkBlacklist));
    await nativeStartDiscoveryV2(discoveryConfig);
    nativeDiscoverySetAnswerAnnouncements(true);
    addLog('info', 'Rust discovery started');
  } catch (e) {
    addLog('error', 'Discovery start failed: ' + e);
  }
  // 启动扫描：discover_staged 是唯一入口
  // （内部：announce + 收藏设备探测 + 宽限期后的条件子网扫描）
  // 与 LocalSend Flutter 的 StartSmartScan 行为一致
  triggerStagedDiscover();

  // 请求轮询由 AppService 门面启动（结合服务器 +
  // 传输生命周期），以避免仓库循环依赖。
  notifyChange();
  return handle.fingerprint;
}

export async function stopLocalServer(): Promise<void> {
  // 请求轮询由 AppService 门面停止（见上文）。
  try {
    nativeDiscoverySetAnswerAnnouncements(false);
    nativeDiscoveryStop();
  } catch (_e) {
  }
  try {
    await nativeStopServer();
  } catch (_e) {
  }
  if (getShareLink().length > 0) {
    await stopShareLink();
  }
  serverRunning = false;
  setServerFingerprint('');
  serverErrorMsg = '';
  clearDiscoveryState();
  addLog('info', 'Server stopped');
  notifyChange();
}
