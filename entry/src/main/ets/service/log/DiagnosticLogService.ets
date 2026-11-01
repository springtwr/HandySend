/**
 * DiagnosticLogService.ets — 双通道文件日志
 *
 * 文件是诊断日志的唯一事实源：
 * - events：info/warn/error/fatal，始终写入，永不写 debug，容量小、保留久
 * - detail：始终写 info+；详细日志开启时追加 debug，容量大，页面固定读取此通道
 *
 * 写入采用内存队列 + 批量 append；退后台/窗口销毁/退出时主动 flush。
 * 日志页只读取文件尾部，不依赖 AppCore 的全量内存缓冲。
 */

import { common, bundleManager } from '@kit.AbilityKit';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo, zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { LogFileChangeEvent, LogFileKind, LogExportResult, LogReadResult } from '../../model/LogFileTypes';
import { LogViewEntry } from '../../model/Types';
import {
  formatLocalIsoTimestamp,
  formatLogLine,
  formatSessionEnd,
  formatSessionStart,
  parseLogLine,
  utf8ByteLength
} from '../../utils/LogFileFormat';
import { isDebugEnabled, registerDebugStateListener } from '../../utils/Logger';
import { DebugLogBudget } from '../../utils/DebugLogBudget';
import { errorText } from '../../utils/FormatUtil';
import { nativeSetRustLogLevel } from '../NativeBridge';

const LOG_DIR_NAME: string = 'diagnostics';
const EVENTS_CURRENT: string = 'events-current.log';
const EVENTS_PREVIOUS: string = 'events-previous.log';
const DETAIL_CURRENT: string = 'detail-current.log';
const DETAIL_PREVIOUS: string = 'detail-previous.log';

const EVENTS_MAX_BYTES: number = 512 * 1024;
const DETAIL_MAX_BYTES: number = 2 * 1024 * 1024;
const MAX_QUEUE_LINES: number = 500;
const FLUSH_INTERVAL_MS: number = 500;
const TAIL_BYTES: number = 256 * 1024;
const SETTINGS_STORE_NAME: string = 'handysend_settings';
const DETAIL_ENABLED_KEY: string = 'diagnostic_detail_enabled';

// debug 全局限流：detail 始终记录 info，debug 只允许占用有限预算，防止热点日志刷爆文件与页面
const DEBUG_BUDGET_PER_SECOND: number = 100;
const DEBUG_BUDGET_BURST: number = 300;

class LogChannel {
  kind: LogFileKind;
  file: fs.File | null = null;
  queue: Array<string> = [];
  writtenBytes: number = 0;
  part: number = 1;
  generation: number = 0;
  flushing: boolean = false;

  constructor(kind: LogFileKind) {
    this.kind = kind;
  }
}

const eventsChannel: LogChannel = new LogChannel(LogFileKind.EVENTS);
const detailChannel: LogChannel = new LogChannel(LogFileKind.DETAIL);

let appContext: common.UIAbilityContext | undefined = undefined;
let initialized: boolean = false;
let detailEnabled: boolean = false;
let sessionId: string = '';
let sessionStartedAt: number = 0;
let flushTimer: number = -1;
let fileError: string = '';
let debugListenerRegistered: boolean = false;
let changeCallbacks: Array<(event: LogFileChangeEvent) => void> = [];
const debugBudget: DebugLogBudget = new DebugLogBudget(DEBUG_BUDGET_PER_SECOND, DEBUG_BUDGET_BURST);

// ── 启动 / 会话 ──

/**
 * 启动文件日志并开始新会话。
 * 返回用户持久化的详细日志选择；未保存过时返回 undefined，由 Logger 使用构建默认值。
 */
export function startDiagnosticLogging(context: common.UIAbilityContext): boolean | undefined {
  appContext = context;
  let persistedDebug: boolean | undefined = readPersistedDebugEnabled();
  if (!debugListenerRegistered) {
    registerDebugStateListener(onDebugStateChanged);
    debugListenerRegistered = true;
  }
  if (!initialized) {
    initialized = true;
    ensureLogDir();
    rotateSessionFiles();
    beginNewSession();
  } else {
    beginNewSession();
  }
  ensureFlushTimer();
  // 若 Logger 已在文件日志之前完成初始化（例如 Ability 重建），补一次通道同步。
  onDebugStateChanged(isDebugEnabled());
  return persistedDebug;
}

/**
 * 新会话：重置会话标识并打开两个通道。
 * detail 始终记录 info 及以上，debug 仅在详细日志开启时追加；页面始终读 detail。
 */
function beginNewSession(): void {
  // Ability 重建时仍可能有一段队列未落盘，先同步 flush 再关闭，避免丢日志
  flushChannelSync(eventsChannel);
  flushChannelSync(detailChannel);
  closeChannel(eventsChannel);
  closeChannel(detailChannel);
  sessionId = createSessionId();
  sessionStartedAt = Date.now();
  eventsChannel.part = 1;
  detailChannel.part = 1;
  fileError = '';
  debugBudget.reset(Date.now());
  openChannel(eventsChannel);
  openChannel(detailChannel);
}

/** 启动时把 current 轮转为 previous；上上次直接删除。 */
function rotateSessionFiles(): void {
  rotateOne(LogFileKind.EVENTS);
  rotateOne(LogFileKind.DETAIL);
}

function rotateOne(kind: LogFileKind): void {
  let current: string = logPath(kind, false);
  let previous: string = logPath(kind, true);
  try {
    if (fs.accessSync(current)) {
      if (fs.accessSync(previous)) {
        fs.unlinkSync(previous);
      }
      fs.renameSync(current, previous);
    }
  } catch (_e) {
  }
}

function openChannel(channel: LogChannel): void {
  if (channel.file !== null) {
    return;
  }
  let path: string = logPath(channel.kind, false);
  try {
    channel.file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
    let size: number = channel.file !== null ? fs.statSync(channel.file.fd).size : 0;
    let header: string = formatSessionStart({
      sessionId: sessionId,
      part: channel.part,
      kind: channel.kind,
      startedAt: sessionStartedAt,
      debug: isDebugEnabled(),
      device: deviceInfo.marketName.length > 0 ? deviceInfo.marketName : deviceInfo.productModel
    });
    if (size > 0) {
      header = '# session-resume ' + formatLocalIsoTimestamp(Date.now()) + '\n' + header;
    }
    fs.writeSync(channel.file.fd, header);
    channel.writtenBytes = size + utf8ByteLength(header);
    channel.generation++;
    fileError = '';
    notifyFileChanged(channel.kind);
  } catch (e) {
    channel.file = null;
    fileError = errorText(e);
  }
}

function closeChannel(channel: LogChannel): void {
  if (channel.file === null) {
    return;
  }
  try {
    fs.closeSync(channel.file.fd);
  } catch (_e) {
  }
  channel.file = null;
  channel.queue = [];
}

function onDebugStateChanged(enabled: boolean): void {
  detailEnabled = enabled;
  // detail 始终打开：关闭详细日志时仍继续记录 info，页面不会因切换开关而失去内容
  if (detailChannel.file === null) {
    openChannel(detailChannel);
  }
  enqueue(detailChannel, '# detail=' + (enabled ? 'on' : 'off') +
    ' at=' + formatLocalIsoTimestamp(Date.now()) + '\n');
  notifyFileChanged(LogFileKind.DETAIL);
  try {
    nativeSetRustLogLevel(enabled ? 'debug' : 'info');
  } catch (_e) {
  }
}

// ── 写入 ──

/** 所有 Logger 输出的统一入口（由 AppCore.addLog 调用）。 */
export function appendDiagnosticLog(level: string, tag: string, message: string): void {
  if (!initialized) {
    return;
  }
  let now: number = Date.now();
  let line: string = formatLogLine(level, tag, message, now);
  // events 永远不写 debug，保证 debug 洪水不会挤掉用户侧关键日志
  if (level !== 'debug') {
    enqueue(eventsChannel, line);
  }
  // detail 始终记录 info+；debug 仅在详细日志开启时写入，并受全局限流保护
  if (level !== 'debug') {
    enqueue(detailChannel, line);
  } else if (detailEnabled) {
    if (!debugBudget.allow(now)) {
      return;
    }
    enqueue(detailChannel, line);
  }
  if (level === 'warn' || level === 'error' || level === 'fatal') {
    flushChannelAsync(eventsChannel);
    flushChannelAsync(detailChannel);
  }
}

/** 把本轮被限流丢弃的 debug 条数写成一条注释行，保留可观测性。 */
function flushDebugSuppressionSummary(flushNow: boolean = true): void {
  let count: number = debugBudget.takeSuppressed();
  if (count <= 0) {
    return;
  }
  enqueue(detailChannel, '# debug-suppressed count=' + count +
    ' at=' + formatLocalIsoTimestamp(Date.now()) + '\n');
  if (flushNow) {
    flushChannelAsync(detailChannel);
  }
}

/**
 * 导出前先等待正在进行的异步 flush，再把两通道队列同步落盘。
 * 否则用户刚操作产生的最后一段日志可能还在队列里，ZIP 会缺内容。
 */
async function prepareExportSnapshot(): Promise<void> {
  await waitForChannelFlush(eventsChannel);
  await waitForChannelFlush(detailChannel);
  flushDebugSuppressionSummary(false);
  flushChannelSync(eventsChannel);
  flushChannelSync(detailChannel);
  try {
    if (eventsChannel.file !== null) {
      fs.fsyncSync(eventsChannel.file.fd);
    }
    if (detailChannel.file !== null) {
      fs.fsyncSync(detailChannel.file.fd);
    }
  } catch (_e) {
  }
}

async function waitForChannelFlush(channel: LogChannel): Promise<void> {
  while (channel.flushing) {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 10);
    });
  }
}

function enqueue(channel: LogChannel, line: string): void {
  if (channel.file === null) {
    return;
  }
  if (channel.queue.length >= MAX_QUEUE_LINES) {
    channel.queue.shift();
  }
  channel.queue.push(line);
}

async function flushChannelAsync(channel: LogChannel): Promise<void> {
  if (channel.flushing || channel.file === null || channel.queue.length === 0) {
    return;
  }
  channel.flushing = true;
  let lines: Array<string> = channel.queue.splice(0, channel.queue.length);
  let text: string = lines.join('');
  try {
    await fs.write(channel.file.fd, text);
    channel.writtenBytes += utf8ByteLength(text);
    if (channel.writtenBytes > channelMaxBytes(channel.kind)) {
      rotateChannel(channel);
    }
    notifyFileChanged(channel.kind);
  } catch (e) {
    fileError = errorText(e);
  } finally {
    channel.flushing = false;
  }
}

function flushChannelSync(channel: LogChannel): void {
  if (channel.file === null || channel.queue.length === 0) {
    return;
  }
  let lines: Array<string> = channel.queue.splice(0, channel.queue.length);
  let text: string = lines.join('');
  try {
    fs.writeSync(channel.file.fd, text);
    channel.writtenBytes += utf8ByteLength(text);
    if (channel.writtenBytes > channelMaxBytes(channel.kind)) {
      rotateChannel(channel);
    }
    notifyFileChanged(channel.kind);
  } catch (e) {
    fileError = errorText(e);
  }
}

/** 主动 flush；sync=true 用于退出前收尾，sync=false 用于退后台等异步场景。 */
export function flushDiagnosticLog(reason: string, sync: boolean): void {
  if (!initialized) {
    return;
  }
  if (sync) {
    flushChannelSync(eventsChannel);
    flushChannelSync(detailChannel);
    try {
      if (eventsChannel.file !== null) {
        fs.fsyncSync(eventsChannel.file.fd);
      }
      if (detailChannel.file !== null) {
        fs.fsyncSync(detailChannel.file.fd);
      }
    } catch (_e) {
    }
  } else {
    flushChannelAsync(eventsChannel);
    flushChannelAsync(detailChannel);
  }
}

/** 正常退出：写 session-end、sync flush 并关闭文件。 */
export function markDiagnosticSessionEnd(): void {
  if (!initialized) {
    return;
  }
  // 先落盘队列，再写结束标记，保证标记位于本次会话最后。
  flushChannelSync(eventsChannel);
  flushChannelSync(detailChannel);
  let marker: string = formatSessionEnd(Date.now(), true);
  appendMarker(eventsChannel, marker);
  appendMarker(detailChannel, marker);
  try {
    if (eventsChannel.file !== null) {
      fs.fsyncSync(eventsChannel.file.fd);
    }
    if (detailChannel.file !== null) {
      fs.fsyncSync(detailChannel.file.fd);
    }
  } catch (_e) {
  }
  closeChannel(eventsChannel);
  closeChannel(detailChannel);
  initialized = false;
  if (flushTimer >= 0) {
    clearInterval(flushTimer);
    flushTimer = -1;
  }
}

function appendMarker(channel: LogChannel, marker: string): void {
  if (channel.file === null) {
    return;
  }
  try {
    fs.writeSync(channel.file.fd, marker);
    channel.writtenBytes += utf8ByteLength(marker);
  } catch (e) {
    fileError = errorText(e);
  }
}

function rotateChannel(channel: LogChannel): void {
  let current: string = logPath(channel.kind, false);
  let previous: string = logPath(channel.kind, true);
  closeChannel(channel);
  try {
    if (fs.accessSync(previous)) {
      fs.unlinkSync(previous);
    }
    fs.renameSync(current, previous);
  } catch (_e) {
  }
  channel.part++;
  openChannel(channel);
}

function channelMaxBytes(kind: LogFileKind): number {
  return kind === LogFileKind.DETAIL ? DETAIL_MAX_BYTES : EVENTS_MAX_BYTES;
}

/** 启动写入定时器；清空/重建后若定时器已被关闭，可重新建立。 */
function ensureFlushTimer(): void {
  if (flushTimer >= 0) {
    return;
  }
  flushTimer = setInterval((): void => {
    flushChannelAsync(eventsChannel);
    flushChannelAsync(detailChannel);
    flushDebugSuppressionSummary();
  }, FLUSH_INTERVAL_MS);
}

// ── 清空 ──

export function clearDiagnosticLogs(): void {
  if (appContext === undefined) {
    return;
  }
  closeChannel(eventsChannel);
  closeChannel(detailChannel);
  deleteOne(LogFileKind.EVENTS);
  deleteOne(LogFileKind.DETAIL);
  sessionId = createSessionId();
  sessionStartedAt = Date.now();
  eventsChannel.part = 1;
  detailChannel.part = 1;
  debugBudget.reset(Date.now());
  initialized = true;
  openChannel(eventsChannel);
  openChannel(detailChannel);
  ensureFlushTimer();
}

function deleteOne(kind: LogFileKind): void {
  let paths: Array<string> = [logPath(kind, false), logPath(kind, true)];
  for (let i = 0; i < paths.length; i++) {
    try {
      if (fs.accessSync(paths[i])) {
        fs.unlinkSync(paths[i]);
      }
    } catch (_e) {
    }
  }
}

// ── 读取 ──

export function isDiagnosticLogAvailable(): boolean {
  // 页面固定读 detail：它始终记录 info+，详细日志只决定是否追加 debug
  return initialized && detailChannel.file !== null;
}

export function getDiagnosticLogError(): string {
  return fileError;
}

/** 读当前文件尾部。 */
export async function readLogTail(kind: LogFileKind,
  maxBytes: number = TAIL_BYTES): Promise<LogReadResult> {
  let path: string = logPath(kind, false);
  let generation: number = channelFor(kind).generation;
  let result: LogReadResult = {
    entries: [],
    nextOffset: 0,
    generation: generation,
    reset: false,
    hasMore: false
  };
  try {
    if (!fs.accessSync(path)) {
      return result;
    }
    let stat: fs.Stat = fs.statSync(path);
    let start: number = Math.max(0, stat.size - maxBytes);
    let text: string = await readTextRangeAsync(path, start, stat.size - start);
    let baseOffset: number = start;
    if (start > 0) {
      let firstBreak: number = text.indexOf('\n');
      if (firstBreak < 0) {
        return result;
      }
      baseOffset += utf8ByteLength(text.substring(0, firstBreak + 1));
      text = text.substring(firstBreak + 1);
    }
    let lastBreak: number = text.lastIndexOf('\n');
    if (lastBreak < 0) {
      return result;
    }
    text = text.substring(0, lastBreak + 1);
    result.entries = parseText(text, baseOffset);
    result.nextOffset = baseOffset + utf8ByteLength(text);
    result.hasMore = start > 0;
  } catch (_e) {
  }
  return result;
}

/** 从已有偏移增量读取；generation 变化或文件回退时返回 reset=true。 */
export async function readLogFrom(kind: LogFileKind, offset: number,
  generation: number): Promise<LogReadResult> {
  let path: string = logPath(kind, false);
  let currentGeneration: number = channelFor(kind).generation;
  if (currentGeneration !== generation) {
    let resetResult: LogReadResult = await readLogTail(kind);
    resetResult.reset = true;
    return resetResult;
  }
  let result: LogReadResult = {
    entries: [],
    nextOffset: offset,
    generation: currentGeneration,
    reset: false,
    hasMore: false
  };
  try {
    if (!fs.accessSync(path)) {
      return result;
    }
    let stat: fs.Stat = fs.statSync(path);
    if (stat.size < offset) {
      let resetResult: LogReadResult = await readLogTail(kind);
      resetResult.reset = true;
      return resetResult;
    }
    if (stat.size === offset) {
      return result;
    }
    let text: string = await readTextRangeAsync(path, offset, stat.size - offset);
    let lastBreak: number = text.lastIndexOf('\n');
    if (lastBreak < 0) {
      return result;
    }
    let complete: string = text.substring(0, lastBreak + 1);
    result.entries = parseText(complete, offset);
    result.nextOffset = offset + utf8ByteLength(complete);
  } catch (_e) {
  }
  return result;
}

function parseText(text: string, baseOffset: number): Array<LogViewEntry> {
  let entries: Array<LogViewEntry> = [];
  let lines: Array<string> = text.split('\n');
  let offset: number = baseOffset;
  for (let i = 0; i < lines.length; i++) {
    let line: string = lines[i];
    let entry: LogViewEntry | undefined = parseLogLine(line, offset);
    if (entry !== undefined) {
      entries.push(entry);
    }
    offset += utf8ByteLength(line) + 1;
  }
  return entries;
}

// ── 导出 ──

interface DiagnosticExportMetadata {
  appName: string;
  versionName: string;
  versionCode: number;
  buildMode: string;
  device: string;
  exportedAt: string;
  detailEnabled: boolean;
  files: Array<string>;
}

/**
 * 导出应用的全部诊断日志：events/detail 的 current/previous 四份文件 + 元数据打包为 ZIP。
 * 页面不再提供“上次会话查看”入口，上一次会话仅作为导出内容保留。
 */
export async function exportAllDiagnosticLogs(context: common.UIAbilityContext): Promise<LogExportResult> {
  let tempDir: string = context.cacheDir + '/diagnostic_export_' + Date.now().toString();
  let zipPath: string = context.cacheDir + '/handysend_logs_' + timestampForFileName() + '.zip';
  try {
    await prepareExportSnapshot();
    let names: Array<string> = ['events-current.log', 'events-previous.log',
      'detail-current.log', 'detail-previous.log'];
    let sources: Array<string> = [
      logPath(LogFileKind.EVENTS, false),
      logPath(LogFileKind.EVENTS, true),
      logPath(LogFileKind.DETAIL, false),
      logPath(LogFileKind.DETAIL, true)
    ];
    fs.mkdirSync(tempDir, true);
    let included: Array<string> = [];
    for (let i = 0; i < sources.length; i++) {
      if (copyIfExists(sources[i], tempDir + '/' + names[i])) {
        included.push(names[i]);
      }
    }
    if (included.length === 0) {
      return { status: 'empty', fileName: '' };
    }
    let metadata: DiagnosticExportMetadata = buildExportMetadata(included);
    writeTextFile(tempDir + '/metadata.json', JSON.stringify(metadata, null, 2));
    writeTextFile(tempDir + '/README.txt',
      'HandySend diagnostic logs\n\n' +
      'timestamps use local time with a UTC offset (for example +08:00)\n' +
      'events-*.log: info/warn/error/fatal only (never debug)\n' +
      'detail-*.log: info/warn/error/fatal; debug lines appear when detailed logging is enabled\n');
    await zlib.compressFile(tempDir, zipPath, {
      level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION
    });
    let saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    saveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    let documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    let uris: Array<string> = await documentPicker.save(saveOptions);
    if (uris.length === 0) {
      return { status: 'cancelled', fileName: '' };
    }
    let dirPath: string = new fileUri.FileUri(uris[0]).path;
    let fileName: string = 'handysend_logs_' + timestampForFileName() + '.zip';
    fs.copyFileSync(zipPath, dirPath + '/' + fileName);
    return { status: 'success', fileName: fileName };
  } catch (e) {
    let text: string = errorText(e);
    if (text.includes('[801]') || text.includes('[0]')) {
      return { status: 'cancelled', fileName: '' };
    }
    return { status: 'failed', fileName: '' };
  } finally {
    cleanupExportTemp(tempDir);
    try {
      if (fs.accessSync(zipPath)) {
        fs.unlinkSync(zipPath);
      }
    } catch (_e) {
    }
  }
}

function copyIfExists(source: string, dest: string): boolean {
  try {
    if (!fs.accessSync(source)) {
      return false;
    }
    if (fs.statSync(source).size === 0) {
      return false;
    }
    fs.copyFileSync(source, dest);
    return true;
  } catch (_e) {
    return false;
  }
}

function buildExportMetadata(files: Array<string>): DiagnosticExportMetadata {
  let versionName: string = '';
  let versionCode: number = 0;
  let buildMode: string = 'unknown';
  try {
    let info: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    versionName = info.versionName;
    versionCode = info.versionCode;
    buildMode = info.appInfo.debug ? 'debug' : 'release';
  } catch (_e) {
  }
  let metadata: DiagnosticExportMetadata = {
    appName: 'HandySend',
    versionName: versionName,
    versionCode: versionCode,
    buildMode: buildMode,
    device: deviceInfo.marketName.length > 0 ? deviceInfo.marketName : deviceInfo.productModel,
    exportedAt: formatLocalIsoTimestamp(Date.now()),
    detailEnabled: detailEnabled,
    files: files
  };
  return metadata;
}

function writeTextFile(path: string, text: string): void {
  let file: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, text);
    fs.fsyncSync(file.fd);
  } finally {
    fs.closeSync(file.fd);
  }
}

function cleanupExportTemp(tempDir: string): void {
  try {
    if (!fs.accessSync(tempDir)) {
      return;
    }
    let names: Array<string> = ['events-current.log', 'events-previous.log',
      'detail-current.log', 'detail-previous.log', 'metadata.json', 'README.txt'];
    for (let i = 0; i < names.length; i++) {
      let path: string = tempDir + '/' + names[i];
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    }
    fs.rmdirSync(tempDir);
  } catch (_e) {
  }
}

// ── 详细日志持久化选择 ──

/** 保存用户对「记录详细日志」的选择；重启后继续生效。 */
export function setPersistedDebugEnabled(enabled: boolean): void {
  if (appContext === undefined) {
    return;
  }
  try {
    let pref: preferences.Preferences = preferences.getPreferencesSync(appContext, { name: SETTINGS_STORE_NAME });
    let current: preferences.ValueType = pref.getSync(DETAIL_ENABLED_KEY, false);
    if (current === enabled && pref.hasSync(DETAIL_ENABLED_KEY)) {
      return;
    }
    pref.putSync(DETAIL_ENABLED_KEY, enabled);
    pref.flushSync();
  } catch (_e) {
  }
}

function readPersistedDebugEnabled(): boolean | undefined {
  if (appContext === undefined) {
    return undefined;
  }
  try {
    let pref: preferences.Preferences = preferences.getPreferencesSync(appContext, { name: SETTINGS_STORE_NAME });
    if (!pref.hasSync(DETAIL_ENABLED_KEY)) {
      return undefined;
    }
    let value: preferences.ValueType = pref.getSync(DETAIL_ENABLED_KEY, false);
    return typeof value === 'boolean' ? value : undefined;
  } catch (_e) {
    return undefined;
  }
}

// ── 订阅 ──

export function subscribeLogFileChanges(callback: (event: LogFileChangeEvent) => void): void {
  changeCallbacks.push(callback);
}

export function unsubscribeLogFileChanges(callback: (event: LogFileChangeEvent) => void): void {
  let index: number = -1;
  for (let i = 0; i < changeCallbacks.length; i++) {
    if (changeCallbacks[i] === callback) {
      index = i;
      break;
    }
  }
  if (index >= 0) {
    changeCallbacks.splice(index, 1);
  }
}

function notifyFileChanged(kind: LogFileKind): void {
  if (changeCallbacks.length === 0) {
    return;
  }
  let event: LogFileChangeEvent = {
    kind: kind,
    generation: channelFor(kind).generation
  };
  let snapshot: Array<(event: LogFileChangeEvent) => void> = changeCallbacks.slice();
  for (let i = 0; i < snapshot.length; i++) {
    try {
      snapshot[i](event);
    } catch (_e) {
    }
  }
}

// ── 路径与工具 ──

function channelFor(kind: LogFileKind): LogChannel {
  return kind === LogFileKind.DETAIL ? detailChannel : eventsChannel;
}

function logPath(kind: LogFileKind, previous: boolean): string {
  let directory: string = appContext !== undefined ? appContext.filesDir + '/' + LOG_DIR_NAME : '';
  if (kind === LogFileKind.DETAIL) {
    return directory + '/' + (previous ? DETAIL_PREVIOUS : DETAIL_CURRENT);
  }
  return directory + '/' + (previous ? EVENTS_PREVIOUS : EVENTS_CURRENT);
}

function ensureLogDir(): void {
  let directory: string = appContext !== undefined ? appContext.filesDir + '/' + LOG_DIR_NAME : '';
  if (directory.length === 0) {
    return;
  }
  try {
    if (!fs.accessSync(directory)) {
      fs.mkdirSync(directory, true);
    }
  } catch (_e) {
  }
}

function createSessionId(): string {
  let now: number = Date.now();
  return now.toString(36) + '-' + Math.floor(Math.random() * 0x10000).toString(36);
}

function timestampForFileName(): string {
  let value: Date = new Date();
  let pad = (n: number): string => n < 10 ? '0' + n : '' + n;
  return '' + value.getFullYear() + pad(value.getMonth() + 1) + pad(value.getDate()) +
    '_' + pad(value.getHours()) + pad(value.getMinutes()) + pad(value.getSeconds());
}

async function readTextRangeAsync(path: string, start: number, length: number): Promise<string> {
  if (length <= 0) {
    return '';
  }
  let file: fs.File | null = null;
  try {
    file = await fs.open(path, fs.OpenMode.READ_ONLY);
    let buffer: ArrayBuffer = new ArrayBuffer(length);
    let read: number = await fs.read(file.fd, buffer, { offset: start, length: length });
    return new util.TextDecoder().decodeToString(new Uint8Array(buffer, 0, read));
  } catch (_e) {
    return '';
  } finally {
    if (file !== null) {
      try {
        await fs.close(file.fd);
      } catch (_e) {
      }
    }
  }
}


