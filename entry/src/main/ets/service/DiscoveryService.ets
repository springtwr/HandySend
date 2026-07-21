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
  protocol: string = 'https'
): Promise<void> {
  if (running) {
    hilog.error(DOMAIN, TAG, 'startDiscovery: already running, skip');
    return;
  }
  localAlias = alias;
  localFingerprint = fingerprint;
  localProtocol = protocol;
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

  // addMembership is REQUIRED for receiving multicast datagrams — failure is fatal
  let groupAddr: socket.NetAddress = { address: MULTICAST_GROUP, port: MULTICAST_PORT };
  try {
    await msock.addMembership(groupAddr);
    hilog.error(DOMAIN, TAG, 'STEP5 addMembership OK %{public}s', MULTICAST_GROUP);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'STEP5 addMembership FAILED: %{public}s', JSON.stringify(e));
    throw new Error('addMembership failed — cannot receive multicast: ' + JSON.stringify(e));
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
  hilog.error(DOMAIN, TAG, 'Discovery STARTED on 0.0.0.0:%{public}d / %{public}s:%{public}d',
    MULTICAST_PORT, MULTICAST_GROUP, MULTICAST_PORT);

  // Fire-and-forget HTTP subnet scan (multicast fallback, §3.2)
  scanSubnetHttp(onDeviceFound, alias, fingerprint, protocol);

  // Send 3 announces at 100/500/2000ms per LocalSend protocol spec
  setTimeout(() => {
    sendAnnounceNow(localAlias, localFingerprint, protocol).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'announce1 failed: %{public}s', JSON.stringify(e));
    });
  }, 100);
  setTimeout(() => {
    sendAnnounceNow(localAlias, localFingerprint, protocol).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'announce2 failed: %{public}s', JSON.stringify(e));
    });
  }, 500);
  setTimeout(() => {
    sendAnnounceNow(localAlias, localFingerprint, protocol).catch((e: Object) => {
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
    // If peer is announcing, respond with TCP /register AND always send UDP announce back.
    // TCP register tells the specific peer about us; UDP announce makes us visible to ALL peers.
    // When other devices refresh, they clear their list and listen for announces — we must re-announce.
    if (announce) {
      tryTcpRegister(data.remoteInfo.address, data.remoteInfo.port,
        localAlias, localFingerprint, localProtocol).then(() => {
        sendAnnounceNow(localAlias, localFingerprint, localProtocol).catch((e: Object) => {
          hilog.error(DOMAIN, TAG, 'UDP announce after register failed: %{public}s', JSON.stringify(e));
        });
      }).catch(() => {
        sendAnnounceNow(localAlias, localFingerprint, localProtocol).catch((e: Object) => {
          hilog.error(DOMAIN, TAG, 'UDP announce fallback failed: %{public}s', JSON.stringify(e));
        });
      });
    }
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'handleMessage failed: %{public}s (text=%{public}s)',
      JSON.stringify(e), text.substring(0, Math.min(text.length, 200)));
  }
}

export async function sendAnnounceNow(alias: string, fingerprint: string, protocol: string = 'https'): Promise<void> {
  if (msock === undefined) {
    hilog.error(DOMAIN, TAG, 'sendAnnounce: msock undefined');
    return;
  }
  let payload: Record<string, Object> = {
    'alias': alias,
    'version': '2.1',
    'deviceModel': '',
    'deviceType': 'mobile',
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
  ourProtocol: string
): Promise<void> {
  let body: string = JSON.stringify({
    'alias': ourAlias,
    'version': '2.1',
    'deviceModel': '',
    'deviceType': 'mobile',
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

// ── HTTP subnet scan (fallback when multicast is unavailable) ──
//
// Protocol §3.2: Send POST /api/localsend/v2/register to every IP
// in the local subnet. Devices that respond are added to our discovery list.
// Runs with 10 concurrent connections, 800ms per-request timeout.
// Cap scanning to at most /24 (254 IPs) to avoid unreasonable delays.

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

export async function scanSubnetHttp(
  onDeviceFound: (alias: string, ip: string, port: number,
    fingerprint: string, version: string, deviceModel: string,
    deviceType: string, protocol: string) => void,
  ourAlias: string,
  ourFingerprint: string,
  ourProtocol: string = 'https'
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
    'deviceModel': '',
    'deviceType': 'mobile',
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