/**
 * DemoTaskHistory.ets — 演示任务历史种子注入（仅演示分支存在）
 *
 * 在应用启动时（initDemoModule）把 DemoTaskData 的固定清单解析为终态历史条目，
 * 以固定 sessionId 逐条 upsert 写入既有任务历史存储：
 * 不经统一会话注册表、协议适配器与进度推进器，不创建真实会话、不启动定时器。
 * 固定标识 upsert 天然幂等：重复启动不产生重复条目，清除历史后重启即自动重建。
 */

import { util } from '@kit.ArkTS';
import { DiscoveredDevice, NetworkInterface } from '../../model/Types';
import {
  SessionDataFlow,
  SessionEventKind,
  SessionFileStage,
  SessionHistoryOutcome,
  SessionPeer,
  SessionTimelineEvent
} from '../../model/transfer/TransferSession';
import {
  SESSION_HISTORY_SCHEMA_VERSION,
  SessionHistoryEntry,
  SessionHistoryFileEntry,
  boundTimeline,
  upsertHistory
} from '../../model/transfer/SessionHistory';
import { sessionHistoryStore } from '../transfer/SessionHistoryStore';
import { getDemoDevices } from './DemoDevices';
import {
  DemoFileSpec,
  DEMO_RECEIVE_FILES,
  DEMO_RECEIVE_TEXT,
  DEMO_SEND_FILES,
  DEMO_SEND_TEXT,
  DEMO_TEXT_FILE_NAME
} from './DemoData';
import { writeDemoTextFile } from './DemoFileWriter';
import { getDeviceAlias } from '../repository/DeviceRepository';
import { getLocalInterfaces } from '../repository/AppCore';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import {
  DemoTaskFileSource,
  DemoTaskSource,
  DemoTaskSpec,
  DEMO_TASK_CATALOG,
  DEMO_WEB_PEER
} from './DemoTaskData';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:DemoTaskHistory', '演示任务历史');

// MTA 单聚合文件条目标识（与真实 MTA 接收会话口径一致）
const MTA_AGGREGATE_FILE_ID: string = 'mta-0';

// 文本文件 MIME 类型
const TEXT_MIME: string = 'text/plain';

// web 网页下载协议键（协议会话标识置空，对齐真实 WebDownloadAdapter）
const WEB_DOWNLOAD_KEY: string = 'web-download';

/** 本机标识快照（与注册表 createSession 同源口径） */
interface DemoLocalIdentity {
  alias: string
  ip: string
  interfaceName: string
}

/**
 * 幂等注入演示任务历史：每次启动执行一次，按固定清单逐条 upsert。
 * 启动时无订阅者，无需发布变更通知（任务中心挂载时经既有读取路径自然可见）。
 *
 * 清除与重建：本函数不与既有「清除任务历史」逻辑耦合——清除动作清空存储后，
 * 下一次启动本函数即按固定清单重新 upsert，故「清除后重启重建」自动成立；
 * 同一次运行内清除后不立即重建（符合 spec 的边界约定）。
 */
export function seedDemoTaskHistory(): void {
  let base: number = Date.now();
  let local: DemoLocalIdentity = resolveLocalIdentity();
  let entries: Array<SessionHistoryEntry> = sessionHistoryStore.load();
  for (let i = 0; i < DEMO_TASK_CATALOG.length; i++) {
    let entry: SessionHistoryEntry = buildDemoHistoryEntry(DEMO_TASK_CATALOG[i], base, local);
    entries = upsertHistory(entries, entry);
  }
  sessionHistoryStore.persist(entries);
  logger.info('演示任务历史已注入 条数=' + DEMO_TASK_CATALOG.length);
}

// ── 本机标识 ──

/** 采集本机标识：昵称取设备仓库；IP/网卡取默认网卡（优先 isDefault 且有 IP，其次首个有 IP） */
function resolveLocalIdentity(): DemoLocalIdentity {
  let iface: NetworkInterface | undefined = defaultLocalInterface();
  let identity: DemoLocalIdentity = {
    alias: getDeviceAlias(),
    ip: iface !== undefined ? iface.ip : '',
    interfaceName: iface !== undefined ? iface.name : ''
  };
  return identity;
}

/** 默认网卡（与注册表同口径：优先 isDefault 且有 IP，其次首个有 IP；缺失返回 undefined） */
function defaultLocalInterface(): NetworkInterface | undefined {
  let list: Array<NetworkInterface> = getLocalInterfaces();
  for (let i = 0; i < list.length; i++) {
    if (list[i].isDefault && list[i].ip.length > 0) {
      return list[i];
    }
  }
  for (let i = 0; i < list.length; i++) {
    if (list[i].ip.length > 0) {
      return list[i];
    }
  }
  return undefined;
}

// ── 清单条目 → 历史条目 ──

/** 由清单条目构建终态历史条目（时间由固定偏移派生，聚合字段由逐文件清单重建） */
function buildDemoHistoryEntry(spec: DemoTaskSpec, base: number,
  local: DemoLocalIdentity): SessionHistoryEntry {
  let startedAt: number = base - spec.startOffsetMs;
  let finishedAt: number = startedAt + spec.durationMs;
  let files: Array<SessionHistoryFileEntry> = buildFiles(spec);
  let peer: SessionPeer = resolvePeer(spec);
  let entry: SessionHistoryEntry = {
    sessionId: spec.sessionId,
    protocolKey: spec.protocolKey,
    // 协议会话标识仅诊断用：网页下载协议层无会话标识（对齐真实适配器），其余取固定派生值
    protocolSessionId: spec.protocolKey === WEB_DOWNLOAD_KEY ? '' : spec.sessionId,
    dataFlow: spec.dataFlow,
    initiatedBy: spec.initiatedBy,
    peerName: peer.displayName,
    peerFingerprint: peer.fingerprint ?? '',
    peerIp: peer.ip ?? '',
    peerDeviceType: peer.deviceType ?? '',
    peerDeviceModel: peer.badges.length > 0 ? peer.badges[0] : '',
    files: files,
    fileCount: files.length,
    totalBytes: sumEntryBytes(files),
    outcome: spec.outcome,
    errorMessage: spec.errorMessage,
    errorCode: spec.errorCode,
    startedAt: startedAt,
    finishedAt: finishedAt,
    durationMs: spec.durationMs,
    averageSpeedBps: spec.averageSpeedBps,
    peakSpeedBps: spec.peakSpeedBps,
    timeline: buildTimeline(spec, startedAt, finishedAt),
    localAlias: local.alias,
    localIp: local.ip,
    localInterfaceName: local.interfaceName,
    schemaVersion: SESSION_HISTORY_SCHEMA_VERSION
  };
  // MTA 品牌标识：仅互传来源写入（驱动详情页设备卡品牌图标）
  if (peer.mtaBrandId !== undefined) {
    entry.peerMtaBrandId = peer.mtaBrandId;
  }
  return entry;
}

// ── 对端解析 ──

/** 解析对端标识：本地/互传复用虚拟设备字段，web 取固定对端常量 */
function resolvePeer(spec: DemoTaskSpec): SessionPeer {
  if (spec.source === DemoTaskSource.web) {
    let webPeer: SessionPeer = {
      displayName: DEMO_WEB_PEER.ip,
      ip: DEMO_WEB_PEER.ip,
      deviceType: 'web',
      badges: []
    };
    return webPeer;
  }
  let protocol: string = spec.source === DemoTaskSource.mta ? 'mta' : 'localsend';
  let device: DiscoveredDevice | undefined = findDemoDevice(protocol, spec.peerRef);
  if (device === undefined) {
    let fallback: SessionPeer = { displayName: spec.peerRef, badges: [] };
    return fallback;
  }
  if (spec.source === DemoTaskSource.mta) {
    // 互传形状：无 IP、无型号徽标，指纹取 BLE 地址，携带品牌标识
    let mtaPeer: SessionPeer = {
      displayName: device.alias,
      deviceType: device.deviceType,
      fingerprint: device.mtaBleAddress ?? '',
      badges: [],
      mtaBrandId: device.mtaBrandId
    };
    return mtaPeer;
  }
  // 局域网形状：昵称/IP/指纹/设备类型，型号徽标取设备型号
  let localPeer: SessionPeer = {
    displayName: device.alias,
    ip: device.ip,
    fingerprint: device.fingerprint,
    deviceType: device.deviceType,
    badges: device.deviceModel.length > 0 ? [device.deviceModel] : []
  };
  return localPeer;
}

/** 按来源协议 + 昵称查演示虚拟设备（同协议内昵称唯一） */
function findDemoDevice(protocol: string, alias: string): DiscoveredDevice | undefined {
  let devices: Array<DiscoveredDevice> = getDemoDevices(protocol);
  for (let i = 0; i < devices.length; i++) {
    if (devices[i].alias === alias) {
      return devices[i];
    }
  }
  return undefined;
}

// ── 文件清单与阶段 ──

/** 由清单来源构建逐文件条目（文本单条、互传单聚合、收发多文件） */
function buildFiles(spec: DemoTaskSpec): Array<SessionHistoryFileEntry> {
  if (spec.fileSource === DemoTaskFileSource.text) {
    return buildTextFiles(spec);
  }
  if (spec.fileSource === DemoTaskFileSource.mtaAggregate) {
    return buildMtaAggregateFiles(spec);
  }
  let specs: Array<DemoFileSpec> = spec.fileSource === DemoTaskFileSource.send ?
  DEMO_SEND_FILES : DEMO_RECEIVE_FILES;
  let files: Array<SessionHistoryFileEntry> = [];
  for (let i = 0; i < specs.length; i++) {
    files.push(buildListFileEntry(spec, specs[i], i));
  }
  return files;
}

/** 多文件清单条目（收/发） */
function buildListFileEntry(spec: DemoTaskSpec, file: DemoFileSpec,
  index: number): SessionHistoryFileEntry {
  let entry: SessionHistoryFileEntry = {
    fileId: `${spec.sessionId}-f${index}`,
    fileName: file.fileName,
    fileType: file.fileType,
    size: file.sizeBytes,
    stage: stageForIndex(spec, index),
    checksum: '',
    path: ''
  };
  return entry;
}

/** 文本条目：单条 text/plain，size 取文本 UTF-8 字节数，落盘路径回填供详情内联预览 */
function buildTextFiles(spec: DemoTaskSpec): Array<SessionHistoryFileEntry> {
  let content: string = textContentOf(spec);
  let path: string = writeDemoTextFile(DEMO_TEXT_FILE_NAME, content);
  let entry: SessionHistoryFileEntry = {
    fileId: `${spec.sessionId}-text`,
    fileName: DEMO_TEXT_FILE_NAME,
    fileType: TEXT_MIME,
    size: utf8ByteLength(content),
    stage: stageForIndex(spec, 0),
    checksum: '',
    path: path
  };
  return [entry];
}

/** 互传接收单聚合条目：主文件名承载展示，大小取收清单总量（对齐真实 MTA 单条目形状） */
function buildMtaAggregateFiles(spec: DemoTaskSpec): Array<SessionHistoryFileEntry> {
  let head: DemoFileSpec = DEMO_RECEIVE_FILES[0];
  let entry: SessionHistoryFileEntry = {
    fileId: MTA_AGGREGATE_FILE_ID,
    fileName: head.fileName,
    fileType: head.fileType,
    size: sumFileBytes(DEMO_RECEIVE_FILES),
    stage: stageForIndex(spec, 0),
    checksum: '',
    path: ''
  };
  return [entry];
}

/** 文本内容：收方向用收文本、发方向用发文本 */
function textContentOf(spec: DemoTaskSpec): string {
  return spec.dataFlow === SessionDataFlow.inbound ? DEMO_RECEIVE_TEXT : DEMO_SEND_TEXT;
}

/**
 * 文件阶段规则：
 * - 成功：全部 completed；
 * - 部分失败：仅 failedIndex 条 failed，其余 completed；
 * - 失败：前 completedCount 条 completed，其余 failed；
 * - 取消：前 completedCount 条 completed，其余 cancelled。
 */
function stageForIndex(spec: DemoTaskSpec, index: number): SessionFileStage {
  if (spec.outcome === SessionHistoryOutcome.partiallyFailed) {
    return index === spec.failedIndex ? SessionFileStage.failed : SessionFileStage.completed;
  }
  if (spec.outcome === SessionHistoryOutcome.failed) {
    return index < spec.completedCount ? SessionFileStage.completed : SessionFileStage.failed;
  }
  if (spec.outcome === SessionHistoryOutcome.cancelled) {
    return index < spec.completedCount ? SessionFileStage.completed : SessionFileStage.cancelled;
  }
  return SessionFileStage.completed;
}

// ── 时间线 ──

/** 时间线事件：恒有 created/started；终态按结果追加（部分失败同时含 failed 与 completed） */
function buildTimeline(spec: DemoTaskSpec, startedAt: number,
  finishedAt: number): Array<SessionTimelineEvent> {
  let events: Array<SessionTimelineEvent> = [];
  events.push({
    kind: SessionEventKind.created,
    timestamp: startedAt,
    detail: spec.protocolKey,
    sessionId: spec.sessionId
  });
  events.push({
    kind: SessionEventKind.started,
    timestamp: startedAt,
    sessionId: spec.sessionId
  });
  if (spec.outcome === SessionHistoryOutcome.succeeded) {
    events.push({ kind: SessionEventKind.completed, timestamp: finishedAt, sessionId: spec.sessionId });
  } else if (spec.outcome === SessionHistoryOutcome.partiallyFailed) {
    events.push({
      kind: SessionEventKind.failed,
      timestamp: finishedAt,
      detail: spec.errorMessage,
      sessionId: spec.sessionId
    });
    events.push({ kind: SessionEventKind.completed, timestamp: finishedAt, sessionId: spec.sessionId });
  } else if (spec.outcome === SessionHistoryOutcome.failed) {
    events.push({
      kind: SessionEventKind.failed,
      timestamp: finishedAt,
      detail: spec.errorMessage,
      sessionId: spec.sessionId
    });
  } else if (spec.outcome === SessionHistoryOutcome.cancelled) {
    events.push({ kind: SessionEventKind.cancelled, timestamp: finishedAt, sessionId: spec.sessionId });
  }
  return boundTimeline(events);
}

// ── 聚合辅助 ──

/** 演示清单总字节 */
function sumFileBytes(specs: Array<DemoFileSpec>): number {
  let total: number = 0;
  for (let i = 0; i < specs.length; i++) {
    total += specs[i].sizeBytes;
  }
  return total;
}

/** 逐文件条目总字节（与 sanitizeHistory 重建口径一致） */
function sumEntryBytes(files: Array<SessionHistoryFileEntry>): number {
  let total: number = 0;
  for (let i = 0; i < files.length; i++) {
    total += files[i].size;
  }
  return total;
}

/** 文本 UTF-8 字节数 */
function utf8ByteLength(text: string): number {
  return new util.TextEncoder().encodeInto(text).length;
}
