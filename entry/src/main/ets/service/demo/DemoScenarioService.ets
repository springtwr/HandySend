/**
 * DemoScenarioService.ets — 演示场景编排与进度推进（仅演示分支存在）
 *
 * 四类演示场景（收文件 / 收文本 / 发文件 / 发文本）完全复用既有协议适配器
 * （localsend-receive / localsend-send / mta-receive / mta-send）与会话注册表：
 * 演示会话与真实会话逐像素一致地经任务中心、详情页、后台通知渲染。
 *
 * 动作接管方式：装饰适配器命令方法（confirm / decline / cancel / retry）——
 * 注册表分发命令时先经装饰器判定演示会话：演示会话走模拟推进逻辑，
 * 真实会话透传原实现，真实链路零改动。相比包装接收仓库的 invoker 注册，
 * 适配器方法装饰与注册顺序无关（invoker 会被接收仓库在模块加载时覆盖）。
 *
 * 进度推进器：每会话一个定时器（1s tick 约 60MB），多会话并发、会话 id 唯一；
 * 待确认演示会话每 45s 续期一次，保证三语言截图期间画面不超时消失。
 */

import { common } from '@kit.AbilityKit';
import { DiscoveredDevice } from '../../model/Types';
import { SendFileItem } from '../../model/Types';
import {
  isTerminalStage,
  SessionFileDescriptor,
  SessionStage
} from '../../model/transfer/TransferSession';
import {
  findByProtocol,
  finish,
  getSession,
  querySessions,
  replaceTerminalSessionsForPeer,
  updateSessionFilePath
} from '../transfer/TransferSessionRegistry';
import { getAdapter } from '../transfer/adapters/SessionAdapter';
import {
  ensureReceiveSession,
  finishLocalReceiveSession,
  LOCAL_RECEIVE_KEY,
  markReceiveActive,
  resetLocalReceivePendingTimeout,
  updateReceiveProgress,
  updateReceiveSessionFilePath
} from '../transfer/adapters/LocalSendReceiveAdapter';
import {
  beginLocalSendSession,
  finishLocalSend,
  LOCAL_SEND_KEY,
  updateLocalSendProgress
} from '../transfer/adapters/LocalSendSendAdapter';
import {
  handleMtaReceiveState,
  MTA_RECEIVE_KEY,
  notifyMtaTextSaved,
  resetMtaPendingTimeout
} from '../transfer/adapters/MtaReceiveAdapter';
import {
  beginMtaSendSession,
  finishMtaSendSession,
  MTA_SEND_KEY,
  MtaSendTerminal,
  updateMtaSendProgress
} from '../transfer/adapters/MtaSendAdapter';
import {
  DownloadProgress,
  ReceiveRequest,
  ReceiverStage,
  ReceiverState
} from '../../model/mta/MtaProtocolModels';
import { MtaSenderStage } from '../../model/mta/MtaSendModels';
import { mtaSendStageLabel } from '../../model/mta/MtaMainModels';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { isDemoDevice } from './DemoDevices';
import {
  appendReceiveHistory,
  DemoWrittenFile,
  initDemoFileWriter,
  writeDemoFiles,
  writeDemoTextFile
} from './DemoFileWriter';
import {
  DemoFileKind,
  DEMO_PENDING_RENEW_INTERVAL_MS,
  DEMO_PROGRESS_PLAN,
  DEMO_RECEIVE_FILES,
  DEMO_RECEIVE_TEXT,
  DEMO_SEND_FILES,
  DEMO_SEND_TEXT,
  DEMO_TEXT_FILE_NAME,
  DEMO_TEXT_SEND_DURATION_MS,
  DemoFileSpec,
  DemoScenarioType
} from './DemoData';
import { seedDemoTaskHistory } from './DemoTaskHistory';
import { util } from '@kit.ArkTS';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:DemoScenario', '演示场景');

// MTA 接收文本会话的固定文件条目标识（与 MtaReceiveAdapter 内部约定一致）
const MTA_TEXT_FILE_ID: string = 'mta-0';

/** 演示会话记录（推进器与装饰器按统一会话标识索引） */
interface DemoSessionRecord {
  unifiedId: string
  /** 会话来源协议：'localsend' | 'mta' */
  protocol: string
  /** 场景类别 */
  scenario: DemoScenarioType
  /** LocalSend 接收会话的协议会话标识（发送/MTA 会话为空串） */
  protocolSessionId: string
  /** 演示文件清单（文本场景为单条） */
  specs: Array<DemoFileSpec>
  /** 收方向的对端昵称（接收历史用） */
  senderAlias: string
  /** MTA 接收会话的请求快照（喂进度状态用） */
  mtaRequest?: ReceiveRequest
}

/** 演示会话表（统一会话标识 → 记录；终态后随推进器停止移除） */
const records: Map<string, DemoSessionRecord> = new Map();

/** 推进器定时器（统一会话标识 → timer id） */
const drivers: Map<string, number> = new Map();

/** 待确认续期定时器（initDemoModule 启动，常驻） */
let renewalTimer: number = -1;

/** 装饰器安装标志（幂等） */
let installed: boolean = false;

/** 演示会话序号（保证协议会话标识唯一） */
let sessionSeq: number = 0;

// ── 初始化与续期 ──

/**
 * 演示模块初始化（应用启动时调用一次，幂等）：
 * 解析落盘目录、安装适配器命令装饰、启动待确认续期定时器。
 */
export function initDemoModule(context: common.Context): void {
  initDemoFileWriter(context);
  // 任务中心模拟任务：固定清单幂等注入既有任务历史存储（每次启动执行，重启不重复、清除后重启重建）
  seedDemoTaskHistory();
  if (installed) {
    return;
  }
  installed = true;
  installReceiveDecorators();
  installSendDecorators();
  renewalTimer = setInterval(renewPendingSessions, DEMO_PENDING_RENEW_INTERVAL_MS);
  logger.info('演示模块已初始化');
}

/** 待确认续期：演示待确认会话逐个重置既有 60s 超时（会话不在待确认阶段时重置函数自动空操作） */
function renewPendingSessions(): void {
  records.forEach((record: DemoSessionRecord) => {
    let session = getSession(record.unifiedId);
    if (session === undefined || session.stage !== SessionStage.awaitingConfirmation) {
      return;
    }
    if (record.protocol === 'localsend' && record.protocolSessionId.length > 0) {
      resetLocalReceivePendingTimeout(record.protocolSessionId);
    } else if (record.protocol === 'mta') {
      resetMtaPendingTimeout(record.unifiedId);
    }
  });
}

// ── 场景触发 ──

/**
 * 触发一个模拟场景：按设备来源协议与场景类别分派到对应适配器路径。
 * MTA 接收受单会话约束：已有进行中的 MTA 接收会话时拒绝触发。
 */
export function triggerScenario(device: DiscoveredDevice, scenario: DemoScenarioType): void {
  if (!isDemoDevice(device.fingerprint)) {
    logger.warn('非演示设备触发场景，忽略: ' + device.alias);
    return;
  }
  let isMta = device.protocol === 'mta';
  switch (scenario) {
    case DemoScenarioType.receiveFiles:
      if (isMta) {
        startMtaReceive(device, false);
      } else {
        startLocalReceive(device, false);
      }
      break;
    case DemoScenarioType.receiveText:
      if (isMta) {
        startMtaReceive(device, true);
      } else {
        startLocalReceive(device, true);
      }
      break;
    case DemoScenarioType.sendFiles:
      if (isMta) {
        startMtaSend(device, false);
      } else {
        startLocalSend(device, false);
      }
      break;
    case DemoScenarioType.sendText:
      if (isMta) {
        startMtaSend(device, true);
      } else {
        startLocalSend(device, true);
      }
      break;
    default:
      break;
  }
}

// ── LocalSend 接收（收文件 / 收文本） ──

/** 创建 LocalSend 待确认接收会话（文本场景为单条文本条目并携带预览内容） */
function startLocalReceive(device: DiscoveredDevice, isText: boolean): void {
  let specs: Array<DemoFileSpec> = isText ? [buildTextSpec('demo-ls-recv-text-0')] :
  DEMO_RECEIVE_FILES.slice();
  let protocolSessionId = `demo-ls-recv-${Date.now()}-${sessionSeq}`;
  sessionSeq++;
  let descriptors: Array<SessionFileDescriptor> = [];
  for (let i = 0; i < specs.length; i++) {
    descriptors.push({
      fileId: specs[i].fileId,
      fileName: specs[i].fileName,
      fileType: specs[i].fileType,
      totalBytes: specs[i].sizeBytes
    });
  }
  let textPreview = isText ? DEMO_RECEIVE_TEXT : '';
  let unifiedId = ensureReceiveSession(protocolSessionId, device.alias, device.ip,
    device.fingerprint, device.deviceType, device.deviceModel, descriptors, true, textPreview);
  records.set(unifiedId, {
    unifiedId: unifiedId,
    protocol: 'localsend',
    scenario: isText ? DemoScenarioType.receiveText : DemoScenarioType.receiveFiles,
    protocolSessionId: protocolSessionId,
    specs: specs,
    senderAlias: device.alias
  });
  logger.info(`LocalSend 演示接收会话已创建 统一标识=${unifiedId} 文本=${isText}`);
}

/** 演示确认（LocalSend 接收）：文本场景落盘收尾，文件场景启动字节推进器 */
function demoConfirmLocalReceive(record: DemoSessionRecord): void {
  markReceiveActive(record.protocolSessionId);
  if (record.scenario === DemoScenarioType.receiveText) {
    finishLocalReceiveText(record);
    return;
  }
  startBytesDriver(record, (record: DemoSessionRecord, fileId: string, bytes: number,
    total: number): void => {
    updateReceiveProgress(record.protocolSessionId, fileId, bytes, total);
  }, (record: DemoSessionRecord): void => {
    finishLocalReceiveFiles(record);
  });
}

/** LocalSend 演示收文本收尾：文本落盘 → 回填路径 → 写历史 → 成功终结 */
function finishLocalReceiveText(record: DemoSessionRecord): void {
  let spec = record.specs[0];
  let path = writeDemoTextFile(spec.fileName, DEMO_RECEIVE_TEXT);
  let written: Array<DemoWrittenFile> = [];
  if (path.length > 0) {
    updateReceiveSessionFilePath(record.protocolSessionId, spec.fileId, path);
    written.push({ fileId: spec.fileId, fileName: extractFileName(path), path: path });
  }
  appendReceiveHistory(record.specs, written, record.senderAlias, true, DEMO_RECEIVE_TEXT);
  finishLocalReceiveSession(record.protocolSessionId, SessionStage.succeeded);
  removeRecord(record.unifiedId);
}

/** LocalSend 演示收文件收尾：占位文件 → 回填路径 → 写历史 → 成功终结 */
function finishLocalReceiveFiles(record: DemoSessionRecord): void {
  let written = writeDemoFiles(record.specs);
  for (let i = 0; i < written.length; i++) {
    updateReceiveSessionFilePath(record.protocolSessionId, written[i].fileId, written[i].path);
  }
  appendReceiveHistory(record.specs, written, record.senderAlias, false);
  finishLocalReceiveSession(record.protocolSessionId, SessionStage.succeeded);
  removeRecord(record.unifiedId);
}

// ── MTA 接收（收文件 / 收文本） ──

/** 创建 MTA 待确认接收会话（喂 REQUEST_RECEIVED 状态；单会话约束由适配器与前置守卫共同保证） */
function startMtaReceive(device: DiscoveredDevice, isText: boolean): void {
  // 前置守卫：已有进行中（非终态）MTA 接收会话时拒绝触发
  let active = querySessions({ protocolKey: MTA_RECEIVE_KEY });
  for (let i = 0; i < active.length; i++) {
    if (!isTerminalStage(active[i].stage)) {
      logger.warn('已有进行中的 MTA 接收会话，拒绝触发演示场景');
      return;
    }
  }
  let specs: Array<DemoFileSpec> = isText ? [buildTextSpec(MTA_TEXT_FILE_ID)] :
  [buildMtaAggregateSpec(DEMO_RECEIVE_FILES)];
  let taskId = `demo-mta-recv-${Date.now()}-${sessionSeq}`;
  sessionSeq++;
  let totalBytes = sumSpecBytes(specs);
  // 同对端终态残留清理（触发适配器 dispose 释放其单会话占用）
  replaceTerminalSessionsForPeer({ ip: '', name: device.alias });
  let request = new ReceiveRequest();
  request.taskId = taskId;
  request.senderId = 'demo-mta-sender';
  request.senderName = device.alias;
  request.fileName = specs[0].fileName;
  request.fileCount = isText ? 1 : DEMO_RECEIVE_FILES.length;
  request.totalSize = totalBytes;
  request.textContent = isText ? DEMO_RECEIVE_TEXT : '';
  let state = new ReceiverState();
  state.stage = ReceiverStage.REQUEST_RECEIVED;
  state.receiveRequest = request;
  handleMtaReceiveState(state);
  let session = findByProtocol(MTA_RECEIVE_KEY, taskId);
  if (session === undefined) {
    logger.warn('MTA 演示接收会话创建失败');
    return;
  }
  records.set(session.id, {
    unifiedId: session.id,
    protocol: 'mta',
    scenario: isText ? DemoScenarioType.receiveText : DemoScenarioType.receiveFiles,
    protocolSessionId: '',
    specs: specs,
    senderAlias: device.alias,
    mtaRequest: request
  });
  logger.info(`MTA 演示接收会话已创建 统一标识=${session.id} 文本=${isText}`);
}

/** 演示确认（MTA 接收）：文本场景落盘收尾，文件场景喂接收中状态序列 */
function demoConfirmMtaReceive(record: DemoSessionRecord): void {
  if (record.scenario === DemoScenarioType.receiveText) {
    finishMtaReceiveText(record);
    return;
  }
  startBytesDriver(record, (record: DemoSessionRecord, _fileId: string, bytes: number,
    total: number): void => {
    feedMtaProgress(record, bytes, total);
  }, (record: DemoSessionRecord): void => {
    finishMtaReceiveFiles(record);
  });
}

/** 喂一帧 MTA 接收中状态（DOWNLOADING 阶段字节进度） */
function feedMtaProgress(record: DemoSessionRecord, bytes: number, total: number): void {
  let request = record.mtaRequest;
  if (request === undefined) {
    return;
  }
  let progress = new DownloadProgress();
  progress.receivedBytes = bytes;
  progress.totalBytes = total;
  let state = new ReceiverState();
  state.stage = ReceiverStage.DOWNLOADING;
  state.receiveRequest = request;
  state.progress = progress;
  handleMtaReceiveState(state);
}

/** MTA 演示收文本收尾：文本落盘 → 回填路径 → 写历史 → 成功终结（复刻适配器文本接受语义） */
function finishMtaReceiveText(record: DemoSessionRecord): void {
  let spec = record.specs[0];
  let path = writeDemoTextFile(spec.fileName, DEMO_RECEIVE_TEXT);
  let written: Array<DemoWrittenFile> = [];
  if (path.length > 0) {
    notifyMtaTextSaved(path);
    written.push({ fileId: spec.fileId, fileName: extractFileName(path), path: path });
  }
  appendReceiveHistory(record.specs, written, record.senderAlias, true, DEMO_RECEIVE_TEXT);
  finish(record.unifiedId, SessionStage.succeeded);
  removeRecord(record.unifiedId);
}

/** MTA 演示收文件收尾：占位文件 → 回填路径 → 写历史 → 喂完成状态（适配器内部终结会话） */
function finishMtaReceiveFiles(record: DemoSessionRecord): void {
  let written = writeDemoFiles(record.specs);
  for (let i = 0; i < written.length; i++) {
    updateSessionFilePath(record.unifiedId, MTA_TEXT_FILE_ID, written[i].path);
  }
  appendReceiveHistory(record.specs, written, record.senderAlias, false);
  let state = new ReceiverState();
  state.stage = ReceiverStage.COMPLETED;
  handleMtaReceiveState(state);
  removeRecord(record.unifiedId);
}

// ── LocalSend 发送（发文件 / 发文本） ──

/** 创建 LocalSend 进行中发送会话（直接 active；文本场景为单条文本条目并短暂推进） */
function startLocalSend(device: DiscoveredDevice, isText: boolean): void {
  if (isText) {
    startLocalSendText(device);
    return;
  }
  let specs = DEMO_SEND_FILES.slice();
  let files: Array<SendFileItem> = [];
  for (let i = 0; i < specs.length; i++) {
    files.push({
      fileId: specs[i].fileId,
      filePath: '',
      fileName: specs[i].fileName,
      fileType: specs[i].fileType,
      size: specs[i].sizeBytes
    });
  }
  let businessSessionId = `demo-ls-send-${Date.now()}-${sessionSeq}`;
  sessionSeq++;
  let unifiedId = beginLocalSendSession(businessSessionId, device, files);
  let record: DemoSessionRecord = {
    unifiedId: unifiedId,
    protocol: 'localsend',
    scenario: DemoScenarioType.sendFiles,
    protocolSessionId: '',
    specs: specs,
    senderAlias: device.alias
  };
  records.set(unifiedId, record);
  startBytesDriver(record,
    (record: DemoSessionRecord, fileId: string, bytes: number, total: number): void => {
      updateLocalSendProgress(record.unifiedId, fileId, bytes, total);
    }, (record: DemoSessionRecord): void => {
      finishLocalSend(record.unifiedId, true);
      removeRecord(record.unifiedId);
    });
  logger.info(`LocalSend 演示发送会话已创建 统一标识=${unifiedId}`);
}

/** LocalSend 演示发文本：单条文本条目（无字节进度口径），短暂进行中后成功 */
function startLocalSendText(device: DiscoveredDevice): void {
  let spec = buildTextSpec('demo-ls-send-text-0');
  let path = writeDemoTextFile(DEMO_TEXT_FILE_NAME, DEMO_SEND_TEXT);
  let files: Array<SendFileItem> = [{
    fileId: spec.fileId,
    filePath: path,
    fileName: spec.fileName,
    fileType: spec.fileType,
    size: spec.sizeBytes,
    preview: DEMO_SEND_TEXT
  }];
  let businessSessionId = `demo-ls-send-${Date.now()}-${sessionSeq}`;
  sessionSeq++;
  let unifiedId = beginLocalSendSession(businessSessionId, device, files);
  let record: DemoSessionRecord = {
    unifiedId: unifiedId,
    protocol: 'localsend',
    scenario: DemoScenarioType.sendText,
    protocolSessionId: '',
    specs: [spec],
    senderAlias: device.alias
  };
  records.set(unifiedId, record);
  scheduleTextFinish(record);
  logger.info(`LocalSend 演示文本发送会话已创建 统一标识=${unifiedId}`);
}

// ── MTA 发送（发文件 / 发文本） ──

/** 创建 MTA 进行中发送会话（直接 active；文件场景按清单顺序推进，文本场景短暂推进） */
function startMtaSend(device: DiscoveredDevice, isText: boolean): void {
  let specs: Array<DemoFileSpec> = isText ? [buildTextSpec('demo-mta-send-text-0')] :
  DEMO_SEND_FILES.slice();
  let descriptors: Array<SessionFileDescriptor> = [];
  for (let i = 0; i < specs.length; i++) {
    descriptors.push({
      fileId: specs[i].fileId,
      fileName: specs[i].fileName,
      fileType: specs[i].fileType,
      totalBytes: specs[i].sizeBytes,
      path: isText ? writeDemoTextFile(DEMO_TEXT_FILE_NAME, DEMO_SEND_TEXT) : ''
    });
  }
  let taskId = `demo-mta-send-${Date.now()}-${sessionSeq}`;
  sessionSeq++;
  let brandBadge = device.mtaBrandName !== undefined ? device.mtaBrandName : '';
  let unifiedId = beginMtaSendSession(taskId, device.alias, device.deviceType,
    device.deviceModel, brandBadge, descriptors,
    device.mtaBrandId !== undefined ? device.mtaBrandId : -1,
    device.mtaBleAddress !== undefined ? device.mtaBleAddress : '');
  let record: DemoSessionRecord = {
    unifiedId: unifiedId,
    protocol: 'mta',
    scenario: isText ? DemoScenarioType.sendText : DemoScenarioType.sendFiles,
    protocolSessionId: '',
    specs: specs,
    senderAlias: device.alias
  };
  records.set(unifiedId, record);
  if (isText) {
    // 文本场景：一帧进度后短暂进行中收尾
    updateMtaSendProgress(unifiedId, specs[0].sizeBytes, specs[0].sizeBytes,
      mtaSendStageLabel(MtaSenderStage.TRANSFERRING));
    scheduleTextFinish(record);
  } else {
    startBytesDriver(record, (record: DemoSessionRecord, _fileId: string, bytes: number,
      total: number): void => {
      updateMtaSendProgress(record.unifiedId, bytes, total,
        mtaSendStageLabel(MtaSenderStage.TRANSFERRING));
    }, (record: DemoSessionRecord): void => {
      finishMtaSendSession(record.unifiedId, MtaSendTerminal.success);
      removeRecord(record.unifiedId);
    });
  }
  logger.info(`MTA 演示发送会话已创建 统一标识=${unifiedId} 文本=${isText}`);
}

// ── 推进器 ──

/** 字节推进回调：按会话把 (fileId, bytes, total) 写入对应协议进度入口 */
type ProgressSink = (record: DemoSessionRecord, fileId: string, bytes: number, total: number) => void;

/** 推进完成回调：执行落盘/历史/终结等场景收尾 */
type CompletionSink = (record: DemoSessionRecord) => void;

/**
 * 启动字节推进器：每 tick 推进固定字节并按清单顺序逐文件分发；
 * 会话被取消/终结时自停；推进完成后执行收尾回调。
 */
function startBytesDriver(record: DemoSessionRecord, sink: ProgressSink, completion: CompletionSink): void {
  let totalBytes = sumSpecBytes(record.specs);
  let cursor = 0;
  let timer = setInterval((): void => {
    let session = getSession(record.unifiedId);
    if (session === undefined || isTerminalStage(session.stage)) {
      // 用户取消或会话已被终结：停止推进器并清理记录
      stopDriver(record.unifiedId);
      return;
    }
    cursor = Math.min(cursor + DEMO_PROGRESS_PLAN.bytesPerTick, totalBytes);
    distributeBytes(record.specs, cursor, sink, record);
    if (cursor >= totalBytes) {
      stopDriver(record.unifiedId);
      completion(record);
    }
  }, DEMO_PROGRESS_PLAN.tickIntervalMs);
  drivers.set(record.unifiedId, timer);
}

/** 停止推进器并移除会话记录 */
function stopDriver(unifiedId: string): void {
  let timer = drivers.get(unifiedId);
  if (timer !== undefined) {
    clearInterval(timer);
    drivers.delete(unifiedId);
  }
  removeRecord(unifiedId);
}

/** 移除演示会话记录（幂等） */
function removeRecord(unifiedId: string): void {
  records.delete(unifiedId);
}

/** 文本发送场景的短暂进行中收尾：时长到达且会话未终结时按成功收尾 */
function scheduleTextFinish(record: DemoSessionRecord): void {
  let timer = setTimeout((): void => {
    drivers.delete(record.unifiedId);
    let session = getSession(record.unifiedId);
    if (session === undefined || isTerminalStage(session.stage)) {
      removeRecord(record.unifiedId);
      return;
    }
    if (record.protocol === 'mta') {
      finishMtaSendSession(record.unifiedId, MtaSendTerminal.success);
    } else {
      finishLocalSend(record.unifiedId, true);
    }
    removeRecord(record.unifiedId);
  }, DEMO_TEXT_SEND_DURATION_MS);
  drivers.set(record.unifiedId, timer);
}

/** 游标式字节分发：按清单顺序依次填充各文件（已完成文件填满、当前文件填部分，与既有游标口径一致） */
function distributeBytes(specs: Array<DemoFileSpec>, cursor: number, sink: ProgressSink,
  record: DemoSessionRecord): void {
  let remaining = cursor;
  for (let i = 0; i < specs.length; i++) {
    let portion = Math.min(Math.max(remaining, 0), specs[i].sizeBytes);
    sink(record, specs[i].fileId, portion, specs[i].sizeBytes);
    remaining -= portion;
    if (remaining <= 0) {
      break;
    }
  }
}

// ── 演示数据辅助 ──

/** 构造文本演示条目（大小按 UTF-8 实际字节数；生成方式为内容文件） */
function buildTextSpec(fileId: string): DemoFileSpec {
  return {
    fileId: fileId,
    fileName: DEMO_TEXT_FILE_NAME,
    fileType: 'text/plain',
    sizeBytes: utf8ByteLength(DEMO_RECEIVE_TEXT),
    demoKind: DemoFileKind.text
  };
}

/** MTA 文件场景聚合条目（MTA 接收为单条目会话：主文件名承载展示，大小取清单总量） */
function buildMtaAggregateSpec(specs: Array<DemoFileSpec>): DemoFileSpec {
  return {
    fileId: MTA_TEXT_FILE_ID,
    fileName: specs[0].fileName,
    fileType: specs[0].fileType,
    sizeBytes: sumSpecBytes(specs),
    demoKind: specs[0].demoKind
  };
}

/** 清单总字节 */
function sumSpecBytes(specs: Array<DemoFileSpec>): number {
  let total = 0;
  for (let i = 0; i < specs.length; i++) {
    total += specs[i].sizeBytes;
  }
  return total;
}

/** 文本 UTF-8 字节数 */
function utf8ByteLength(text: string): number {
  return new util.TextEncoder().encodeInto(text).length;
}

/** 从完整路径截取文件名（含重编号后缀） */
function extractFileName(path: string): string {
  let idx = path.lastIndexOf('/');
  return idx >= 0 ? path.substring(idx + 1) : path;
}

// ── 适配器命令装饰（演示会话走模拟逻辑，真实会话透传原实现） ──

/** 安装接收方向装饰器（两个接收适配器的 confirm / decline / cancel） */
function installReceiveDecorators(): void {
  let localAdapter = getAdapter(LOCAL_RECEIVE_KEY);
  if (localAdapter !== undefined) {
    let origConfirm = localAdapter.confirm;
    localAdapter.confirm = (sessionId: string): void => {
      let record = records.get(sessionId);
      if (record !== undefined) {
        demoConfirmLocalReceive(record);
        return;
      }
      origConfirm(sessionId);
    };
    // 拒绝/取消：注册表已自行终结会话，演示会话无需透传（避免触发真实接收仓库与原生调用）
    let origDecline = localAdapter.decline;
    localAdapter.decline = (sessionId: string): void => {
      if (records.get(sessionId) !== undefined) {
        removeRecord(sessionId);
        return;
      }
      origDecline(sessionId);
    };
    let origCancel = localAdapter.cancel;
    localAdapter.cancel = (sessionId: string): void => {
      if (records.get(sessionId) !== undefined) {
        stopDriver(sessionId);
        return;
      }
      origCancel(sessionId);
    };
  }
  let mtaAdapter = getAdapter(MTA_RECEIVE_KEY);
  if (mtaAdapter !== undefined) {
    let origConfirm = mtaAdapter.confirm;
    mtaAdapter.confirm = (sessionId: string): void => {
      let record = records.get(sessionId);
      if (record !== undefined) {
        demoConfirmMtaReceive(record);
        return;
      }
      origConfirm(sessionId);
    };
    let origDecline = mtaAdapter.decline;
    mtaAdapter.decline = (sessionId: string): void => {
      if (records.get(sessionId) !== undefined) {
        removeRecord(sessionId);
        return;
      }
      origDecline(sessionId);
    };
    let origCancel = mtaAdapter.cancel;
    mtaAdapter.cancel = (sessionId: string): void => {
      if (records.get(sessionId) !== undefined) {
        stopDriver(sessionId);
        return;
      }
      origCancel(sessionId);
    };
  }
}

/** 安装发送方向装饰器（两个发送适配器的 cancel / retry：演示会话空操作，防误伤真实发送链路） */
function installSendDecorators(): void {
  let localSend = getAdapter(LOCAL_SEND_KEY);
  if (localSend !== undefined) {
    let origCancel = localSend.cancel;
    localSend.cancel = (sessionId: string): void => {
      if (records.get(sessionId) !== undefined) {
        stopDriver(sessionId);
        return;
      }
      origCancel(sessionId);
    };
    let origRetry = localSend.retry;
    localSend.retry = (sessionId: string): void => {
      if (records.get(sessionId) !== undefined) {
        logger.warn('演示会话不支持重试: ' + sessionId);
        return;
      }
      origRetry(sessionId);
    };
  }
  let mtaSend = getAdapter(MTA_SEND_KEY);
  if (mtaSend !== undefined) {
    let origCancel = mtaSend.cancel;
    mtaSend.cancel = (sessionId: string): void => {
      if (records.get(sessionId) !== undefined) {
        stopDriver(sessionId);
        return;
      }
      origCancel(sessionId);
    };
    let origRetry = mtaSend.retry;
    mtaSend.retry = (sessionId: string): void => {
      if (records.get(sessionId) !== undefined) {
        logger.warn('演示会话不支持重试: ' + sessionId);
        return;
      }
      origRetry(sessionId);
    };
  }
}
