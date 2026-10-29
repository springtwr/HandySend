import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { SendFileItem, ReceiveHistoryEntry } from '../../model/Types';
import {
  SessionFileDescriptor,
  SessionFileStage,
  SessionStage,
  TransferSession,
  isTerminalStage
} from '../../model/transfer/TransferSession';
import {
  NativeTransferFileInfo,
  NativeWebAccessEvent,
  NativeWebDownloadStartedEvent,
  NativeWebDownloadProgressEvent,
  NativeWebDownloadFileDoneEvent,
  NativeWebDownloadEndedEvent,
  NativeWebUploadDoneEvent,
  NativeWebUploadPrepareEvent,
  NativeWebUploadProgressEvent
} from '../../model/NativeTypes';
import {
  nativeStartWebService,
  nativeStopWebService,
  nativeMarkWebServiceStopped,
  nativeUpdateWebServiceFiles,
  nativeSetWebServiceUploadEnabled,
  nativeAcceptWebSession,
  nativeDeclineWebSession,
  nativeExpireWebSession,
  nativeSweepWebSessions,
  nativeSetWebUploadTargets
} from '../NativeBridge';
import { getAppContext, getLocalInterfaces, notifyChange, updateLocalInterfaces } from './AppCore';
import {
  getWebSendAllowed,
  getWebReceiveAllowed,
  getWebHttpsEnabled,
  getWebPort,
  getWebLastPort,
  setWebLastPort,
  getWebInterfaceNames,
  getWebInterfaceBlacklistNames,
  getWebDisplayAddress,
  setWebDisplayAddress
} from './SettingsRepository';
import { getDeviceAlias } from './DeviceRepository';
import {
  WebAddress,
  buildWebUrl,
  isWebPortFallback as isPortFallback,
  listWebAddresses,
  pickWebAddress
} from '../../model/WebAddress';
import { ensureRecvDownloadDir, ensureRecvTextDir, uniquePath } from './ReceiveTargets';
import { addEntries as addHistoryEntries } from './ReceiveHistoryService';
import { readTextOfLocation } from '../../utils/FileTextUtil';
import { generateWebAccessCode } from '../../utils/WebAccessCode';
import {
  WEB_DOWNLOAD_KEY,
  beginWebDownloadBatch,
  handleWebDownloadEnded,
  handleWebDownloadFileDone,
  handleWebDownloadProgress
} from '../transfer/adapters/WebDownloadAdapter';
import {
  WEB_UPLOAD_KEY,
  beginWebUploadBurst,
  finishWebUploadIfAllDone,
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
// 本次服务实例的二维码/URL 能力令牌：随服务启动生成，浏览器扫码后换取 HttpOnly Cookie。
// 服务重启即失效，旧二维码/链接随之作废。
let webCapabilityToken: string = '';
// 本次服务实例的访问码：每次启动生成，仅用于裸地址手动输入；停止/重启即失效。
let webAccessCode: string = '';
// 实际端口与设置端口不一致（首选端口被占用后回退）；面板据此提示
let webPortFallback: boolean = false;

// 当前服务启动时使用的网页配置：文件挂载可原地换表的前提
let webServiceAlias: string = '';
let webServiceHttps: boolean = false;
let webServiceConfiguredPort: number = 0;
// 本次挂载是否允许浏览器上传免确认：与下载免确认对称，停止分享即复位。
let webUploadAutoAccept: boolean = false;

/** 设置本次挂载的上传免确认（仅当前分享有效）。 */
export function setWebUploadAutoAccept(enabled: boolean): void {
  webUploadAutoAccept = enabled;
  logger.info('本次挂载的上传免确认=' + enabled);
  notifyChange();
}

/** 本次挂载是否允许浏览器上传免确认。 */
export function isWebUploadAutoAccept(): boolean {
  return webUploadAutoAccept;
}

/** 本次分享的访问码（服务未启动为空串）。 */
export function getWebAccessCode(): string {
  return webAccessCode;
}

// 分享文件表是否正在替换（避免暂存区连续变化时并发换表）
let webUpdating: boolean = false;

// 停止服务后保留 stopped 页面供网页收尾的时间；超时再真正关闭监听端口
const WEB_STOP_GRACE_MS: number = 30000;
let webStopTimer: number = -1;

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
  // 源文件修改时间（Unix 毫秒，可缺省）：供网页 zip 条目还原时间
  lastModified?: number
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
  lastModified?: number
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
      sha256: f.hash !== undefined ? f.hash : '',
      lastModified: f.lastModified
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
      sha256: profile.sha256,
      lastModified: profile.lastModified
    });
  }
  return JSON.stringify(entries);
}

/**
 * 清空分享源文件档案（停止分享时调用）。
 */
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
  lastModified?: number
}

interface WebServiceConfigJson {
  alias: string
  // 本次分享的 6 位访问码（裸地址手动输入时使用）
  pin?: string
  capability?: string
  uploadEnabled: boolean
  useHttps: boolean
  port: number
  uploadDir: string
  files: Array<WebServiceFileJson>
}

/** 生成二维码/URL 能力令牌（32 位十六进制；失败时退化为时间戳随机串）。 */
function generateWebCapabilityToken(): string {
  try {
    return util.generateRandomUUID(false).replace(/-/g, '');
  } catch (e) {
    logger.warn('生成网页访问令牌失败，改用降级随机串：' + String(e));
    return Date.now().toString(36) + Math.random().toString(36).substring(2);
  }
}

/** 日志中隐去能力令牌，避免诊断日志泄漏可访问凭据。 */
function redactWebToken(url: string): string {
  let index: number = url.indexOf('?t=');
  return index >= 0 ? url.substring(0, index) + '?t=***' : url;
}

/** 组装新服务启动配置（字段名与 Rust WebServiceConfig 对齐）。 */
function buildWebServiceConfig(uploadEnabled: boolean, preferredPort: number): string {
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
      sha256: profile.sha256,
      lastModified: profile.lastModified
    });
  }
  webCapabilityToken = generateWebCapabilityToken();
  let config: WebServiceConfigJson = {
    alias: getDeviceAlias(),
    uploadEnabled: uploadEnabled,
    useHttps: getWebHttpsEnabled(),
    port: preferredPort,
    uploadDir: webUploadStageDir(),
    files: files
  };
  if (webAccessCode.length > 0) {
    config.pin = webAccessCode;
  }
  if (webCapabilityToken.length > 0) {
    config.capability = webCapabilityToken;
  }
  return JSON.stringify(config);
}

/** 服务启动失败：清掉运行时地址与端口，避免面板继续展示已停止服务的旧地址。 */
function markWebServiceUnavailable(): void {
  sharePort = 0;
  shareLinkInfo = '';
  webPortFallback = false;
  webUploadEnabled = false;
  // 启动失败时若仍残留上一个停止态实例，也安排一次硬停止兜底
  scheduleWebStop();
  notifyChange();
}

/** 以当前挂载与上传开关启动服务（调用方已备好文件句柄与档案）。 */
async function startWebServiceLocked(uploadEnabled: boolean): Promise<boolean> {
  // 任何重新启服都取消旧的延时停止，避免宽限期结束后误停新实例
  cancelScheduledWebStop();
  // 每次启动生成新的本次访问码：服务重启后旧访问码与旧二维码一起失效。
  webAccessCode = generateWebAccessCode();
  // 网页服务独立于 LocalSend 服务器：不依赖服务器启动时的网卡刷新，
  // 自行刷新以取到本机 IP（LocalSend 关闭时本模块仍需给出可用地址）
  updateLocalInterfaces();
  // 进程内优先复用上次实际端口（重启服务时地址不变）；应用重启后 lastPort 为 0，
  // 回到配置端口重新尝试，用户改端口时 setWebPort 也会清空 lastPort
  let preferredPort: number = getWebLastPort() > 0 ? getWebLastPort() : getWebPort();
  let port: number = 0;
  try {
    port = await nativeStartWebService(buildWebServiceConfig(uploadEnabled, preferredPort));
  } catch (e) {
    logger.error('网页服务启动失败：' + e);
    markWebServiceUnavailable();
    return false;
  }
  if (port <= 0) {
    logger.error('网页服务启动失败：无效 port ' + port);
    markWebServiceUnavailable();
    return false;
  }
  sharePort = port;
  webUploadEnabled = uploadEnabled;
  setWebLastPort(port);
  webPortFallback = isPortFallback(getWebPort(), port);
  webServiceAlias = getDeviceAlias();
  webServiceHttps = getWebHttpsEnabled();
  webServiceConfiguredPort = getWebPort();
  refreshWebAddress();
  if (shareLinkInfo.length > 0) {
    logger.info('网页服务已启动：' + redactWebToken(shareLinkInfo));
  } else {
    logger.warn('网页服务已启动但无可用展示地址 port=' + port);
  }
  return true;
}

export function getShareLink(): string {
  return shareLinkInfo;
}

/** 当前启用的可展示网页地址（按 Wi-Fi → 有线 → VPN → 网桥 → 未知 → 蜂窝排序）。 */
export function getWebAddresses(): Array<WebAddress> {
  return listWebAddresses(getLocalInterfaces(), getWebInterfaceNames(), getWebInterfaceBlacklistNames());
}

/** 当前展示的地址：上次选择优先，失效时回退排序后的第一个。 */
export function getSelectedWebAddress(): WebAddress | undefined {
  return pickWebAddress(getWebAddresses(), getWebDisplayAddress());
}

/**
 * 按当前网卡、展示选择与加密开关重建网页地址（不重启服务）。
 * 网络变化、网卡筛选/展示选择变化、加密开关变化后调用。
 */
export function refreshWebAddress(): void {
  if (sharePort <= 0) {
    shareLinkInfo = '';
    webPortFallback = false;
    notifyChange();
    return;
  }
  let address: WebAddress | undefined = getSelectedWebAddress();
  shareLinkInfo = address !== undefined ?
    buildWebUrl(webServiceHttps, address.ip, sharePort, webCapabilityToken) : '';
  webPortFallback = isPortFallback(getWebPort(), sharePort);
  notifyChange();
}

/** 切换面板展示的地址（按 IP 持久化，供下次进入复用）。 */
export function selectWebDisplayAddress(ip: string): void {
  setWebDisplayAddress(ip);
  refreshWebAddress();
}

/** 当前网页服务实际绑定端口（未启动为 0）。 */
export function getWebActualPort(): number {
  return sharePort;
}

/** 实际端口是否已从设置端口回退（面板据此提示）。 */
export function isWebPortFallback(): boolean {
  return webPortFallback;
}

/**
 * 重启网页服务以应用加密/PIN/端口变更：保留已挂载文件与上传入口。
 * 无文件时按当前上传开关重新起服；有文件时重新挂载（内部会重开句柄并起服）。
 */
export async function restartWebService(): Promise<void> {
  if (sharePort <= 0) {
    return;
  }
  if (hasSharedFiles()) {
    let files: Array<SendFileItem> = [];
    let ids: Array<string> = Object.keys(shareFileProfiles);
    for (let i = 0; i < ids.length; i++) {
      let profile = shareFileProfiles[ids[i]];
      files.push({
        fileId: ids[i],
        filePath: profile.path,
        fileName: profile.fileName,
        fileType: profile.fileType,
        size: profile.size,
        preview: profile.preview,
        hash: profile.sha256,
        lastModified: profile.lastModified
      });
    }
    // 设置已变化：必须重建服务，不能走就地换表
    await createShareLink(files, true);
    return;
  }
  let uploadEnabled: boolean = webUploadEnabled;
  await stopShareLink();
  await startWebServiceLocked(uploadEnabled);
}

/**
 * 当前服务配置是否仍与设置一致。
 * 别名/加密/配置端口变化必须重建服务；文件列表变化可原地换表。
 */
function webServiceConfigMatches(): boolean {
  return getDeviceAlias() === webServiceAlias &&
    getWebHttpsEnabled() === webServiceHttps &&
    getWebPort() === webServiceConfiguredPort;
}

/**
 * 挂载分享并启动服务（网页发送入口）。
 *
 * 服务已在运行时只就地替换文件表，不重启服务、不断开已打开的网页；
 * 仅在服务未运行或调用方要求应用新配置（`restartService = true`）时才重建。
 * 重建流程：先打开新句柄 → 启动成功后再关闭旧句柄并移交，失败时旧分享保持可用。
 */
export async function createShareLink(files: Array<SendFileItem>, restartService: boolean = false): Promise<void> {
  if (!getWebSendAllowed()) {
    logger.warn('网页传输总开关未开启，忽略分享挂载');
    return;
  }
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

  // 服务运行中且无需应用新配置：就地换表，避免选中文件时重启服务
  if (!restartService && sharePort > 0 && webServiceConfigMatches()) {
    let uploadEnabled: boolean = webUploadEnabled || getWebReceiveAllowed();
    reuseShareFileIds(files);
    let mounted: boolean = false;
    try {
      let count: number = nativeUpdateWebServiceFiles(buildWebFilesJsonFor(files, openedHandles));
      mounted = count === files.length;
      if (!mounted) {
        logger.warn('就地挂载分享文件未全部生效：' + count + '/' + files.length);
      }
    } catch (e) {
      logger.warn('就地挂载分享文件失败，回退到重建服务：' + e);
    }
    if (mounted) {
      if (uploadEnabled !== webUploadEnabled) {
        try {
          nativeSetWebServiceUploadEnabled(uploadEnabled);
          webUploadEnabled = uploadEnabled;
        } catch (e) {
          logger.warn('就地更新网页上传入口失败：' + e);
        }
      }
      registerShareFileProfiles(files, openedHandles);
      closeShareFileHandles();
      shareFileHandles = openedHandles;
      // 新一次分享从「需确认」开始：上传免确认只在本次挂载内由面板显式打开
      webUploadAutoAccept = false;
      refreshWebAddress();
      logger.info('分享文件已就地挂载，当前可下载 ' + files.length + ' 个');
      return;
    }
  }

  // 先登记新档案再启动：启动配置据此组装文件表
  let previousProfiles: Record<string, ShareFileProfile> = shareFileProfiles;
  let previousHandles: Array<fs.File> = shareFileHandles;
  registerShareFileProfiles(files, openedHandles);
  let uploadEnabled: boolean = webUploadEnabled || getWebReceiveAllowed();
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
    // 重建流程在尝试绑定前会先停旧实例；启动失败时尽力按旧档案把服务补起来，
    // 避免已挂载的分享因一次设置变更而静默消失。
    if (Object.keys(previousProfiles).length > 0 || uploadEnabled) {
      let recovered: boolean = await startWebServiceLocked(uploadEnabled);
      if (!recovered) {
        logger.error('网页服务重建失败后恢复旧分享也失败');
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
  // 新一次分享从「需确认」开始：上传免确认只在本次挂载内由面板显式打开
  webUploadAutoAccept = false;
}

/** 取消待执行的硬停止（重新启服时调用，避免误停新实例）。 */
function cancelScheduledWebStop(): void {
  if (webStopTimer >= 0) {
    clearTimeout(webStopTimer);
    webStopTimer = -1;
  }
}

/** 停止分享后保留服务一段时间，让页面显示结束态并可短暂刷新，再关闭端口。 */
function scheduleWebStop(): void {
  cancelScheduledWebStop();
  webStopTimer = setTimeout(() => {
    webStopTimer = -1;
    try {
      nativeStopWebService();
    } catch (e) {
      logger.warn('延时停止网页服务失败：' + String(e));
    }
  }, WEB_STOP_GRACE_MS);
}

/** 停止网页服务：关闭句柄、清空档案与地址（幂等）。 */
export async function stopShareLink(): Promise<void> {
  logger.debug('停止分享已调用');
  let wasRunning: boolean = sharePort > 0;
  if (wasRunning) {
    try {
      // 先只标记停止并广播：已打开页面立即显示结束，刷新也可在宽限内看到停止态
      nativeMarkWebServiceStopped();
      scheduleWebStop();
    } catch (e) {
      logger.warn('标记网页服务停止失败：' + String(e));
      try {
        nativeStopWebService();
      } catch (_se) {
      }
    }
  }
  closeShareFileHandles();
  shareLinkInfo = '';
  sharePort = 0;
  webPortFallback = false;
  webServiceAlias = '';
  webServiceHttps = false;
  webAccessCode = '';
  webServiceConfiguredPort = 0;
  clearShareFileProfiles();
  webUploadAutoAccept = false;
  webUploadEnabled = false;
  logger.info('网页分享已停止，服务保留一段时间供页面收尾');
  notifyChange();
}

/**
 * 启动网页上传入口（网页接收入口；无内容前置条件）。
 * 已挂载的分享文件随服务一起提供（单服务双段），不单独重建。
 */
export async function startWebUpload(): Promise<void> {
  if (!getWebSendAllowed()) {
    return;
  }
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
 * 以空文件表热替换；出站方向（网页发送）已关闭时服务随之完全停止。
 */
export async function unmountShare(): Promise<void> {
  if (shareLinkInfo.length === 0) {
    return;
  }
  try {
    let count: number = nativeUpdateWebServiceFiles('[]');
    closeShareFileHandles();
    clearShareFileProfiles();
    webUploadAutoAccept = false;
    // 总开关关闭时停服务；仅撤下文件时保留地址/二维码与上传入口。
    if (!getWebSendAllowed()) {
      await stopShareLink();
      return;
    }
    logger.info('分享文件已撤下，服务按方向开关继续运行');
  } catch (e) {
    logger.error('撤下分享文件失败：' + e);
  }
  notifyChange();
}

/**
 * 关闭浏览器上传入口，已挂载的分享文件保留。
 * 总开关关闭时服务随之停止。
 */
export async function disableWebUpload(): Promise<void> {
  if (shareLinkInfo.length === 0) {
    return;
  }
  try {
    nativeSetWebServiceUploadEnabled(false);
    webUploadEnabled = false;
    // 发送方向仍开放时服务继续运行（即使当前没有挂载文件）
    if (!getWebSendAllowed()) {
      await stopShareLink();
      return;
    }
    logger.info('浏览器上传已关闭，网页发送继续提供');
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
    if (count !== files.length) {
      throw new Error('分享文件未全部挂载 ' + count + '/' + files.length);
    }
    closeShareFileHandles();
    shareFileHandles = openedHandles;
    registerShareFileProfiles(files, shareFileHandles);
    logger.info('分享文件已更新，当前可下载 ' + count + ' 个');
  } catch (e) {
    // 换表失败：先把服务端文件表恢复为旧分享（此时新句柄仍有效，
    // 部分生效的新条目会由原生保留区自行 dup），再关闭本次打开的句柄
    try {
      nativeUpdateWebServiceFiles(buildWebFilesJson());
    } catch (_re) {
    }
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
      sha256: f.hash !== undefined ? f.hash : '',
      lastModified: f.lastModified
    });
  }
  return JSON.stringify(entries);
}

// ── Web 下载事件（批次模型；页面访问只记日志，不建任务） ──

/**
 * 由服务端批次事件的文件清单构造会话描述符。
 * 文件清单以服务端快照为准；本地路径仅用于详情页文本预览，按 fileId 从当前档案补齐。
 */
function descriptorsFromDownloadEvent(files: Array<NativeTransferFileInfo>): Array<SessionFileDescriptor> {
  let result: Array<SessionFileDescriptor> = [];
  for (let i = 0; i < files.length; i++) {
    let f: NativeTransferFileInfo = files[i];
    let descriptor: SessionFileDescriptor = {
      fileId: f.fileId,
      fileName: f.fileName,
      fileType: f.fileType,
      totalBytes: f.size
    };
    let profile: ShareFileProfile | undefined = shareFileProfiles[f.fileId];
    if (profile !== undefined && profile.path.length > 0) {
      descriptor.path = profile.path;
    }
    result.push(descriptor);
  }
  return result;
}

/** 网页访问：只写诊断日志；保活由 AppService 统一处理，不建任务。 */
export function handleWebAccessTyped(event: NativeWebAccessEvent): void {
  if (event.ip.length === 0) {
    return;
  }
  logger.info('网页访问 ip=' + event.ip + ' 文件数=' + event.fileCount +
    ' ua=' + (event.userAgent ?? ''));
}

/** 下载批次开始：一个批次一个任务。 */
export function handleWebDownloadStartedTyped(event: NativeWebDownloadStartedEvent): void {
  if (event.batchId.length === 0) {
    return;
  }
  let descriptors: Array<SessionFileDescriptor> = descriptorsFromDownloadEvent(event.files);
  if (descriptors.length === 0) {
    return;
  }
  beginWebDownloadBatch(event.batchId, event.ip, descriptors);
  logger.info('网页下载开始 batch=' + event.batchId + ' ip=' + event.ip +
    ' 文件数=' + descriptors.length);
  notifyChange();
}

/** 单文件字节进度（zip 内逐条目）。 */
export function handleWebDownloadProgressTyped(event: NativeWebDownloadProgressEvent): void {
  if (event.batchId.length === 0 || event.fileId.length === 0) {
    return;
  }
  handleWebDownloadProgress(event.batchId, event.fileId, event.sentBytes, event.totalBytes);
  notifyChange();
}

/** 单文件完成。 */
export function handleWebDownloadFileDoneTyped(event: NativeWebDownloadFileDoneEvent): void {
  if (event.batchId.length === 0 || event.fileId.length === 0) {
    return;
  }
  handleWebDownloadFileDone(event.batchId, event.fileId, event.totalBytes);
  notifyChange();
}

/** 下载批次终态。 */
export function handleWebDownloadEndedTyped(event: NativeWebDownloadEndedEvent): void {
  if (event.batchId.length === 0) {
    return;
  }
  handleWebDownloadEnded(event.batchId, event.outcome, event.error);
  logger.info('网页下载结束 batch=' + event.batchId + ' 结果=' + event.outcome);
  notifyChange();
}

/**
 * 应用网页传输总开关：开启时拉起服务，上传入口跟随“允许对方上传”；
 * 关闭时停止服务并撤下已挂载文件。
 */
export function applyWebSendAllowed(enabled: boolean): void {
  if (!enabled) {
    stopShareLink().catch((e: Error) => {
      logger.error('网页传输关闭后停止服务失败: ' + String(e));
    });
    return;
  }
  if (shareLinkInfo.length === 0) {
    startWebServiceLocked(getWebReceiveAllowed()).catch((e: Error) => {
      logger.error('网页传输开启后拉起服务失败: ' + String(e));
    });
  } else if (getWebReceiveAllowed() && !webUploadEnabled) {
    startWebUpload().catch((e: Error) => {
      logger.error('网页传输开启后补开上传入口失败: ' + String(e));
    });
  }
}

/**
 * 应用“允许对方上传”开关：总开关开启时控制上传入口；
 * 总开关关闭时子开关不生效（服务已停止）。
 */
export function applyWebReceiveAllowed(enabled: boolean): void {
  if (!getWebSendAllowed()) {
    return;
  }
  if (enabled) {
    ensureWebUpload().catch((e: Error) => {
      logger.error('允许上传开启后确保上传入口失败: ' + String(e));
    });
  } else {
    disableWebUpload().catch((e: Error) => {
      logger.error('允许上传关闭后关闭上传入口失败: ' + String(e));
    });
  }
}

/**
 * 冷启动恢复网页服务：总开关开启时拉起服务，上传入口跟随“允许对方上传”。
 * 网页服务独立于 LocalSend 服务器，必须由自身开关在启动流程中恢复。
 */
export async function restoreWebService(): Promise<void> {
  if (!getWebSendAllowed()) {
    return;
  }
  if (shareLinkInfo.length === 0) {
    await startWebServiceLocked(getWebReceiveAllowed());
    return;
  }
  // 服务已在运行：仅补齐可能缺失的上传入口
  if (getWebReceiveAllowed() && !webUploadEnabled) {
    await startWebUpload();
  }
}

/**
 * 是否存在活跃的网页下载会话。
 * 判定取自统一会话注册表，不在此维护第二套状态。
 */
export function hasActiveWebDownloads(): boolean {
  let all: Array<TransferSession> = querySessions();
  for (let i = 0; i < all.length; i++) {
    let session = all[i];
    if (session.protocolKey === WEB_DOWNLOAD_KEY && !isTerminalStage(session.stage)) {
      return true;
    }
  }
  return false;
}

// ── Web 上传事件（由 handleNativeEvent 路由；token 即浏览器会话标识） ──

/** 上传待确认请求到达：登记入站会话（文件清单来自浏览器声明）。 */
export function handlePrepareUploadTyped(event: NativeWebUploadPrepareEvent): void {
  ensureUploadArchiveSubscribed();
  let token: string = event.token;
  if (token.length === 0) {
    logger.warn('WebPrepareUpload 事件 token 为空，已忽略');
    return;
  }
  let ip: string = event.ip;
  logger.info('收到 Web 上传请求 ip=' + ip + '（token=' + token + '）');
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
  let previewText: string = '';
  if (event.files.length === 1) {
    let f = event.files[0];
    if (f.fileType === 'text/plain' && f.fileName === 'message.txt' && f.preview !== undefined) {
      previewText = f.preview;
    }
  }
  if (webUploadAutoAccept) {
    // 本次挂载已开启上传免确认：先登记为进行中，再按正常接受流程预置落盘目标。
    // 目标目录准备失败时 acceptWebUpload 内部会转为拒绝，不会静默落盘。
    logger.info('Web 上传按本次挂载授权自动接受 token=' + token);
    beginWebUploadBurst(token, false, descriptors, ip, previewText);
    acceptWebUpload(token);
  } else {
    logger.debug('Web 上传进入待确认 token=' + token);
    beginWebUploadBurst(token, true, descriptors, ip, previewText);
  }
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
  // 声明清单已全部落盘（完成回执先于状态刷新到达）：直接按成功收尾
  if (finishWebUploadIfAllDone(token)) {
    return;
  }
  let all: Array<TransferSession> = querySessions();
  for (let i = 0; i < all.length; i++) {
    let session = all[i];
    if (session.protocolKey === WEB_UPLOAD_KEY && session.protocolSessionId === token &&
      !isTerminalStage(session.stage)) {
      if (session.stage === SessionStage.awaitingConfirmation) {
        finishWebUploadSession(token, SessionStage.cancelled, '等待确认超时', 'pending_timeout');
      } else if (session.stage === SessionStage.active) {
        let completed: number = session.files.filter((file) =>
          file.stage === SessionFileStage.completed ||
          (file.totalBytes > 0 && file.bytesSent >= file.totalBytes)).length;
        if (completed > 0) {
          finishWebUploadSession(token, SessionStage.partiallyFailed, '网页已关闭，部分文件已上传',
            'upload_session_ended');
        } else {
          finishWebUploadSession(token, SessionStage.cancelled, '网页已关闭，上传已中断',
            'upload_session_ended');
        }
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
  try {
    nativeDeclineWebSession(token);
  } catch (e) {
    logger.warn('拒绝 Web 上传失败 token=' + token + '：' + String(e));
  }
  markWebUploadDeclined(token);
  logger.info('Web 上传已拒绝 token=' + token);
  notifyChange();
}

/** 结束原生侧网页上传会话：待确认超时或用户结束任务。 */
export function expireWebUpload(token: string): void {
  if (token.length === 0) {
    return;
  }
  try {
    nativeExpireWebSession(token);
    logger.info('Web 上传会话已终结 token=' + token);
  } catch (_e) {
    // 决策已被处理或会话已过期：属正常竞态
  }
}

/**
 * 是否存在活跃的网页上传会话。
 * 判定取自统一会话注册表，不在此维护第二套状态。
 */
export function hasActiveWebUploads(): boolean {
  let all: Array<TransferSession> = querySessions();
  for (let i = 0; i < all.length; i++) {
    let session = all[i];
    if (session.protocolKey === WEB_UPLOAD_KEY && !isTerminalStage(session.stage)) {
      return true;
    }
  }
  return false;
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
  let isTextMessage: boolean = session.files.length === 1 &&
    session.files[0].fileType === 'text/plain' &&
    session.files[0].fileName === 'message.txt';
  // 文本消息只落应用私有文本目录，不依赖 Download 目录授权；
  // 普通文件才需要惰性获取 Download/<包名>/。
  let downloadDir: string = '';
  if (!isTextMessage) {
    try {
      downloadDir = await ensureRecvDownloadDir();
    } catch (_e) {
      downloadDir = '';
    }
    if (downloadDir.length === 0) {
      logger.error('上传落盘目录不可用 token=' + token);
      return false;
    }
  }
  // 文本消息目录是应用沙箱私有目录：首次使用前必须显式创建，
  // 否则服务端创建临时文件会因目录不存在而直接失败。
  let textDir: string = isTextMessage ? ensureRecvTextDir() : '';
  if (isTextMessage && textDir.length === 0) {
    logger.error('上传文本目录不可用 token=' + token);
    return false;
  }
  interface UploadTargetJson {
    fileId: string
    path: string
  }
  let targets: Array<UploadTargetJson> = [];
  // 同一批内同名文件（来自不同目录）也要各自落盘，不能共用同一目标路径
  let reserved: Record<string, boolean> = {};
  for (let i = 0; i < session.files.length; i++) {
    let f = session.files[i];
    let dir: string = isTextMessage ? textDir : downloadDir;
    if (dir.length === 0) {
      logger.error('上传落盘目录缺失 token=' + token);
      return false;
    }
    let fileName: string = uniquePath(dir, f.fileName);
    let serial: number = 1;
    while (reserved[dir + '/' + fileName] === true) {
      let dot: number = f.fileName.lastIndexOf('.');
      let stem: string = dot > 0 ? f.fileName.substring(0, dot) : f.fileName;
      let ext: string = dot > 0 ? f.fileName.substring(dot) : '';
      fileName = uniquePath(dir, stem + ' (' + serial + ')' + ext);
      serial++;
    }
    reserved[dir + '/' + fileName] = true;
    targets.push({ fileId: f.fileId, path: dir + '/' + fileName });
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
  let senderAlias: string = session.peer.displayName.length > 0 ? session.peer.displayName : 'Web Browser';
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
