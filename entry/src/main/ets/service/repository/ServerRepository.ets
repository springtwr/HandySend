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

// ── Server runtime state ──

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

// Refreshes local interfaces + recomputes the WiFi warning (called by the
// network-change listener registered in the AppService facade).
export function refreshWifiWarning(): void {
  updateLocalInterfaces();
  let hasWifi = getLocalInterfaces().some((iface: NetworkInterface) => iface.type === NetworkType.wifi);
  noWifiWarning = !hasWifi;
  notifyChange();
}

// Query native layer for actual server state and sync to module state
function syncServerState(): boolean {
  try {
    let status = nativeGetServerStatus();
    serverRunning = status.running;
    if (status.fingerprint !== undefined && status.fingerprint.length > 0) {
      setServerFingerprint(status.fingerprint);
    }
  } catch (_e) {
    // Native query failed — keep current JS state
  }
  return serverRunning;
}

export async function startServer(): Promise<string> {
  // If native server reports running, do a clean stop first
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
  // Always do a full stop + start to ensure clean state
  await stopLocalServer();
  try {
    await startLocalServer();
  } catch (_e) {
    // Start failed — sync real state
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

// ── Server lifecycle ──

export async function startLocalServer(): Promise<string> {
  let appContext = getAppContext();
  if (appContext === undefined) {
    addLog('error', 'AppService not initialized');
    return '';
  }

  // 更新本地网卡列表
  updateLocalInterfaces();
  addLog('info', `Local interfaces: ${getLocalInterfaces().map(i => `${i.ip}(${i.type})`).join(', ')}`);

  // Check WiFi availability — warn if only cellular
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
    // Detect port-in-use errors and provide user-friendly message
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
  // Clear any previous error
  serverErrorMsg = '';
  setServerFingerprint(handle.fingerprint);
  serverRunning = true;
  // Server is running with current settings — no restart needed
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
  // Startup scan: discover_staged is the single entry point
  // (internally: announce + favorites probe + conditional subnet scan after grace period)
  // Matches LocalSend Flutter's StartSmartScan behavior
  triggerStagedDiscover();

  // Request polling is started by the AppService facade (combines server +
  // transfer lifecycle) to avoid a repository circular dependency.
  notifyChange();
  return handle.fingerprint;
}

export async function stopLocalServer(): Promise<void> {
  // Request polling is stopped by the AppService facade (see above).
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
