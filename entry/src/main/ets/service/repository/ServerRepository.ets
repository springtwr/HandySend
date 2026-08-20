import { fileIo as fs } from '@kit.CoreFileKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { NetworkInterface, NetworkType } from '../../model/Types';
import { NativeServerHandle, NativeDiscoveryConfig } from '../../model/NativeTypes';
import { nativeCreateServer, nativeStopServer, nativeGetServerStatus,
  nativeStartDiscoveryV2, nativeDiscoverySetAnswerAnnouncements, nativeDiscoveryStop } from '../NativeBridge';
import { getAppContext, addLog, notifyChange, updateLocalInterfaces, getLocalInterfaces,
  getServerFingerprint as getServerFingerprintValue, setServerFingerprint } from './AppCore';
import { getHttpsEnabled, getPort, getReceivePin, getMulticastGroup, getDiscoveryTimeout,
  getNetworkListAsArray, getNetworkWhitelist, getNetworkBlacklist, clearServerNeedsRestart } from './SettingsRepository';
import { getDeviceAlias, getDeviceModel, getDeviceType } from './DeviceRepository';
import { triggerStagedDiscover, clearDiscoveryState } from './DiscoveryRepository';
import { getShareLink, stopShareLink } from './WebShareRepository';

const logger = getLogger(LogDomains.SERVER, 'HandySend:ServerRepository');

// ── 服务器运行时状态 ──

let serverRunning = false;
let serverErrorMsg: string = '';
let noWifiWarning: boolean = false;
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

export function getServerFingerprint(): string {
  return getServerFingerprintValue();
}

// 刷新本地网卡 + 重新计算 WiFi 警告（由
// 在 AppService 门面中注册的网络变化监听器）。
export function refreshWifiWarning(): void {
  updateLocalInterfaces();
  let hasWifi = getLocalInterfaces().some((iface: NetworkInterface) => iface.type === NetworkType.wifi);
  noWifiWarning = !hasWifi;
  notifyChange();
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
  } catch (_e) {}
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

  let appContext = getAppContext();
  let savedAlias: string = getDeviceAlias();
  let savedDeviceType: string = getDeviceType();
  let savedDeviceModel: string = getDeviceModel();
  let savedHttps: boolean = getHttpsEnabled();
  let protocol: string = savedHttps ? 'https' : 'http';

  try {
    nativeDiscoverySetAnswerAnnouncements(false);
    nativeDiscoveryStop();
  } catch (_e) {}

  try {
    await nativeStopServer();
  } catch (_e) {}

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
      networkWhitelist: getNetworkListAsArray(getNetworkWhitelist()),
      networkBlacklist: getNetworkListAsArray(getNetworkBlacklist()),
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
        networkWhitelist: getNetworkListAsArray(getNetworkWhitelist()),
        networkBlacklist: getNetworkListAsArray(getNetworkBlacklist()),
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

  // 检查 WiFi 可用性——仅在蜂窝网络时给出警告
  let hasWifi = getLocalInterfaces().some((iface: NetworkInterface) => iface.type === NetworkType.wifi);
  noWifiWarning = !hasWifi;

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
      pin: getReceivePin().length > 0 ? getReceivePin() : undefined
    });
  } catch (e) {
    serverRunning = false;
    let errorMsg = String(e);
    // 检测端口占用错误并提供用户友好的提示
    if (errorMsg.indexOf('in use') >= 0 || errorMsg.indexOf('EADDRINUSE') >= 0 ||
        errorMsg.indexOf('Address already') >= 0) {
      let portMsg = appContext !== undefined ?
        appContext.resourceManager.getStringSync($r('app.string.port_in_use_error').id).replace('%d', String(getPort())) :
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
      networkWhitelist: getNetworkListAsArray(getNetworkWhitelist()),
      networkBlacklist: getNetworkListAsArray(getNetworkBlacklist()),
      discoveryTimeoutMs: getDiscoveryTimeout(),
      download: true
    };
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
