import { hilog } from '@kit.PerformanceAnalysisKit';
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

const TAG = 'LocalSend:DiscoveryRepository';
const DOMAIN = 0x0001;
const DEVICE_EXPIRY_MS = 120000;

// ── Discovered devices state ──

let discoveredDevices: Array<DiscoveredDevice> = [];

export function clearDiscoveryState(): void {
  discoveredDevices = [];
}

export function getDiscoveredDevices(): Array<DiscoveredDevice> {
  let now = Date.now();
  // Filter out expired devices (lastSeen too old)
  // Devices are only added via handleDeviceFound (actual confirmations),
  // so lastSeen is only updated when a device actually responds.
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
    hilog.info(DOMAIN, TAG, '[DBG-DEVS]   expired: %{public}s', expired.join(', '));
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

// ── Event handlers (routed from handleNativeEvent) ──

// Handle a single device found event (like LocalSend's RegisterDeviceAction).
// Rust sends only the newly discovered/updated device, not the full store.
export function handleDeviceFound(event: NativeDeviceFoundEvent): void {
  let deviceObj: Record<string, Object> = event.device;
  let now = Date.now();

  // Parse device fields
  let alias: string = (deviceObj['alias'] as string) || '';
  let fingerprint: string = (deviceObj['fingerprint'] as string) || '';
  let version: string = (deviceObj['version'] as string) || '';
  let deviceModel: string = (deviceObj['deviceModel'] as string) || '';
  let deviceType: string = (deviceObj['deviceType'] as string) || '';
  let download: boolean = (deviceObj['download'] as boolean) || false;
  let host: string = (deviceObj['host'] as string) || '';
  let devPort: number = (deviceObj['port'] as number) || 53317;
  let devProtocol: string = (deviceObj['protocol'] as string) || 'http';

  // Parse channels
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

  // Find existing device
  let existingDevice: DiscoveredDevice | undefined = undefined;
  for (let k = 0; k < discoveredDevices.length; k++) {
    if (discoveredDevices[k].fingerprint === fingerprint) {
      existingDevice = discoveredDevices[k];
      break;
    }
  }

  // Keep HTTPS if existing device had it
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

  // Replace existing entry or append new
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
  // Update/add devices from the event
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

    // Device is confirmed present — update lastSeen to now
    let lastSeen: number = now;

    // Keep HTTPS if existing device had it
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

    // Replace existing entry or append new
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
  // Devices NOT in this event keep their existing state (including lastSeen);
  // they will expire naturally via getDiscoveredDevices() when lastSeen is too old.
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
    // Use the remote device's actual protocol (from its register payload),
    // not the local server's setting.
    protocol: (info.protocol !== undefined && info.protocol !== null && info.protocol.length > 0) ?
      info.protocol : (getHttpsEnabled() ? 'https' : 'http'),
    channels: []
  };
  nativeDiscoveryAddDevice(nativeDevice).catch((e: Error) => {
    addLog('warn', 'Failed to add register device to discovery: ' + e.message);
  });
}

// ── Scan / rescan ──

// Helper: trigger staged discover using current config + favorites
// Does NOT include subnet scan to avoid duplicate DISCOVER/REGISTER messages
// when called alongside announce(). Use scanSubnets() separately if needed.
export function triggerStagedDiscover(): void {
  let favDevices = getFavorites();
  let channels: Array<NativeDeviceChannel> = [];
  let protocol = getHttpsEnabled() ? 'https' : 'http';
  let altProtocol = getHttpsEnabled() ? 'http' : 'https';
  for (let i = 0; i < favDevices.length; i++) {
    // Probe favorites with both protocols so we can find devices using a different encryption mode
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
    // Scan with alternate protocol to discover devices using a different encryption mode
    for (let i = 0; i < interfaceIps.length; i++) {
      nativeDiscoveryScanSubnet(interfaceIps[i], getPort(), altProtocol).catch((e: Error) => {
        hilog.info(DOMAIN, TAG, '[DBG-SCAN]   alt-protocol scan (%{public}s) for %{public}s failed: %{public}s', altProtocol, interfaceIps[i], e.message);
      });
    }
  }).catch((e: Error) => {
    addLog('warn', 'Staged discover failed: ' + e.message);
    // Still try alt-protocol scan even if primary discover failed
    for (let i = 0; i < interfaceIps.length; i++) {
      nativeDiscoveryScanSubnet(interfaceIps[i], getPort(), altProtocol).catch((_e: Error) => {
        // Ignore alt-protocol scan failures
      });
    }
  });
}

// Helper: scan subnets for new devices (not combined with announce to avoid duplicates)

export function rescanDevices(announce: boolean = true): void {
  let serverFingerprint: string = getServerFingerprint();
  if (serverFingerprint.length > 0) {
    // Match LocalSend Flutter's StartSmartScan:
    // 1. Clear device list first (so stale devices disappear)
    // 2. Call discover_staged (which internally includes announce + favorites probe + conditional subnet scan)
    discoveredDevices = [];
    if (announce) {
      // discover_staged already includes announce internally,
      // so just call triggerStagedDiscover — it's the equivalent of StartSmartScan
      triggerStagedDiscover();
    } else {
      // No announce (e.g. server restart), probe known addresses only
      triggerStagedDiscover();
    }
    notifyChange();
  }
}

// ── Manual IP connect ──

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
