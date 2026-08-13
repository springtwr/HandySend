import { socket } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { NetworkInterface, NetworkType } from '../model/Types';
import { nativeRegisterDevice, NativeRegisterResult } from '../service/NativeBridge';

const TAG = 'LocalSend:Discovery';
const DOMAIN = 0x0001;

interface MulticastMessageEvent {
  message: ArrayBuffer
  remoteInfo: socket.SocketRemoteInfo
}

interface NetworkInfo {
  ip: string
  prefixLength: number
}

const MULTICAST_GROUP = '224.0.0.167';
const MULTICAST_PORT = 53317;

// 多网卡支持：每个网卡一个独立的multicast socket
let multicastSockets: Array<socket.MulticastSocket> = [];
let running = false;
let localAlias = '';
let localFingerprint = '';
let localProtocol = 'https';
let localDeviceModel = '';
let localDeviceType = 'mobile';
let localPort: number = MULTICAST_PORT;
let decoder: util.TextDecoder | undefined = undefined;
let localInterfaces: Array<NetworkInterface> = [];  // 本地网卡列表

export function isDiscoveryRunning(): boolean {
  return running;
}

export async function startDiscovery(
  alias: string,
  fingerprint: string,
  onDeviceFound: (alias: string, ip: string, port: number,
    fingerprint: string, version: string, deviceModel: string,
    deviceType: string, protocol: string) => void,
  protocol: string = 'https',
  deviceModel: string = '',
  deviceType: string = 'mobile',
  serverPort: number = MULTICAST_PORT,
  interfaces: Array<NetworkInterface> = []
): Promise<void> {
  if (running) {
    hilog.error(DOMAIN, TAG, 'startDiscovery: already running, skip');
    return;
  }
  
  localAlias = alias;
  localFingerprint = fingerprint;
  localProtocol = protocol;
  localDeviceModel = deviceModel;
  localDeviceType = deviceType;
  localPort = serverPort;
  localInterfaces = interfaces;
  decoder = util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true });
  
  hilog.info(DOMAIN, TAG, 'startDiscovery BEGIN alias=%{public}s fp=%{public}s interfaces=%{public}d',
    alias, fingerprint.substring(0, 10) + '...', interfaces.length);
  
  // 多网卡广播：为每个网卡创建独立的multicast socket
  if (interfaces.length === 0) {
    hilog.warn(DOMAIN, TAG, 'No interfaces provided, using default 0.0.0.0');
    interfaces = [{ ip: '0.0.0.0', prefixLength: 24, type: NetworkType.unknown, isDefault: true }];
  }
  
  for (let i = 0; i < interfaces.length; i++) {
    let iface = interfaces[i];
    
    try {
      hilog.info(DOMAIN, TAG, 'Creating multicast socket for interface %{public}s (%{public}s)',
        iface.ip, iface.type);
      
      // 创建multicast socket
      let msock = socket.constructMulticastSocketInstance();
      
      // 绑定到特定网卡或0.0.0.0（所有网卡）
      let bindAddr: socket.NetAddress = {
        address: '0.0.0.0',  // 绑定到所有网卡，通过addMembership指定接收接口
        port: MULTICAST_PORT,
        family: 1
      };
      await msock.bind(bindAddr);
      hilog.info(DOMAIN, TAG, 'Multicast socket bound to 0.0.0.0:%{public}d for interface %{public}s',
        MULTICAST_PORT, iface.ip);
      
      // 设置multicast TTL
      try {
        await msock.setMulticastTTL(1);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'setMulticastTTL failed: %{public}s', JSON.stringify(e));
      }
      
      // 订阅消息事件
      msock.on('message', (data: MulticastMessageEvent) => {
        handleMessage(data, onDeviceFound);
      });
      
      // 加入multicast组（指定网卡）
      let groupAddr: socket.NetAddress = {
        address: MULTICAST_GROUP,
        port: MULTICAST_PORT
      };
      
      try {
        await msock.addMembership(groupAddr);
        hilog.info(DOMAIN, TAG, 'Joined multicast group %{public}s on interface %{public}s',
          MULTICAST_GROUP, iface.ip);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'addMembership failed for %{public}s: %{public}s',
          iface.ip, JSON.stringify(e));
        // 继续运行，只是无法接收multicast消息
      }
      
      // 禁用loopback（不接收自己发送的消息）
      try {
        await msock.setLoopbackMode(false);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'setLoopbackMode failed: %{public}s', JSON.stringify(e));
      }
      
      // 错误处理
      msock.on('error', (err: Object) => {
        hilog.error(DOMAIN, TAG, 'Multicast socket error on %{public}s: %{public}s',
          iface.ip, JSON.stringify(err));
      });
      
      msock.on('close', () => {
        hilog.info(DOMAIN, TAG, 'Multicast socket closed for %{public}s', iface.ip);
      });
      
      // 保存socket
      multicastSockets.push(msock);
      
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Failed to create multicast socket for %{public}s: %{public}s',
        iface.ip, JSON.stringify(e));
      // 继续处理其他网卡
    }
  }
  
  if (multicastSockets.length === 0) {
    throw new Error('Failed to create any multicast socket');
  }
  
  running = true;
  hilog.info(DOMAIN, TAG, 'Discovery started with %{public}d multicast socket(s)', multicastSockets.length);
  
  running = true;
  
  // Send 3 announces at 100/500/2000ms per LocalSend protocol spec
  setTimeout(() => {
    sendAnnounceNow(localAlias, localFingerprint, protocol, localDeviceModel, localDeviceType).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'announce1 failed: %{public}s', JSON.stringify(e));
    });
  }, 100);
  setTimeout(() => {
    sendAnnounceNow(localAlias, localFingerprint, protocol, localDeviceModel, localDeviceType).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'announce2 failed: %{public}s', JSON.stringify(e));
    });
  }, 500);
  setTimeout(() => {
    sendAnnounceNow(localAlias, localFingerprint, protocol, localDeviceModel, localDeviceType).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'announce3 failed: %{public}s', JSON.stringify(e));
    });
  }, 2000);
}

export async function stopDiscovery(): Promise<void> {
  if (!running) {
    return;
  }
  hilog.info(DOMAIN, TAG, 'Discovery STOPPING, closing %{public}d socket(s)', multicastSockets.length);
  running = false;
  
  // 关闭所有multicast socket
  for (let i = 0; i < multicastSockets.length; i++) {
    try {
      await multicastSockets[i].close();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'close socket %{public}d failed: %{public}s', i, JSON.stringify(e));
    }
  }
  
  multicastSockets = [];
  decoder = undefined;
  localInterfaces = [];
  hilog.info(DOMAIN, TAG, 'Discovery stopped');
}

function handleMessage(
  data: MulticastMessageEvent,
  onDeviceFound: (alias: string, ip: string, port: number,
    fingerprint: string, version: string, deviceModel: string,
    deviceType: string, protocol: string) => void
): void {
  if (!running) {
    return;
  }
  let text = '';
  try {
    if (decoder === undefined) {
      hilog.error(DOMAIN, TAG, 'handleMessage: decoder undefined');
      return;
    }
    let uint8 = new Uint8Array(data.message);
    text = decoder.decodeToString(uint8, { stream: false });
    let payload = JSON.parse(text) as Record<string, Object>;
    let aliasObj = payload['alias'];
    let fgpObj = payload['fingerprint'];
    let portObj = payload['port'];
    if (aliasObj === undefined || aliasObj === null ||
      fgpObj === undefined || fgpObj === null ||
      portObj === undefined || portObj === null) {
      hilog.error(DOMAIN, TAG, 'handleMessage: missing required fields, text=%{public}s',
        text.substring(0, Math.min(text.length, 200)));
      return;
    }
    let alias = aliasObj as string;
    let fgp = fgpObj as string;
    // Validate port: must be a valid integer in range [1, 65535]
    if (typeof portObj !== 'number' || !Number.isInteger(portObj) || portObj < 1 || portObj > 65535) {
      hilog.error(DOMAIN, TAG, 'handleMessage: invalid port=%{public}s, skipping', String(portObj));
      return;
    }
    let port = portObj;
    // Skip self-discovery by fingerprint
    if (fgp === localFingerprint) {
      return;
    }
    let versionObj = payload['version'];
    let modelObj = payload['deviceModel'];
    let typeObj = payload['deviceType'];
    let protoObj = payload['protocol'];
    let announceObj = payload['announce'];
    let announcementObj = payload['announcement'];
    let downloadObj = payload['download'];
    let version = versionObj !== undefined && versionObj !== null ? versionObj as string : '2.0';
    let deviceModel = modelObj !== undefined && modelObj !== null ? modelObj as string : '';
    let deviceType = typeObj !== undefined && typeObj !== null ? typeObj as string : 'desktop';
    let protocol = protoObj !== undefined && protoObj !== null ? protoObj as string : 'https';
    let shouldRespond = announceObj === true || announcementObj === true || downloadObj === true;
    // 优先使用payload中声明的IP（发送方自己知道的真实IP），
    // fallback到remoteInfo.address（在模拟器NAT场景下可能是127.0.0.1）
    let ipObj = payload['ip'];
    let deviceIp = (ipObj !== undefined && ipObj !== null && typeof ipObj === 'string' && ipObj.length > 0)
      ? ipObj as string
      : data.remoteInfo.address;
    hilog.info(DOMAIN, TAG, 'recv from %{public}s:%{public}d alias=%{public}s shouldRespond=%{public}s protocol=%{public}s declaredIp=%{public}s',
      data.remoteInfo.address, data.remoteInfo.port, alias, shouldRespond.toString(), protocol,
      ipObj !== undefined && ipObj !== null ? String(ipObj) : 'N/A');
    onDeviceFound(alias, deviceIp, port, fgp, version,
      deviceModel, deviceType, protocol);
    // Respond to announces: try TCP /register first, fall back to UDP multicast
    if (shouldRespond) {
      tryTcpRegister(deviceIp, data.remoteInfo.port,
        localAlias, localFingerprint, localProtocol, localDeviceModel, localDeviceType).then(() => {
        hilog.error(DOMAIN, TAG, 'TCP register OK, no need for UDP fallback');
      }).catch(() => {
        sendAnnounceNow(localAlias, localFingerprint, localProtocol, localDeviceModel, localDeviceType).catch((e: Object) => {
          hilog.error(DOMAIN, TAG, 'UDP announce fallback failed: %{public}s', JSON.stringify(e));
        });
      });
    }
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'handleMessage failed: %{public}s (text=%{public}s)',
      JSON.stringify(e), text.substring(0, Math.min(text.length, 200)));
  }
}

export async function sendAnnounceNow(alias: string, fingerprint: string, protocol: string = 'https', deviceModel: string = '', deviceType: string = 'mobile'): Promise<void> {
  if (multicastSockets.length === 0) {
    hilog.error(DOMAIN, TAG, 'sendAnnounce: no multicast sockets available');
    return;
  }
  
  let payload: Record<string, Object> = {
    'alias': alias,
    'version': '2.2',
    'deviceModel': deviceModel,
    'deviceType': deviceType,
    'fingerprint': fingerprint,
    'port': localPort,
    'protocol': protocol,
    'download': false,
    'ip': getAnnounceIp()
  };
  let json = JSON.stringify(payload);
  let sendAddr: socket.NetAddress = { address: MULTICAST_GROUP, port: MULTICAST_PORT };
  
  // 通过所有网卡发送广播
  let successCount = 0;
  for (let i = 0; i < multicastSockets.length; i++) {
    try {
      await multicastSockets[i].send({ data: json, address: sendAddr });
      successCount++;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'announce send failed on socket %{public}d: %{public}s',
        i, JSON.stringify(e));
    }
  }
  
  hilog.info(DOMAIN, TAG, 'Announce sent via %{public}d/%{public}d interface(s) (%{public}d bytes) alias=%{public}s',
    successCount, multicastSockets.length, json.length, alias);
  
  if (successCount === 0) {
    throw new Error('Failed to send announce on any interface');
  }
}

function getAnnounceIp(): string {
  // 返回默认网络的IP，用于在announce payload中声明自己的IP
  // 这样接收方可以优先使用发送方声明的IP，而非remoteInfo.address
  // （后者在模拟器场景下可能是127.0.0.1）
  for (let i = 0; i < localInterfaces.length; i++) {
    if (localInterfaces[i].isDefault) {
      return localInterfaces[i].ip;
    }
  }
  if (localInterfaces.length > 0) {
    return localInterfaces[0].ip;
  }
  return '';
}

// ── TCP register (preferred response to announce, falls back to UDP) ──
// Uses Rust NAPI for mTLS support — ArkTS HTTP client cannot provide client certificates.

async function tryTcpRegister(
  targetIp: string,
  targetPort: number,
  ourAlias: string,
  ourFingerprint: string,
  ourProtocol: string,
  ourDeviceModel: string = '',
  ourDeviceType: string = 'mobile'
): Promise<void> {
  let result: NativeRegisterResult = await nativeRegisterDevice(
    targetIp, targetPort,
    ourAlias, ourFingerprint, ourProtocol,
    ourDeviceModel, ourDeviceType,
    localPort, getAnnounceIp()
  );
  // If we get here, register succeeded — notify device found with response info
  // (protocol from actual successful connection, not from response body)
  if (result.fingerprint !== ourFingerprint && result.alias.length > 0) {
    hilog.info(DOMAIN, TAG, 'TCP register OK to %{public}s:%{public}d proto=%{public}s alias=%{public}s',
      targetIp, targetPort, result.protocol, result.alias);
  } else {
    hilog.info(DOMAIN, TAG, 'TCP register OK to %{public}s:%{public}d proto=%{public}s (self or empty alias)',
      targetIp, targetPort, result.protocol);
  }
}

function getLocalNetworkInfo(): NetworkInfo {
  try {
    let netHandle = connection.getDefaultNetSync();
    let props = connection.getConnectionPropertiesSync(netHandle);
    if (props.linkAddresses !== undefined) {
      for (let i = 0; i < props.linkAddresses.length; i++) {
        let linkAddr = props.linkAddresses[i];
        if (linkAddr.address !== undefined && linkAddr.address.family === 1) {
          let info: NetworkInfo = { ip: linkAddr.address.address, prefixLength: linkAddr.prefixLength };
          return info;
        }
      }
    }
  } catch (_e) {
  }
  let defaultInfo: NetworkInfo = { ip: '0.0.0.0', prefixLength: 24 };
  return defaultInfo;
}

function ipToNum(ip: string): number {
  let parts = ip.split('.');
  if (parts.length !== 4) {
    return 0; // Invalid IP format
  }
  let result = 0;
  for (let i = 0; i < 4; i++) {
    let octet = Number(parts[i]);
    if (!Number.isInteger(octet) || octet < 0 || octet > 255) {
      return 0; // Invalid octet
    }
    result = (result << 8) | octet;
  }
  return result >>> 0; // Ensure unsigned
}

function numToIp(num: number): string {
  return ((num >>> 24) & 0xFF) + '.' + ((num >>> 16) & 0xFF) + '.' + ((num >>> 8) & 0xFF) + '.' + (num & 0xFF);
}

function buildIpRange(localIp: string, prefixLength: number): Array<string> {
  // Validate prefixLength: must be in [1, 32]
  if (prefixLength < 1 || prefixLength > 32) {
    hilog.warn(DOMAIN, TAG, 'buildIpRange: invalid prefixLength=%{public}d, defaulting to 24', prefixLength);
    prefixLength = 24;
  }
  let ipNum = ipToNum(localIp);
  let mask = prefixLength >= 32 ? 0xFFFFFFFF : (~((1 << (32 - prefixLength)) - 1)) >>> 0;
  let network = ipNum & mask;
  let hostCount = (1 << (32 - prefixLength)) - 2;
  if (hostCount > 254) {
    hostCount = 254;
  }
  let result: Array<string> = [];
  for (let i = 1; i <= hostCount; i++) {
    let candidate = network + i;
    if (candidate === ipNum) {
      continue;
    }
    result.push(numToIp(candidate));
  }
  return result;
}

// ── Scan favorite devices' known IP:Port addresses (T039) ──
// This is called from AppService.startLocalServer after discovery starts

interface FavScanTarget {
  ip: string;
  port: number;
  fingerprint: string;
}

export async function scanFavoriteDevices(
  favoriteDevices: Array<FavScanTarget>,
  onDeviceFound: (alias: string, ip: string, port: number,
    fingerprint: string, version: string, deviceModel: string,
    deviceType: string, protocol: string) => void,
  ourAlias: string,
  ourFingerprint: string,
  ourProtocol: string = 'https',
  ourDeviceModel: string = '',
  ourDeviceType: string = 'mobile',
  ourPort: number = MULTICAST_PORT
): Promise<void> {
  if (favoriteDevices.length === 0) {
    return;
  }
  hilog.info(DOMAIN, TAG, 'scanFavoriteDevices: scanning %{public}d favorites', favoriteDevices.length);
  for (let i = 0; i < favoriteDevices.length; i++) {
    let fav = favoriteDevices[i];
    if (fav.ip.length === 0 || fav.ip === '0.0.0.0') {
      continue;
    }
    // Use Rust NAPI for mTLS-capable register
    try {
      let result: NativeRegisterResult = await nativeRegisterDevice(
        fav.ip, fav.port,
        ourAlias, ourFingerprint, ourProtocol,
        ourDeviceModel, ourDeviceType,
        ourPort, getAnnounceIp()
      );
      if (result.fingerprint.length > 0 && result.fingerprint !== ourFingerprint) {
        onDeviceFound(result.alias, fav.ip, fav.port,
          result.fingerprint, result.version, result.deviceModel,
          result.deviceType, result.protocol);
        hilog.info(DOMAIN, TAG, 'scanFavoriteDevices: FOUND %{public}s at %{public}s:%{public}d proto=%{public}s',
          result.alias, fav.ip, fav.port, result.protocol);
      }
    } catch (_e) {
      hilog.info(DOMAIN, TAG, 'scanFavoriteDevices: skip %{public}s:%{public}d (failed)', fav.ip, fav.port);
    }
  }
  hilog.info(DOMAIN, TAG, 'scanFavoriteDevices: done');
}

export async function scanSubnetHttp(
  onDeviceFound: (alias: string, ip: string, port: number,
    fingerprint: string, version: string, deviceModel: string,
    deviceType: string, protocol: string) => void,
  ourAlias: string,
  ourFingerprint: string,
  ourProtocol: string = 'https',
  ourDeviceModel: string = '',
  ourDeviceType: string = 'mobile',
  ourPort: number = MULTICAST_PORT,
  interfaces: Array<NetworkInterface> = []
): Promise<void> {
  // 如果没有传入网卡列表，使用本地保存的列表
  if (interfaces.length === 0) {
    interfaces = localInterfaces;
  }
  
  if (interfaces.length === 0) {
    hilog.warn(DOMAIN, TAG, 'scanSubnetHttp: no interfaces, skip');
    return;
  }
  
  hilog.info(DOMAIN, TAG, 'scanSubnetHttp: scanning %{public}d interface(s)', interfaces.length);
  
  // 为每个网卡扫描对应的子网
  for (let ifaceIdx = 0; ifaceIdx < interfaces.length; ifaceIdx++) {
    let iface = interfaces[ifaceIdx];
    
    if (iface.ip === '0.0.0.0') {
      hilog.warn(DOMAIN, TAG, 'scanSubnetHttp: interface %{public}d has no IP, skip', ifaceIdx);
      continue;
    }
    
    let targets = buildIpRange(iface.ip, iface.prefixLength);
    if (targets.length === 0) {
      continue;
    }
    
    hilog.info(DOMAIN, TAG, 'scanSubnetHttp: scanning %{public}d IPs on interface %{public}s/%{public}d (%{public}s)',
      targets.length, iface.ip, iface.prefixLength, iface.type);
    
    // 执行子网扫描（复用原有逻辑）
    await scanSubnetOnInterface(targets, onDeviceFound, ourAlias, ourFingerprint, ourProtocol,
      ourDeviceModel, ourDeviceType, ourPort, iface.ip);
  }
}

// 辅助函数：扫描单个子网
// Uses Rust NAPI for mTLS support — concurrent workers each call nativeRegisterDevice
async function scanSubnetOnInterface(
  targets: Array<string>,
  onDeviceFound: (alias: string, ip: string, port: number,
    fingerprint: string, version: string, deviceModel: string,
    deviceType: string, protocol: string) => void,
  ourAlias: string,
  ourFingerprint: string,
  ourProtocol: string,
  ourDeviceModel: string,
  ourDeviceType: string,
  ourPort: number,
  interfaceIp: string
): Promise<void> {
  let completed = 0;
  let found = 0;
  let index = 0;
  let worker = async (): Promise<void> => {
    while (index < targets.length) {
      let targetIp = targets[index++];
      try {
        let result: NativeRegisterResult = await nativeRegisterDevice(
          targetIp, ourPort,
          ourAlias, ourFingerprint, ourProtocol,
          ourDeviceModel, ourDeviceType,
          ourPort, getAnnounceIp()
        );
        if (result.fingerprint.length > 0 && result.fingerprint !== ourFingerprint) {
          onDeviceFound(result.alias, targetIp, ourPort,
            result.fingerprint, result.version, result.deviceModel,
            result.deviceType, result.protocol);
          found++;
          hilog.info(DOMAIN, TAG, 'scanSubnetHttp: FOUND %{public}s at %{public}s via interface %{public}s proto=%{public}s',
            result.alias, targetIp, interfaceIp, result.protocol);
        }
      } catch (_e) {
        // Connection failed — skip this IP
      }
      completed++;
    }
  };
  let concurrency = 20;
  if (concurrency > targets.length) {
    concurrency = targets.length;
  }
  let workers: Array<Promise<void>> = [];
  for (let i = 0; i < concurrency; i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  hilog.info(DOMAIN, TAG, 'scanSubnetHttp: done %{public}d/%{public}d found=%{public}d',
    completed, targets.length, found);
}