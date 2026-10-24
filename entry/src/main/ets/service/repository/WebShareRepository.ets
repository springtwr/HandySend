import { fileIo as fs } from '@kit.CoreFileKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { SendFileItem, ReceiveHistoryEntry } from '../../model/Types';
import {
  SessionFileDescriptor,
  SessionStage,
  TransferSession,
  isTerminalStage
} from '../../model/transfer/TransferSession';
import {
  NativeTransferFileInfo,
  NativeWebSendPrepareDownloadEvent,
  NativeWebSendProgressEvent,
  NativeWebSendSessionEndEvent,
  NativeWebUploadDoneEvent,
  NativeWebUploadPrepareEvent,
  NativeWebUploadProgressEvent
} from '../../model/NativeTypes';
import {
  nativeStartWebService,
  nativeStopWebService,
  nativeUpdateWebServiceFiles,
  nativeSetWebServiceUploadEnabled,
  nativeAcceptWebSession,
  nativeDeclineWebSession,
  nativeExpireWebSession,
  nativeSweepWebSessions,
  nativeSetWebUploadTargets
} from '../NativeBridge';
import { getAppContext, notifyChange } from './AppCore';
import { getHttpsEnabled, getReceivePin } from './SettingsRepository';
import { getDeviceAlias, getLocalDeviceInfo } from './DeviceRepository';
import { ensureRecvDownloadDir, recvTextDir, uniquePath } from './ReceiveTargets';
import { addEntries as addHistoryEntries } from './ReceiveHistoryService';
import { readTextOfLocation } from '../../utils/FileTextUtil';
import {
  WEB_DOWNLOAD_KEY,
  beginWebDownloadBurst,
  handleWebDownloadProgress,
  markWebDownloadAccepted,
  markWebDownloadDeclined,
  setWebDownloadInvokers
} from '../transfer/adapters/WebDownloadAdapter';
import {
  WEB_UPLOAD_KEY,
  beginWebUploadBurst,
  handleWebUploadDone,
  handleWebUploadProgress,
  markWebUploadAccepted,
  markWebUploadDeclined,
  setWebUploadInvokers
} from '../transfer/adapters/WebUploadAdapter';
import {
  finish,
  querySessions,
  subscribeSessions
} from '../transfer/TransferSessionRegistry';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:WebShareRepository', '网页分享');

// ── Web 分享服务状态（自研单服务：下载与上传同端口） ──

let shareLinkInfo: string = '';
let sharePort: number = 0;

// 本次挂载是否允许浏览器直接下载：由分享面板在挂载期间切换，停止分享即复位。
// 它是一次外发授权而非长期偏好，故不进入设置持久化。
let webDownloadAutoAccept: boolean = false;

/** 设置本次挂载的直接下载授权（仅当前分享有效）。 */
export function setWebDownloadAutoAccept(enabled: boolean): void {
  webDownloadAutoAccept = enabled;
  logger.info('本次挂载的直接下载授权=' + enabled);
  notifyChange();
}

/** 本次挂载是否允许浏览器直接下载。 */
export function isWebDownloadAutoAccept(): boolean {
  return webDownloadAutoAccept;
}

// 分享文件表是否正在替换（避免暂存区连续变化时并发换表）
let webUpdating: boolean = false;

// 网页服务当前是否开放浏览器上传：决定面板是否出示上传入口
let webUploadEnabled: boolean = false;

/** 当前是否已挂载分享文件（决定面板是否出示下载入口）。 */
export function hasSharedFiles(): boolean {
  return Object.keys(shareFileProfiles).length > 0;
}

/** 已挂载的分享文件数量。 */
export function getSharedFileCount(): number {
  return Object.keys(shareFileProfiles).length;
}

/** 网页上传入口是否已开放（决定面板是否出示上传入口）。 */
export function isWebUploadEnabled(): boolean {
  return webUploadEnabled;
}

// 当前分享打开的源文件句柄集合：模块级持有 fs.File 引用，阻止 GC 回收
// 对象时 fd 被自动关闭（否则 Rust 侧将持有失效 fd）。fd 所有权归本层——
// Rust 每次下载仅 dup 副本消费、从不关闭原始 fd；本层在停止/替换分享、
// 创建失败时统一 closeSync 关闭。
let shareFileHandles: Array<fs.File> = [];

// 当前分享的源文件档案（fileId → 文件信息）：分享创建成功后写入，
// 待确认会话创建时据此登记完整文件清单；停止分享时清空。
interface ShareFileProfile {
  path: string
  fileName: string
  fileType: string
  size: number
  fd: number
  preview: string
  sha256: string
}

let shareFileProfiles: Record<string, ShareFileProfile> = {};

/** 重建服务时下发的文件表条目（字段名与原生层解析契约一致）。 */
interface WebFileJson {
  fileId: string
  fileName: string
  fileType: string
  size: number
  filePath: string
  fd: number
  preview: string
  sha256: string
}

/** 登记本次分享的源文件档案（分享创建成功后调用）。 */
function registerShareFileProfiles(files: Array<SendFileItem>, handles: Array<fs.File>): void {
  let next: Record<string, ShareFileProfile> = {};
  for (let i = 0; i < files.length; i++) {
    let f = files[i];
    next[f.fileId] = {
      path: f.filePath,
      fileName: f.fileName,
      fileType: f.fileType,
      size: f.size,
      fd: i < handles.length ? handles[i].fd : -1,
      preview: f.preview !== undefined ? f.preview : '',
      sha256: f.hash !== undefined ? f.hash : ''
    };
  }
  shareFileProfiles = next;
}

/** 以已挂载的文件档案组装原生层文件表 JSON（无文件时为空数组）。 */
function buildWebFilesJson(): string {
  let entries: Array<WebFileJson> = [];
  let ids: Array<string> = Object.keys(shareFileProfiles);
  for (let i = 0; i < ids.length; i++) {
    let profile = shareFileProfiles[ids[i]];
    entries.push({
      fileId: ids[i],
      fileName: profile.fileName,
      fileType: profile.fileType,
      size: profile.size,
      filePath: profile.path,
      fd: profile.fd,
      preview: profile.preview,
      sha256: profile.sha256
    });
  }
  return JSON.stringify(entries);
}

/**
 * 本次挂载的可下载文件清单（会话文件描述符）。
 *
 * 浏览器下载会话创建时即登记，使待确认弹窗与详情页在下载开始前
 * 就有完整的文件数量与清单，而不是等第一个文件事件才逐条出现。
 */
function shareFileDescriptors(): Array<SessionFileDescriptor> {
  let result: Array<SessionFileDescriptor> = [];
  let ids: Array<string> = Object.keys(shareFileProfiles);
  for (let i = 0; i < ids.length; i++) {
    let profile = shareFileProfiles[ids[i]];
    let descriptor: SessionFileDescriptor = {
      fileId: ids[i],
      fileName: profile.fileName,
      fileType: profile.fileType,
      totalBytes: profile.size,
      path: profile.path
    };
    result.push(descriptor);
  }
  return result;
}

/** 清空分享源文件档案（停止分享时调用）。 */
function clearShareFileProfiles(): void {
  shareFileProfiles = {};
}

/**
 * 关闭当前分享持有的全部源文件句柄并清空。
 * 调用时机由调用方保证：须在服务器已停止接受该分享的下载请求之后
 * （stopShareLink 的 native 调用返回后，或创建新分享替换旧分享时），
 * 避免"句柄关闭后仍被下载读取"的竞态。
 */
function closeShareFileHandles(): void {
  for (let i = 0; i < shareFileHandles.length; i++) {
    try {
      fs.closeSync(shareFileHandles[i]);
    } catch (_ce) {
    }
  }
  shareFileHandles = [];
}

// ── 自研服务启停（与 LocalSend 服务独立端口） ──

/** 网页上传暂存目录（应用缓存下；确认时文件落盘到最终位置，暂存只做中转）。 */
function webUploadStageDir(): string {
  let appContext = getAppContext();
  if (appContext === undefined) {
    return '';
  }
  let dir: string = appContext.cacheDir + '/web_upload/';
  try {
    fs.mkdirSync(dir, true);
  } catch (_e) {
    return '';
  }
  return dir;
}

/** 新服务启动配置（字段名与 Rust WebServiceConfig 对齐，camelCase）。 */
interface WebServiceFileJson {
  fileId: string
  filePath: string
  fileName: string
  fileType: string
  size: number
  fd: number
  preview: string
  sha256: string
}

interface WebServiceConfigJson {
  alias: string
  pin?: string
  uploadEnabled: boolean
  useHttps: boolean
  uploadDir: string
  files: Array<WebServiceFileJson>
}

/** 组装新服务启动配置（字段名与 Rust WebServiceConfig 对齐）。 */
function buildWebServiceConfig(uploadEnabled: boolean): string {
  let files: Array<WebServiceFileJson> = [];
  let ids: Array<string> = Object.keys(shareFileProfiles);
  for (let i = 0; i < ids.length; i++) {
    let profile = shareFileProfiles[ids[i]];
    files.push({
      fileId: ids[i],
      filePath: profile.path,
      fileName: profile.fileName,
      fileType: profile.fileType,
      size: profile.size,
      fd: profile.fd,
      preview: profile.preview,
      sha256: profile.sha256
    });
  }
  let pin: string = getReceivePin();
  let config: WebServiceConfigJson = {
    alias: getDeviceAlias(),
    uploadEnabled: uploadEnabled,
    useHttps: getHttpsEnabled(),
    uploadDir: webUploadStageDir(),
    files: files
  };
  if (pin.length > 0) {
    config.pin = pin;
  }
  return JSON.stringify(config);
}

/** 以当前挂载与上传开关启动服务（调用方已备好文件句柄与档案）。 */
async function startWebServiceLocked(uploadEnabled: boolean): Promise<boolean> {
  let port: number = 0;
  try {
    port = await nativeStartWebService(buildWebServiceConfig(uploadEnabled));
  } catch (e) {
    logger.error('网页服务启动失败：' + e);
    notifyChange();
    return false;
  }
  if (port <= 0) {
    logger.error('网页服务启动失败：无效 port ' + port);
    notifyChange();
    return false;
  }
  sharePort = port;
  webUploadEnabled = uploadEnabled;
  let localIp = getLocalDeviceInfo().ip;
  shareLinkInfo = (getHttpsEnabled() ? 'https' : 'http') + '://' + localIp + ':' + sharePort;
  logger.info('网页服务已启动：' + shareLinkInfo);
  notifyChange();
  return true;
}

export function getShareLink(): string {
  return shareLinkInfo;
}

/**
 * 挂载分享并启动服务（网页发送入口）。
 * 流程与旧链路一致：先打开新句柄 → 启动成功后再关闭旧句柄并移交，
 * 失败时旧分享保持可用。
 */
export async function createShareLink(files: Array<SendFileItem>): Promise<void> {
  let appContext = getAppContext();
  if (appContext === undefined) {
    logger.error('AppService 未初始化');
    return;
  }
  // fd-direct：为每个源文件打开读 fd 一并交给 Rust；本层持有 fs.File
  // 对象至分享结束（Rust 每次下载 dup 副本直读，原始 fd 由本层关闭）
  let openedHandles: Array<fs.File> = [];
  try {
    for (let i = 0; i < files.length; i++) {
      let file = fs.openSync(files[i].filePath, fs.OpenMode.READ_ONLY);
      openedHandles.push(file);
    }
  } catch (e) {
    for (let k = 0; k < openedHandles.length; k++) {
      try {
        fs.closeSync(openedHandles[k]);
      } catch (_ce) {
      }
    }
    logger.error('打开源文件失败：' + e);
    notifyChange();
    return;
  }
  // 先登记新档案再启动：启动配置据此组装文件表
  let previousProfiles: Record<string, ShareFileProfile> = shareFileProfiles;
  let previousHandles: Array<fs.File> = shareFileHandles;
  registerShareFileProfiles(files, openedHandles);
  let uploadEnabled: boolean = webUploadEnabled;
  let started: boolean = await startWebServiceLocked(uploadEnabled);
  if (!started) {
    // 启动失败：恢复旧档案，关闭本次打开的句柄（旧句柄未动，无需恢复）
    shareFileProfiles = previousProfiles;
    for (let k = 0; k < openedHandles.length; k++) {
      try {
        fs.closeSync(openedHandles[k]);
      } catch (_ce) {
      }
    }
    return;
  }
  // 启动成功：关闭旧分享句柄并移交新句柄长期持有
  for (let i = 0; i < previousHandles.length; i++) {
    try {
      fs.closeSync(previousHandles[i]);
    } catch (_ce) {
    }
  }
  shareFileHandles = openedHandles;
  // 新一次分享从「需确认」开始：直接下载授权只在本次挂载内由面板显式打开
  webDownloadAutoAccept = false;
}

/** 停止网页服务：关闭句柄、清空档案与地址（幂等）。 */
export async function stopShareLink(): Promise<void> {
  logger.debug('停止分享已调用');
  try {
    nativeStopWebService();
  } catch (e) {
    logger.warn('停止网页服务失败: ' + String(e));
  }
  closeShareFileHandles();
  shareLinkInfo = '';
  sharePort = 0;
  clearShareFileProfiles();
  webDownloadAutoAccept = false;
  webUploadEnabled = false;
  logger.info('网页分享服务已停止');
  notifyChange();
}

/**
 * 启动网页上传入口（网页接收入口；无内容前置条件）。
 * 已挂载的分享文件随服务一起提供（单服务双段），不单独重建。
 */
export async function startWebUpload(): Promise<void> {
  if (shareLinkInfo.length > 0 && webUploadEnabled) {
    return;
  }
  if (shareLinkInfo.length > 0) {
    try {
      nativeSetWebServiceUploadEnabled(true);
      webUploadEnabled = true;
    } catch (e) {
      logger.error('打开浏览器上传失败：' + e);
    }
    notifyChange();
    return;
  }
  await startWebServiceLocked(true);
}

/**
 * 确保网页上传已开放：服务已运行时直接返回，
 * 避免重复进入面板时重建服务器打断进行中的传输。
 */
export async function ensureWebUpload(): Promise<void> {
  if (shareLinkInfo.length > 0 && webUploadEnabled) {
    return;
  }
  await startWebUpload();
}

/**
 * 撤下已挂载的分享文件，浏览器上传入口按当前状态保留。
 * 以空文件表热替换；上传未开放时服务随之完全停止。
 */
export async function unmountShare(): Promise<void> {
  if (shareLinkInfo.length === 0) {
    return;
  }
  try {
    let count: number = nativeUpdateWebServiceFiles('[]');
    closeShareFileHandles();
    clearShareFileProfiles();
    webDownloadAutoAccept = false;
    if (!webUploadEnabled) {
      await stopShareLink();
      return;
    }
    logger.info('分享文件已撤下，上传入口继续开放');
  } catch (e) {
    logger.error('撤下分享文件失败：' + e);
  }
  notifyChange();
}

/**
 * 关闭浏览器上传入口，已挂载的分享文件保留。
 * 没有分享文件时服务随之完全停止。
 */
export async function disableWebUpload(): Promise<void> {
  if (shareLinkInfo.length === 0) {
    return;
  }
  try {
    nativeSetWebServiceUploadEnabled(false);
    webUploadEnabled = false;
    if (!hasSharedFiles()) {
      await stopShareLink();
      return;
    }
    logger.info('浏览器上传已关闭，分享文件继续提供');
  } catch (e) {
    logger.error('关闭浏览器上传失败：' + e);
  }
  notifyChange();
}

/**
 * 为更新后的清单复用既有文件标识。
 *
 * 文件标识是对外契约的一部分：浏览器页面加载后按该标识请求文件，重新挂载时若整批换新标识，
 * 已打开的页面会拿着旧标识请求而全部失效（表现为下载失败、进度停在 0）。故按路径复用原标识。
 */
function reuseShareFileIds(files: Array<SendFileItem>): void {
  let idByPath: Record<string, string> = {};
  let ids: Array<string> = Object.keys(shareFileProfiles);
  for (let i = 0; i < ids.length; i++) {
    idByPath[shareFileProfiles[ids[i]].path] = ids[i];
  }
  let used: Record<string, boolean> = {};
  for (let i = 0; i < files.length; i++) {
    let reused: string | undefined = idByPath[files[i].filePath];
    if (reused !== undefined && used[reused] !== true) {
      files[i].fileId = reused;
      used[reused] = true;
    }
  }
}

/**
 * 就地把分享文件表替换为当前暂存内容（浏览器刷新即可见，不重启服务器）。
 *
 * 仅在服务运行中且处于分享模式时生效；清单为空时等价于撤下分享。
 * 新旧句柄交接顺序：先打开新句柄 → 原生层换表（旧表立即失效）→ 再关闭旧句柄，
 * 保证换表瞬间不存在「表里指向已关闭 fd」的窗口。
 */
export async function updateShareFiles(files: Array<SendFileItem>): Promise<void> {
  if (shareLinkInfo.length === 0 || webUpdating) {
    return;
  }
  if (files.length === 0) {
    await unmountShare();
    return;
  }
  webUpdating = true;
  reuseShareFileIds(files);
  let openedHandles: Array<fs.File> = [];
  try {
    for (let i = 0; i < files.length; i++) {
      let file = fs.openSync(files[i].filePath, fs.OpenMode.READ_ONLY);
      openedHandles.push(file);
    }
    let count: number = nativeUpdateWebServiceFiles(buildWebFilesJsonFor(files, openedHandles));
    closeShareFileHandles();
    shareFileHandles = openedHandles;
    registerShareFileProfiles(files, shareFileHandles);
    logger.info('分享文件已更新，当前可下载 ' + count + ' 个');
  } catch (e) {
    // 换表失败：旧分享保持不变，关闭本次打开的句柄
    for (let k = 0; k < openedHandles.length; k++) {
      try {
        fs.closeSync(openedHandles[k]);
      } catch (_ce) {
      }
    }
    logger.error('更新分享文件失败：' + e);
  } finally {
    webUpdating = false;
  }
  notifyChange();
}

/** 以给定清单与句柄组装原生层文件表 JSON（供换表时使用已就绪的新句柄）。 */
function buildWebFilesJsonFor(files: Array<SendFileItem>, handles: Array<fs.File>): string {
  let entries: Array<WebFileJson> = [];
  for (let i = 0; i < files.length; i++) {
    let f = files[i];
    entries.push({
      fileId: f.fileId,
      fileName: f.fileName,
      fileType: f.fileType,
      size: f.size,
      filePath: f.filePath,
      fd: i < handles.length ? handles[i].fd : -1,
      preview: f.preview !== undefined ? f.preview : '',
      sha256: f.hash !== undefined ? f.hash : ''
    });
  }
  return JSON.stringify(entries);
}

// ── Web 下载事件（由 handleNativeEvent 路由；sessionId 即浏览器 token） ──

export function handlePrepareDownloadTyped(event: NativeWebSendPrepareDownloadEvent): void {
  let token: string = event.sessionId;
  if (token.length === 0) {
    logger.warn('WebPrepareDownload 事件 token 为空，已忽略');
    return;
  }
  let ip: string = event.ip;
  logger.debug('token=' + token + ' ip=' + ip, { direction: 'share' });
  logger.info('收到 Web 下载请求 ip=' + ip + '（token=' + token + '）');

  // 是否直接放行由本次挂载的授权决定；未授权时进入待确认会话，
  // 由统一的新传输弹窗与任务页处理，本层不再维护第二套请求队列
  if (webDownloadAutoAccept) {
    logger.debug('Web 下载已按本次挂载授权直接放行');
    nativeAcceptWebSession(token);
    beginWebDownloadBurst(token, false, shareFileDescriptors(), ip);
    markWebDownloadAccepted(token);
  } else {
    logger.debug('Web 下载进入待确认（本次挂载未授权直接放行）');
    beginWebDownloadBurst(token, true, shareFileDescriptors(), ip);
  }
  notifyChange();
}

// Web 下载字节级进度：同步到统一会话，终态由适配器按静默窗口判定
export function handleWebSendProgressTyped(event: NativeWebSendProgressEvent): void {
  let token: string = event.sessionId;
  let fileId: string = event.fileId;
  if (token.length === 0 || fileId.length === 0) {
    return;
  }
  handleWebDownloadProgress(token, fileId, event.sentBytes, event.totalBytes);
  notifyChange();
}

/** 按 token 终结指定的网页下载会话（终态收口；不存在或已终态时静默返回）。 */
function finishWebDownloadSession(token: string, stage: SessionStage, reason?: string,
  code?: string): void {
  let targets: Array<TransferSession> = querySessions();
  for (let i = 0; i < targets.length; i++) {
    let target = targets[i];
    if (target.protocolKey === WEB_DOWNLOAD_KEY && target.protocolSessionId === token &&
      !isTerminalStage(target.stage)) {
      finish(target.id, stage, reason, code);
      return;
    }
  }
}

/** 服务端终结通知：待确认阶段直接取消；进行中交由适配器静默判定收口。 */
export function handleWebDownloadFinished(token: string): void {
  if (token.length === 0) {
    return;
  }
  let all: Array<TransferSession> = querySessions();
  for (let i = 0; i < all.length; i++) {
    let session = all[i];
    if (session.protocolKey === WEB_DOWNLOAD_KEY && session.protocolSessionId === token &&
      !isTerminalStage(session.stage)) {
      if (session.stage === SessionStage.awaitingConfirmation) {
        // 服务端已遗忘该待确认会话：本地按超时取消，不再等待用户
        finishWebDownloadSession(token, SessionStage.cancelled, '等待确认超时', 'pending_timeout');
      }
      return;
    }
  }
}

// ── Web 下载确认操作（入参为浏览器 token） ──

export function acceptWebDownload(token: string): void {
  if (token.length === 0) {
    return;
  }
  nativeAcceptWebSession(token);
  markWebDownloadAccepted(token);
  logger.info('Web 下载已接受 token=' + token);
  notifyChange();
}

export function declineWebDownload(token: string): void {
  if (token.length === 0) {
    return;
  }
  nativeDeclineWebSession(token);
  markWebDownloadDeclined(token);
  logger.info('Web 下载已拒绝 token=' + token);
  notifyChange();
}

/**
 * 待确认超时：结束原生侧决策通道，使浏览器收到「等待确认超时」而不是无限等待。
 * 本地会话终态由适配器同帧收口，此处只负责协议侧。
 */
export function expireWebDownload(token: string): void {
  if (token.length === 0) {
    return;
  }
  try {
    nativeExpireWebSession(token);
    logger.info('Web 下载等待确认超时 token=' + token);
  } catch (_e) {
    // 决策已被处理或会话已过期：属正常竞态，不改变本地终态
  }
}

/**
 * 应用网页总开关：关闭时若服务运行则停止（含进行中会话由调用方经二次确认中断）。
 * 开启时不做任何事（服务按需启动）。
 */
export function applyWebEnabled(enabled: boolean): void {
  if (enabled) {
    return;
  }
  if (shareLinkInfo.length > 0) {
    stopShareLink().catch((e: Error) => {
      logger.error('网页总开关关闭后停止服务失败: ' + String(e));
    });
  }
}

/**
 * 是否存在活跃的网页下载会话。
 * 判定取自统一会话注册表，不在此维护第二套状态。
 */
export function hasActiveWebDownloads(): boolean {
  return getActiveWebDownloadCount() > 0;
}

/** 未终态的网页下载会话数（发送页菜单后缀用）。 */
export function getActiveWebDownloadCount(): number {
  let count: number = 0;
  let all: Array<TransferSession> = querySessions();
  for (let i = 0; i < all.length; i++) {
    let session = all[i];
    if (session.protocolKey === WEB_DOWNLOAD_KEY && !isTerminalStage(session.stage)) {
      count++;
    }
  }
  return count;
}

/** 未终态的网页上传会话数（发送页菜单后缀用）。 */
export function getActiveWebUploadCount(): number {
  let count: number = 0;
  let all: Array<TransferSession> = querySessions();
  for (let i = 0; i < all.length; i++) {
    let session = all[i];
    if (session.protocolKey === WEB_UPLOAD_KEY && !isTerminalStage(session.stage)) {
      count++;
    }
  }
  return count;
}

// 注册 Web 下载确认/拒绝/超时入口：任务的待确认操作经适配器回调本仓库
setWebDownloadInvokers(
  (token: string): void => {
    acceptWebDownload(token);
  },
  (token: string): void => {
    declineWebDownload(token);
  },
  (token: string): void => {
    expireWebDownload(token);
  }
);

// ── Web 上传事件（由 handleNativeEvent 路由；token 即浏览器会话标识） ──

/** 上传待确认请求到达：登记入站会话（文件清单来自浏览器声明）。 */
export function handlePrepareUploadTyped(event: NativeWebUploadPrepareEvent): void {
  let token: string = event.token;
  if (token.length === 0) {
    logger.warn('WebPrepareUpload 事件 token 为空，已忽略');
    return;
  }
  let ip: string = event.ip;
  logger.info('收到 Web 上传请求 ip=' + ip + '（token=' + token + '）');
  // 入站上传一律需确认（陌生设备向本机发送文件，不设免确认）。
  let descriptors: Array<SessionFileDescriptor> = [];
  for (let i = 0; i < event.files.length; i++) {
    let f: NativeTransferFileInfo = event.files[i];
    descriptors.push({
      fileId: f.fileId,
      fileName: f.fileName,
      fileType: f.fileType,
      totalBytes: f.size
    });
  }
  beginWebUploadBurst(token, true, descriptors, ip);
  notifyChange();
}

// Web 上传字节级进度：同步到统一会话，终态由适配器按静默窗口判定
export function handleWebUploadProgressTyped(event: NativeWebUploadProgressEvent): void {
  let token: string = event.token;
  let fileId: string = event.fileId;
  if (token.length === 0 || fileId.length === 0) {
    return;
  }
  handleWebUploadProgress(token, fileId, event.receivedBytes, event.totalBytes);
  notifyChange();
}

// Web 上传文件落盘完成：服务端已给出最终路径，回填并记完成
export function handleWebUploadDoneTyped(event: NativeWebUploadDoneEvent): void {
  let token: string = event.token;
  let fileId: string = event.fileId;
  if (token.length === 0 || fileId.length === 0) {
    return;
  }
  handleWebUploadDone(token, fileId, event.path);
  notifyChange();
}

/** 按 token 终结指定的网页上传会话（终态收口；不存在或已终态时静默返回）。 */
function finishWebUploadSession(token: string, stage: SessionStage, reason?: string,
  code?: string): void {
  let targets: Array<TransferSession> = querySessions();
  for (let i = 0; i < targets.length; i++) {
    let target = targets[i];
    if (target.protocolKey === WEB_UPLOAD_KEY && target.protocolSessionId === token &&
      !isTerminalStage(target.stage)) {
      finish(target.id, stage, reason, code);
      return;
    }
  }
}

/** 服务端终结通知：待确认阶段直接取消；进行中交由适配器静默判定收口。 */
export function handleWebUploadFinished(token: string): void {
  if (token.length === 0) {
    return;
  }
  let all: Array<TransferSession> = querySessions();
  for (let i = 0; i < all.length; i++) {
    let session = all[i];
    if (session.protocolKey === WEB_UPLOAD_KEY && session.protocolSessionId === token &&
      !isTerminalStage(session.stage)) {
      if (session.stage === SessionStage.awaitingConfirmation) {
        finishWebUploadSession(token, SessionStage.cancelled, '等待确认超时', 'pending_timeout');
      }
      return;
    }
  }
}

// ── Web 上传确认操作（入参为浏览器 token） ──

/** 接受上传：先下发落盘目标（Download 去重 / 文本消息走接收文本目录），再放行。 */
export function acceptWebUpload(token: string): void {
  if (token.length === 0) {
    return;
  }
  // 落盘目标计算需异步（Download 目录授权）：浏览器在等待决策，
  // 此处 fire-and-forget，完成后放行或拒绝。
  prepareUploadTargets(token).then((ready: boolean): void => {
    if (!ready) {
      declineWebUpload(token);
      return;
    }
    try {
      nativeAcceptWebSession(token);
    } catch (e) {
      logger.error('接受上传失败 token=' + token + '：' + e);
      declineWebUpload(token);
      return;
    }
    markWebUploadAccepted(token);
    logger.info('Web 上传已接受 token=' + token);
    notifyChange();
  }).catch((): void => {
    declineWebUpload(token);
  });
}

export function declineWebUpload(token: string): void {
  if (token.length === 0) {
    return;
  }
  nativeDeclineWebSession(token);
  markWebUploadDeclined(token);
  logger.info('Web 上传已拒绝 token=' + token);
  notifyChange();
}

/** 待确认超时：结束原生侧决策通道。 */
export function expireWebUpload(token: string): void {
  if (token.length === 0) {
    return;
  }
  try {
    nativeExpireWebSession(token);
    logger.info('Web 上传等待确认超时 token=' + token);
  } catch (_e) {
    // 决策已被处理或会话已过期：属正常竞态
  }
}

/**
 * 是否存在活跃的网页上传会话。
 * 判定取自统一会话注册表，不在此维护第二套状态。
 */
export function hasActiveWebUploads(): boolean {
  return getActiveWebUploadCount() > 0;
}

// 注册 Web 上传确认/拒绝/超时入口
setWebUploadInvokers(
  (token: string): void => {
    acceptWebUpload(token);
  },
  (token: string): void => {
    declineWebUpload(token);
  },
  (token: string): void => {
    expireWebUpload(token);
  }
);

// ── 上传落盘目标与历史归档 ──

/**
 * 为待确认上传会话计算落盘目标并下发原生层。
 * 普通文件进 Download/<包名>/（重名自动加后缀）；单文本消息（message.txt）
 * 进接收文本目录。目录不可用时返回 false，调用方据此拒绝。
 */
async function prepareUploadTargets(token: string): Promise<boolean> {
  let session = findWebUploadSession(token);
  if (session === undefined) {
    return false;
  }
  let downloadDir: string = '';
  try {
    downloadDir = await ensureRecvDownloadDir();
  } catch (_e) {
    downloadDir = '';
  }
  if (downloadDir.length === 0) {
    logger.error('上传落盘目录不可用 token=' + token);
    return false;
  }
  let textDir: string = recvTextDir();
  if (textDir.endsWith('/')) {
    textDir = textDir.substring(0, textDir.length - 1);
  }
  let isTextMessage: boolean = session.files.length === 1 &&
    session.files[0].fileType === 'text/plain' &&
    session.files[0].fileName === 'message.txt';
  interface UploadTargetJson {
    fileId: string
    path: string
  }
  let targets: Array<UploadTargetJson> = [];
  for (let i = 0; i < session.files.length; i++) {
    let f = session.files[i];
    let dir: string = isTextMessage ? textDir : downloadDir;
    if (dir.length === 0) {
      logger.error('上传落盘目录缺失 token=' + token);
      return false;
    }
    targets.push({ fileId: f.fileId, path: dir + '/' + uniquePath(dir, f.fileName) });
  }
  let applied: number = 0;
  try {
    applied = nativeSetWebUploadTargets(token, JSON.stringify(targets));
  } catch (e) {
    logger.error('下发上传目标失败 token=' + token + '：' + e);
    return false;
  }
  if (applied !== targets.length) {
    logger.warn('上传目标部分未生效 token=' + token + ' applied=' + applied);
    return false;
  }
  return true;
}

/** 按 token 查找未终态的网页上传会话。 */
function findWebUploadSession(token: string): TransferSession | undefined {
  let all: Array<TransferSession> = querySessions();
  for (let i = 0; i < all.length; i++) {
    let session = all[i];
    if (session.protocolKey === WEB_UPLOAD_KEY && session.protocolSessionId === token &&
      !isTerminalStage(session.stage)) {
      return session;
    }
  }
  return undefined;
}

// 已归档终态上传会话（统一会话标识集合）：避免重复归档
let archivedUploadSessions: Record<string, boolean> = {};

// 是否已订阅统一会话变更（归档监听只注册一次）
let uploadArchiveSubscribed: boolean = false;

/** 确保上传归档监听已注册（首次启动服务时调用）。 */
function ensureUploadArchiveSubscribed(): void {
  if (uploadArchiveSubscribed) {
    return;
  }
  uploadArchiveSubscribed = true;
  subscribeSessions(() => {
    archiveFinishedUploads();
  });
}

/** 终态上传会话归档：落盘位置已在接受时确定，此处只写接收历史。 */
function archiveFinishedUploads(): void {
  let all: Array<TransferSession> = querySessions();
  for (let i = 0; i < all.length; i++) {
    let session = all[i];
    if (session.protocolKey !== WEB_UPLOAD_KEY || !isTerminalStage(session.stage)) {
      continue;
    }
    if (session.stage !== SessionStage.succeeded) {
      continue;
    }
    if (archivedUploadSessions[session.id] === true) {
      continue;
    }
    archivedUploadSessions[session.id] = true;
    archiveUploadHistory(session);
  }
}

/** 写上传会话的接收历史（文件条目 + 文本消息判定）。 */
function archiveUploadHistory(session: TransferSession): void {
  let entries: Array<ReceiveHistoryEntry> = [];
  let senderAlias: string = 'Web Browser';
  let isTextMessage: boolean = session.files.length === 1 &&
    session.files[0].fileType === 'text/plain' &&
    session.files[0].fileName === 'message.txt';
  for (let i = 0; i < session.files.length; i++) {
    let f = session.files[i];
    let displayFileName: string = f.fileName;
    let lastSlash: number = f.path.lastIndexOf('/');
    if (f.path.length > 0 && lastSlash >= 0) {
      displayFileName = f.path.substring(lastSlash + 1);
    }
    let fileSize: number = f.totalBytes;
    if (f.path.length > 0) {
      try {
        let stat = fs.statSync(f.path);
        fileSize = stat.size;
      } catch (_e) {
      }
    }
    let entry: ReceiveHistoryEntry = {
      id: session.id + '_' + i,
      fileName: displayFileName,
      fileType: f.fileType,
      path: f.path,
      savedToGallery: false,
      isMessage: isTextMessage,
      fileSize: fileSize,
      senderAlias: senderAlias,
      timestamp: Date.now()
    };
    if (isTextMessage) {
      entry.textContent = readTextOfLocation(f.path) ?? '';
    }
    entries.push(entry);
  }
  if (entries.length > 0) {
    addHistoryEntries(entries);
    logger.info('Web 上传已归档接收历史 token=' + session.protocolSessionId);
  }
}
