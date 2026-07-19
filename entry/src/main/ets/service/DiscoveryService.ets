import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'LocalSend:Discovery';
const DOMAIN = 0x0001;

interface MulticastMessageEvent {
  message: ArrayBuffer
  remoteInfo: socket.SocketRemoteInfo
}

const MULTICAST_GROUP = '224.0.0.167';
const MULTICAST_PORT = 53317;

let msock: socket.MulticastSocket | undefined = undefined;
let running = false;
let localAlias = '';
let localFingerprint = '';
let decoder: util.TextDecoder | undefined = undefined;

export function isDiscoveryRunning(): boolean {
  return running;
}

export async function startDiscovery(
  alias: string,
  fingerprint: string,
  onDeviceFound: (alias: string, ip: string, port: number,
    fingerprint: string, version: string, deviceModel: string,
    deviceType: string, protocol: string) => void
): Promise<void> {
  if (running) {
    hilog.error(DOMAIN, TAG, 'startDiscovery: already running, skip');
    return;
  }
  localAlias = alias;
  localFingerprint = fingerprint;
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

  let groupAddr: socket.NetAddress = { address: MULTICAST_GROUP, port: MULTICAST_PORT };
  try {
    await msock.addMembership(groupAddr);
    hilog.error(DOMAIN, TAG, 'STEP4 addMembership OK %{public}s', MULTICAST_GROUP);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'STEP4 addMembership FAILED: %{public}s', JSON.stringify(e));
    // continue anyway — bind + recv may still work
  }

  try {
    await msock.setLoopbackMode(false);
    hilog.error(DOMAIN, TAG, 'STEP5 setLoopbackMode(false) OK');
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'STEP5 setLoopbackMode FAILED: %{public}s', JSON.stringify(e));
  }

  try {
    msock.on('message', (data: MulticastMessageEvent) => {
      handleMessage(data, onDeviceFound);
    });
    hilog.error(DOMAIN, TAG, 'STEP6 on(message) subscribed');
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'STEP6 on(message) FAILED: %{public}s', JSON.stringify(e));
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

  running = true;
  hilog.error(DOMAIN, TAG, 'Discovery STARTED on 0.0.0.0:%{public}d / %{public}s:%{public}d',
    MULTICAST_PORT, MULTICAST_GROUP, MULTICAST_PORT);

  // Send 3 announces at 0/100/500ms like official LocalSend
  await sendAnnounceNow(localAlias, localFingerprint).catch((e: Object) => {
    hilog.error(DOMAIN, TAG, 'announce1 failed: %{public}s', JSON.stringify(e));
  });
  setTimeout(() => {
    sendAnnounceNow(localAlias, localFingerprint).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'announce2 failed: %{public}s', JSON.stringify(e));
    });
  }, 100);
  setTimeout(() => {
    sendAnnounceNow(localAlias, localFingerprint).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'announce3 failed: %{public}s', JSON.stringify(e));
    });
  }, 500);
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
    hilog.error(DOMAIN, TAG, 'recv from %{public}s:%{public}d alias=%{public}s announce=%{public}s',
      data.remoteInfo.address, data.remoteInfo.port, alias, announce.toString());
    onDeviceFound(alias, data.remoteInfo.address, port, fgp, version,
      deviceModel, deviceType, protocol);
    // If peer is announcing, respond with our own announce so they discover us too
    if (announce) {
      sendAnnounceNow(localAlias, localFingerprint).catch((e: Object) => {
        hilog.error(DOMAIN, TAG, 'response announce failed: %{public}s', JSON.stringify(e));
      });
    }
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'handleMessage failed: %{public}s (text=%{public}s)',
      JSON.stringify(e), text.substring(0, Math.min(text.length, 200)));
  }
}

export async function sendAnnounceNow(alias: string, fingerprint: string): Promise<void> {
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
    'protocol': 'https',
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