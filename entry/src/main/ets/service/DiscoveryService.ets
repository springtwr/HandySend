import { socket, http } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';

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

let msock: socket.MulticastSocket | undefined = undefined;
let running = false;
let localAlias = '';
let localFingerprint = '';
let localProtocol = 'https';
let localDeviceModel = '';
let localDeviceType = 'mobile';
let decoder: util.TextDecoder | undefined = undefined;

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
  deviceType: string = 'mobile'
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
  decoder = util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true });
  hilog.error(DOMAIN, TAG, 'startDiscovery BEGIN alias=%{public}s fp=%{public}s',
    alias, fingerprint.substring(0, 10) + '...');

  try {
    msock = socket.constructMulticastSocketInstance();
    hilog.error(DOMAIN, TAG, 'STEP1 construct OK');
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'STEP1 construct FAILED: %{public}s', JSON.stringify(e));
    throw new Error('construct failed: ' + JSON.stringify(e));
  }

  let bindAddr: socket.NetAddress = { address: '0.0.0.0', port: MULTICAST_PORT, family: 1 };
  try {
    await msock.bind(bindAddr);
    hilog.error(DOMAIN, TAG, 'STEP3 bind OK 0.0.0.0:%{public}d', MULTICAST_PORT);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'STEP3 bind FAILED: %{public}s', JSON.stringify(e));
    throw new Error('bind failed: ' + JSON.stringify(e));
  }

  // Set multicast TTL to at least 1 so packets leave the device (LAN scope)
  try {
    await msock.setMulticastTTL(1);
    hilog.error(DOMAIN, TAG, 'STEP3b setMulticastTTL(1) OK');
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'STEP3b setMulticastTTL skipped: %{public}s', JSON.stringify(e));
  }

  // Subscribe to message event BEFORE addMembership to avoid missing early packets
  try {
    msock.on('message', (data: MulticastMessageEvent) => {
      handleMessage(data, onDeviceFound);
    });
    hilog.error(DOMAIN, TAG, 'STEP4 on(message) subscribed');
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'STEP4 on(message) FAILED: %{public}s', JSON.stringify(e));
  }

  // addMembership is required for receiving multicast datagrams.
  // On emulators or networks without multicast support, this may fail.
  // We degrade gracefully: UDP receive won't work, but sending still works.
  // HTTP subnet scan will serve as the fallback for device discovery.
  let groupAddr: socket.NetAddress = { address: MULTICAST_GROUP, port: MULTICAST_PORT };
  let multicastReceiveOk = false;
  try {
    await msock.addMembership(groupAddr);
    multicastReceiveOk = true;
    hilog.error(DOMAIN, TAG, 'STEP5 addMembership OK %{public}s', MULTICAST_GROUP);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'STEP5 addMembership FAILED (multicast receive disabled): %{public}s', JSON.stringify(e));
    // Don't throw — continue with degraded mode (send-only + HTTP scan fallback)
  }

  try {
    await msock.setLoopbackMode(false);
    hilog.error(DOMAIN, TAG, 'STEP6 setLoopbackMode(false) OK');
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'STEP6 setLoopbackMode FAILED: %{public}s', JSON.stringify(e));
  }

  try {
    msock.on('error', (err: Object) => {
      hilog.error(DOMAIN, TAG, 'on(error): %{public}s', JSON.stringify(err));
    });
  } catch (_e) {
  }

  try {
    msock.on('close', () => {
      hilog.error(DOMAIN, TAG, 'on(close) socket closed');
    });
  } catch (_e) {
  }

  try {
    let fd = await msock.getSocketFd();
    hilog.error(DOMAIN, TAG, 'STEP7 getSocketFd=%{public}d', fd);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'STEP7 getSocketFd skipped: %{public}s', JSON.stringify(e));
  }

  running = true;
  if (multicastReceiveOk) {
    hilog.info(DOMAIN, TAG, 'Discovery STARTED (full mode) on 0.0.0.0:%{public}d / %{public}s:%{public}d',
      MULTICAST_PORT, MULTICAST_GROUP, MULTICAST_PORT);
  } else {
    hilog.warn(DOMAIN, TAG, 'Discovery STARTED (send-only mode, HTTP scan fallback) on 0.0.0.0:%{public}d',
      MULTICAST_PORT);
  }

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
  if (!running || msock === undefined) {
    return;
  }
  hilog.error(DOMAIN, TAG, 'Discovery STOPPING');
  running = false;
  try {
    await msock.close();
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'close FAILED: %{public}s', JSON.stringify(e));
  } finally {
    msock = undefined;
    decoder = undefined;
  }
}

function handleMessage(
  data: MulticastMessageEvent,
  onDeviceFound: (alias: string, ip: string, port: number,
    fingerprint: string, version: string, deviceModel: string,
    deviceType: string, protocol: string) => void
): void {
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
    let port = portObj as number;
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
    let version = versionObj !== undefined && versionObj !== null ? versionObj as string : '2.0';
    let deviceModel = modelObj !== undefined && modelObj !== null ? modelObj as string : '';
    let deviceType = typeObj !== undefined && typeObj !== null ? typeObj as string : 'desktop';
    let protocol = protoObj !== undefined && protoObj !== null ? protoObj as string : 'https';
    let announce = announceObj === true || announcementObj === true;
    hilog.error(DOMAIN, TAG, 'recv from %{public}s:%{public}d alias=%{public}s announce=%{public}s protocol=%{public}s',
      data.remoteInfo.address, data.remoteInfo.port, alias, announce.toString(), protocol);
    onDeviceFound(alias, data.remoteInfo.address, port, fgp, version,
      deviceModel, deviceType, protocol);
    // Respond to announces: try TCP /register first, fall back to UDP multicast
    if (announce) {
      tryTcpRegister(data.remoteInfo.address, data.remoteInfo.port,
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
  if (msock === undefined) {
    hilog.error(DOMAIN, TAG, 'sendAnnounce: msock undefined');
    return;
  }
  let payload: Record<string, Object> = {
    'alias': alias,
    'version': '2.1',
    'deviceModel': deviceModel,
    'deviceType': deviceType,
    'fingerprint': fingerprint,
    'port': MULTICAST_PORT,
    'protocol': protocol,
    'download': false,
    'announce': true,
    'announcement': true
  };
  let json = JSON.stringify(payload);
  let sendAddr: socket.NetAddress = { address: MULTICAST_GROUP, port: MULTICAST_PORT };
  try {
    await msock.send({ data: json, address: sendAddr });
    hilog.error(DOMAIN, TAG, 'announce SENT (%{public}d bytes) alias=%{public}s', json.length, alias);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'announce SEND FAILED: %{public}s', JSON.stringify(e));
    throw new Error('send failed: ' + JSON.stringify(e));
  }
}

// ── TCP register (preferred response to announce, falls back to UDP) ──

async function tryTcpRegister(
  targetIp: string,
  targetPort: number,
  ourAlias: string,
  ourFingerprint: string,
  ourProtocol: string,
  ourDeviceModel: string = '',
  ourDeviceType: string = 'mobile'
): Promise<void> {
  let body: string = JSON.stringify({
    'alias': ourAlias,
    'version': '2.1',
    'deviceModel': ourDeviceModel,
    'deviceType': ourDeviceType,
    'fingerprint': ourFingerprint,
    'port': MULTICAST_PORT,
    'protocol': ourProtocol,
    'download': false,
    'announce': false,
    'announcement': false
  });
  let skipCert = deviceInfo.sdkApiVersion >= 18;
  let protocols: Array<string> = ['https', 'http'];
  for (let pi = 0; pi < protocols.length; pi++) {
    let url: string = protocols[pi] + '://' + targetIp + ':' + targetPort +
      '/api/localsend/v2/register';
    try {
      let httpRequest = http.createHttp();
      let opts: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        connectTimeout: 1500,
        readTimeout: 1500,
        header: { 'Content-Type': 'application/json' },
        extraData: body
      };
      if (skipCert && protocols[pi] === 'https') {
        opts.remoteValidation = 'skip' as http.RemoteValidation;
      }
      let ok: boolean = await new Promise<boolean>((resolve) => {
        httpRequest.request(url, opts).then((resp: http.HttpResponse) => {
          resolve(resp.responseCode === 200 || resp.responseCode === 412);
        }).catch((e: Error) => {
          hilog.error(DOMAIN, TAG, 'TCP register %{public}s err=%{public}s',
            protocols[pi], e.message);
          resolve(false);
        }).finally(() => {
          httpRequest.destroy();
        });
      });
      if (ok) {
        hilog.error(DOMAIN, TAG, 'TCP register OK to %{public}s:%{public}d proto=%{public}s',
          targetIp, targetPort, protocols[pi]);
        return;
      }
    } catch (_e) {
    }
  }
  throw new Error('TCP register failed to ' + targetIp + ':' + targetPort);
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
  return (Number(parts[0]) << 24) | (Number(parts[1]) << 16) | (Number(parts[2]) << 8) | Number(parts[3]);
}

function numToIp(num: number): string {
  return ((num >>> 24) & 0xFF) + '.' + ((num >>> 16) & 0xFF) + '.' + ((num >>> 8) & 0xFF) + '.' + (num & 0xFF);
}

function buildIpRange(localIp: string, prefixLength: number): Array<string> {
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
  ourDeviceType: string = 'mobile'
): Promise<void> {
  if (favoriteDevices.length === 0) {
    return;
  }
  hilog.info(DOMAIN, TAG, 'scanFavoriteDevices: scanning %{public}d favorites', favoriteDevices.length);
  let registerBody = JSON.stringify({
    'alias': ourAlias,
    'version': '2.1',
    'deviceModel': ourDeviceModel,
    'deviceType': ourDeviceType,
    'fingerprint': ourFingerprint,
    'port': MULTICAST_PORT,
    'protocol': ourProtocol,
    'download': false,
    'announce': false,
    'announcement': false
  });
  let skipCert = deviceInfo.sdkApiVersion >= 18;
  for (let i = 0; i < favoriteDevices.length; i++) {
    let fav = favoriteDevices[i];
    if (fav.ip.length === 0 || fav.ip === '0.0.0.0') {
      continue;
    }
    // Try HTTP POST to /api/localsend/v2/register at the favorite's known IP:Port
    let protocols: Array<string> = ['https', 'http'];
    let found = false;
    for (let pi = 0; pi < protocols.length && !found; pi++) {
      let proto = protocols[pi];
      let url = proto + '://' + fav.ip + ':' + fav.port + '/api/localsend/v2/register';
      try {
        let httpRequest = http.createHttp();
        let opts: http.HttpRequestOptions = {
          method: http.RequestMethod.POST,
          connectTimeout: 1500,
          readTimeout: 1500,
          header: { 'Content-Type': 'application/json' },
          extraData: registerBody
        };
        if (skipCert && proto === 'https') {
          opts.remoteValidation = 'skip' as http.RemoteValidation;
        }
        let resp: http.HttpResponse = await httpRequest.request(url, opts);
        httpRequest.destroy();
        if (resp.responseCode === 200 && resp.result !== undefined) {
          try {
            let data = JSON.parse(resp.result as string) as Record<string, Object>;
            let respAlias = data['alias'];
            let respFp = data['fingerprint'];
            if (respAlias !== undefined && respAlias !== null &&
                respFp !== undefined && respFp !== null &&
                respFp !== ourFingerprint) {
              let respVersion = data['version'] !== undefined ? data['version'] as string : '2.0';
              let respModel = data['deviceModel'] !== undefined ? data['deviceModel'] as string : '';
              let respType = data['deviceType'] !== undefined ? data['deviceType'] as string : 'desktop';
              let respProtocol = data['protocol'] !== undefined ? data['protocol'] as string : 'https';
              onDeviceFound(respAlias as string, fav.ip, fav.port,
                respFp as string, respVersion, respModel, respType, respProtocol);
              found = true;
              hilog.info(DOMAIN, TAG, 'scanFavoriteDevices: FOUND %{public}s at %{public}s:%{public}d',
                respAlias as string, fav.ip, fav.port);
            }
          } catch (_e) {
            // Parse error, skip
          }
        }
      } catch (e) {
        // Connection timeout/error - gracefully skip this favorite
        hilog.info(DOMAIN, TAG, 'scanFavoriteDevices: skip %{public}s:%{public}d (timeout/error)', fav.ip, fav.port);
      }
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
  ourDeviceType: string = 'mobile'
): Promise<void> {
  let netInfo = getLocalNetworkInfo();
  if (netInfo.ip === '0.0.0.0') {
    hilog.error(DOMAIN, TAG, 'scanSubnetHttp: no network, skip');
    return;
  }
  let targets = buildIpRange(netInfo.ip, netInfo.prefixLength);
  if (targets.length === 0) {
    return;
  }
  let registerBody = JSON.stringify({
    'alias': ourAlias,
    'version': '2.1',
    'deviceModel': ourDeviceModel,
    'deviceType': ourDeviceType,
    'fingerprint': ourFingerprint,
    'port': MULTICAST_PORT,
    'protocol': ourProtocol,
    'download': false,
    'announce': true,
    'announcement': true
  });
  let skipCert = deviceInfo.sdkApiVersion >= 18;
  hilog.error(DOMAIN, TAG, 'scanSubnetHttp: scanning %{public}d IPs from %{public}s/%{public}s protocol=%{public}s skipCert=%{public}s',
    targets.length, netInfo.ip, netInfo.prefixLength, ourProtocol, skipCert.toString());
  let completed = 0;
  let found = 0;
  let index = 0;
  let worker = async (): Promise<void> => {
    while (index < targets.length) {
      let targetIp = targets[index++];
      let protocolsToTry: Array<string> = ['https', 'http'];
      let foundThisTarget = false;
      for (let pi = 0; pi < protocolsToTry.length && !foundThisTarget; pi++) {
        let proto = protocolsToTry[pi];
        let url = proto + '://' + targetIp + ':' + MULTICAST_PORT +
          '/api/localsend/v2/register';
        try {
          let httpRequest = http.createHttp();
          let isHttps = proto === 'https';
          let opts: http.HttpRequestOptions = {
            method: http.RequestMethod.POST,
            connectTimeout: isHttps ? 2000 : 800,
            readTimeout: isHttps ? 2000 : 800,
            header: { 'Content-Type': 'application/json' },
            extraData: registerBody
          };
          if (skipCert && isHttps) {
            opts.remoteValidation = 'skip' as http.RemoteValidation;
          }
          await new Promise<void>((resolve) => {
            httpRequest.request(url, opts).then((resp: http.HttpResponse) => {
              if (resp.responseCode === 200 && resp.result !== undefined) {
                try {
                  let data = JSON.parse(resp.result as string) as Record<string, Object>;
                  let respAlias = data['alias'];
                  let respFp = data['fingerprint'];
                  if (respAlias !== undefined && respAlias !== null &&
                      respFp !== undefined && respFp !== null &&
                      respFp !== ourFingerprint) {
                    let respVersion = data['version'] !== undefined ? data['version'] as string : '2.0';
                    let respModel = data['deviceModel'] !== undefined ? data['deviceModel'] as string : '';
                    let respType = data['deviceType'] !== undefined ? data['deviceType'] as string : 'desktop';
                    let respProtocol = data['protocol'] !== undefined ? data['protocol'] as string : 'https';
                    onDeviceFound(respAlias as string, targetIp, MULTICAST_PORT,
                      respFp as string, respVersion, respModel, respType, respProtocol);
                    found++;
                    foundThisTarget = true;
                    hilog.error(DOMAIN, TAG, 'scanSubnetHttp: FOUND %{public}s at %{public}s proto=%{public}s',
                      respAlias as string, targetIp, proto);
                  }
                } catch (_e) {
                }
              }
            }).catch((e: Error) => {
              if (pi === 0) {
                hilog.error(DOMAIN, TAG, 'scanSubnetHttp: %{public}s %{public}s err=%{public}s',
                  proto, targetIp, e.message);
              }
            }).finally(() => {
              httpRequest.destroy();
              resolve();
            });
          });
        } catch (_e) {
        }
      }
      completed++;
    }
  };
  let concurrency = 50;
  if (concurrency > targets.length) {
    concurrency = targets.length;
  }
  let workers: Array<Promise<void>> = [];
  for (let i = 0; i < concurrency; i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  hilog.error(DOMAIN, TAG, 'scanSubnetHttp: done %{public}d/%{public}d found=%{public}d',
    completed, targets.length, found);
}