import { fileIo as fs } from '@kit.CoreFileKit';
import { i18n } from '@kit.LocalizationKit';
import { getLogger } from '../../utils/Logger';
import { LogContext } from '../../common/LogFormat';
import { LogDomains } from '../../common/LogDomains';
import { LANGUAGE_LIST } from '../../common/LanguageConstants';
import { SendFileItem } from '../../model/Types';
import {
  SessionFileDescriptor,
  TransferSession,
  isTerminalStage
} from '../../model/transfer/TransferSession';
import {
  NativeFileToSend,
  NativeWebSendPrepareDownloadEvent,
  NativeWebSendFileDownloadEvent,
  NativeWebSendProgressEvent
} from '../../model/NativeTypes';
import {
  nativeCreateShareLink,
  nativeStopShareServer,
  nativeStartWebUpload,
  nativeConfigureWebService,
  nativeUpdateWebFiles,
  nativeAcceptWebDownload,
  nativeDeclineWebDownload,
  nativeExpireWebDownload
} from '../NativeBridge';
import { getAppContext, notifyChange } from './AppCore';
import { getLocale, getHttpsEnabled } from './SettingsRepository';
import { getDeviceAlias, getLocalDeviceInfo } from './DeviceRepository';
import {
  WEB_DOWNLOAD_KEY,
  beginWebDownloadBurst,
  handleWebDownloadProgress,
  handleWebFileDownload,
  markWebDownloadAccepted,
  markWebDownloadDeclined,
  setWebDownloadInvokers
} from '../transfer/adapters/WebDownloadAdapter';
import { querySessions } from '../transfer/TransferSessionRegistry';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:WebShareRepository', '网页分享');

/**
 * 读取传给网页文案本地化的语言值（BCP47 串），供原生层选择文案集。
 *
 * 以应用语言设置状态为准：`getLocale()` 返回 `''`（跟随系统）/`zh`/`zh-TW`/`en`，
 * 经 `LANGUAGE_LIST` 映射为 BCP47（value → bcp47 单一数据源，避免重复映射）；
 * 未登记的取值原样透传（与设置侧口径一致）；`''`（跟随系统）时回退系统语言；
 * 全部取不到时返回空串，交由原生层回退简体中文，绝不中断分享/接收流程。
 */
function getWebLocaleBcp47(): string {
  let locale: string = '';
  let systemLanguage: string = '';
  try {
    locale = getLocale();
    systemLanguage = i18n.System.getSystemLanguage();
  } catch (_e) {
    // 任一处读取异常：保留已取到的值，缺失项按空值处理
  }
  if (locale.length > 0) {
    for (let i = 0; i < LANGUAGE_LIST.length; i++) {
      if (LANGUAGE_LIST[i].value === locale) {
        return LANGUAGE_LIST[i].bcp47;
      }
    }
    // 未登记的应用语言设置：原样透传
    return locale;
  }
  // 「跟随系统」或未设置：回退系统语言（取不到则为空串，由原生层回退简体中文）
  return systemLanguage;
}

// ── Web 分享链接状态 ──

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

// 网页服务当前是否开放浏览器上传：决定 `/upload` 是否可用，也是重复进入面板时免于重建的依据
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
// 创建失败、切换上传模式时统一 closeSync 关闭。
let shareFileHandles: Array<fs.File> = [];

// 当前分享的源文件档案（fileId → 文件信息）：分享创建成功后写入，
// 下载事件按 fileId 命中回填本地内容位置；重建服务（关上传/重挂）时据此还原文件表。
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

/** 清空分享源文件档案（停止分享/切换上传模式时调用）。 */
function clearShareFileProfiles(): void {
  shareFileProfiles = {};
}

/**
 * 关闭当前分享持有的全部源文件句柄并清空。
 * 调用时机由调用方保证：须在服务器已停止接受该分享的下载请求之后
 * （stopShareLink/startWebUpload 的 native 调用返回后，或创建新分享
 * 替换旧分享时），避免"句柄关闭后仍被下载读取"的竞态。
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

// ── Web 下载的确认与终态 ──
//
// 待确认列表与终态判定均由统一会话引擎承担：会话在 WebDownloadAdapter 内建立，
// 静默窗口与无活动超时在那里判定。本层只负责把协议事件转给适配器，
// 确认/拒绝按适配器回调下发的客户端 IP 直接送达原生层。

export function getShareLink(): string {
  return shareLinkInfo;
}

export async function createShareLink(files: Array<SendFileItem>): Promise<void> {
  let appContext = getAppContext();
  if (appContext === undefined) {
    logger.error('AppService 未初始化');
    return;
  }
  // fd-direct：为每个源文件打开读 fd 一并交给 Rust；本层持有 fs.File
  // 对象至分享结束（Rust 每次下载 dup 副本直读，原始 fd 由本层关闭）
  let nativeFiles: Array<NativeFileToSend> = [];
  let openedHandles: Array<fs.File> = [];
  try {
    for (let i = 0; i < files.length; i++) {
      let f = files[i];
      let file = fs.openSync(f.filePath, fs.OpenMode.READ_ONLY);
      openedHandles.push(file);
      nativeFiles.push({
        fileId: f.fileId,
        filePath: f.filePath,
        fileName: f.fileName,
        fileType: f.fileType,
        size: f.size,
        fd: file.fd,
        preview: f.preview,
        sha256: f.hash
      });
    }
  } catch (e) {
    // 任一源文件打开失败：关闭已打开句柄，不创建链接
    // （旧分享句柄未动，其链接保持可用）
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
  try {
    let result = await nativeCreateShareLink(nativeFiles, getDeviceAlias(), getWebLocaleBcp47());
    // 新分享创建成功：此时才关闭旧分享句柄（先关会造成替换失败时
    // 旧链接悬空——URL 仍有效但源 fd 已失效），并移交新句柄长期持有
    closeShareFileHandles();
    shareFileHandles = openedHandles;
    sharePort = result.port;
    // 使用 ArkTS 侧的本地 IP 构建 URL（比 Rust server_handle 的 IP 更可靠）
    let localIp = getLocalDeviceInfo().ip;
    let protocol = getHttpsEnabled() ? 'https' : 'http';
    shareLinkInfo = protocol + '://' + localIp + ':' + sharePort;
    logger.info('分享链接已创建：' + shareLinkInfo);
    // 新一次分享从「需确认」开始：直接下载授权只在本次挂载内由面板显式打开
    webDownloadAutoAccept = false;
    // 登记本次分享的文件档案：供下载事件回填真实文件名与本地内容位置
    registerShareFileProfiles(files, shareFileHandles);
  } catch (e) {
    // 链接创建失败：关闭本次打开的全部句柄；旧分享句柄与链接保持一致可用，
    // 留待 stopShareLink 或下次成功创建时统一收口
    logger.error('分享链接创建失败：' + e);
    for (let k = 0; k < openedHandles.length; k++) {
      try {
        fs.closeSync(openedHandles[k]);
      } catch (_ce) {
      }
    }
  }
  notifyChange();
}

export async function stopShareLink(): Promise<void> {
  logger.debug('停止分享已调用');
  try {
    await nativeStopShareServer();
  } catch (e) {
    // 正常模式重启失败：服务器保持停止，清理由下继续；留痕以便排查恢复失败
    logger.warn('停止分享后正常模式重启失败: ' + String(e));
  }
  // 服务器已停止（不再接受新请求）：关闭分享持有的全部源文件句柄
  closeShareFileHandles();
  shareLinkInfo = '';
  sharePort = 0;
  clearShareFileProfiles();
  webDownloadAutoAccept = false;
  webUploadEnabled = false;
  // 服务器已由 Rust stop_share_server 以正常模式重启
  logger.info('分享服务已停止，服务器已恢复正常模式');
  notifyChange();
}

/**
 * 启动 Web 上传模式：以启用上传的方式重启服务器，
 * 以便浏览器可通过 v2 协议向本设备上传文件。
 */
export async function startWebUpload(): Promise<void> {
  let webCtx: LogContext = { direction: 'share', protocol: getHttpsEnabled() ? 'https' : 'http' };
  logger.debug('httpsEnabled=' + getHttpsEnabled().toString(), webCtx);
  try {
    let uploadPort: number = await nativeStartWebUpload(getWebLocaleBcp47());
    logger.debug('nativeStartWebUpload 已返回 port=' + uploadPort, webCtx);
    if (uploadPort <= 0) {
      logger.error('Web 上传启动失败：无效 port ' + uploadPort);
      notifyChange();
      return;
    }
    // 上传与分享共用一次启动：已挂载的分享文件由原生层保留，
    // 故此处不回收分享句柄与文件档案，仅刷新服务地址
    sharePort = uploadPort;
    webUploadEnabled = true;
    let localIp = getLocalDeviceInfo().ip;
    shareLinkInfo = (getHttpsEnabled() ? 'https' : 'http') + '://' + localIp + ':' + sharePort;
    logger.debug('shareLink=' + shareLinkInfo, webCtx);
    logger.info('Web 上传已启动：' + shareLinkInfo);
  } catch (e) {
    logger.error('Web 上传启动失败：' + e, webCtx);
  }
  notifyChange();
}

/**
 * 撤下已挂载的分享文件，浏览器上传入口按当前状态保留。
 *
 * 以空文件表重建服务；上传未开放时服务随之完全停止（地址变为空串）。
 */
export async function unmountShare(): Promise<void> {
  try {
    let url: string = await nativeConfigureWebService('[]', webUploadEnabled, getWebLocaleBcp47());
    closeShareFileHandles();
    clearShareFileProfiles();
    webDownloadAutoAccept = false;
    shareLinkInfo = url;
    if (url.length === 0) {
      sharePort = 0;
      webUploadEnabled = false;
    }
    logger.info('分享文件已撤下，服务地址=' + url);
  } catch (e) {
    logger.error('撤下分享文件失败：' + e);
  }
  notifyChange();
}

/**
 * 关闭浏览器上传入口，已挂载的分享文件保留。
 *
 * 以当前文件表重建服务；没有分享文件时服务随之完全停止。
 */
export async function disableWebUpload(): Promise<void> {
  try {
    let url: string = await nativeConfigureWebService(buildWebFilesJson(), false,
      getWebLocaleBcp47());
    webUploadEnabled = false;
    shareLinkInfo = url;
    if (url.length === 0) {
      sharePort = 0;
      closeShareFileHandles();
      clearShareFileProfiles();
      webDownloadAutoAccept = false;
    }
    logger.info('浏览器上传已关闭，服务地址=' + url);
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
  let nativeFiles: Array<NativeFileToSend> = [];
  let openedHandles: Array<fs.File> = [];
  try {
    for (let i = 0; i < files.length; i++) {
      let f = files[i];
      let file = fs.openSync(f.filePath, fs.OpenMode.READ_ONLY);
      openedHandles.push(file);
      nativeFiles.push({
        fileId: f.fileId,
        filePath: f.filePath,
        fileName: f.fileName,
        fileType: f.fileType,
        size: f.size,
        fd: file.fd,
        preview: f.preview,
        sha256: f.hash
      });
    }
    let count: number = nativeUpdateWebFiles(JSON.stringify(nativeFiles));
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

// ── Web 下载事件（由 handleNativeEvent 路由） ──

export function handlePrepareDownloadTyped(event: NativeWebSendPrepareDownloadEvent): void {
  let sessionId: string = event.sessionId;
  if (sessionId.length === 0) {
    logger.warn('WebPrepareDownload 事件 sessionId 为空，已忽略');
    return;
  }
  let ip: string = event.ip;

  // 网页场景 sessionId 即客户端 IP，打完整值便于定位问题
  logger.debug('sessionId=' + sessionId + ' ip=' + ip, { direction: 'share' });
  logger.info('收到 Web 下载请求 ip=' + ip + '（session=' + sessionId + '）');

  // 是否直接放行由本次挂载的授权决定；未授权时进入待确认会话，
  // 由统一的新传输弹窗与任务页处理，本层不再维护第二套请求队列
  if (webDownloadAutoAccept) {
    logger.debug('Web 下载已按本次挂载授权直接放行');
    nativeAcceptWebDownload(sessionId);
    beginWebDownloadBurst(ip, false, shareFileDescriptors());
    markWebDownloadAccepted(ip);
  } else {
    logger.debug('Web 下载进入待确认（本次挂载未授权直接放行）');
    beginWebDownloadBurst(ip, true, shareFileDescriptors());
  }
  notifyChange();
}

export function handleFileDownloadTyped(event: NativeWebSendFileDownloadEvent): void {
  if (event.sessionId.length > 0) {
    logger.debug('sessionId=' + event.sessionId + ' fileId=' + event.fileId + ' name=' +
      event.fileName + ' size=' + event.size, { fileId: event.fileId, direction: 'share' });
    logger.info('Web 文件下载：' + event.fileName + '（' + event.size + ' 字节）session=' +
      event.sessionId);
    // 按事件携带的真实文件名登记文件并重置静默窗口；
    // 命中分享文件档案时一并透传本地内容位置，供文本内容预览读取
    let profile: ShareFileProfile | undefined = shareFileProfiles[event.fileId];
    let localPath: string = profile !== undefined ? profile.path : '';
    handleWebFileDownload(event.sessionId, event.fileId, event.fileName, event.size, localPath);
    notifyChange();
  }
}

// Web 下载字节级进度：同步到统一会话，终态由适配器按静默窗口判定
export function handleWebSendProgressTyped(event: NativeWebSendProgressEvent): void {
  let sessionId: string = event.sessionId;
  let fileId: string = event.fileId;
  if (sessionId.length === 0 || fileId.length === 0) {
    return;
  }
  handleWebDownloadProgress(sessionId, fileId, event.sentBytes, event.totalBytes);
  notifyChange();
}

// ── Web 下载确认操作 ──
//
// 入参为协议层会话标识（网页场景即客户端 IP）：适配器从统一会话取对端 IP 下发，
// 本层不依赖任何本地请求队列。

export function acceptWebDownloadByIp(ip: string): void {
  if (ip.length === 0) {
    return;
  }
  nativeAcceptWebDownload(ip);
  markWebDownloadAccepted(ip);
  logger.info('Web 下载已接受 ip=' + ip);
  notifyChange();
}

export function declineWebDownloadByIp(ip: string): void {
  if (ip.length === 0) {
    return;
  }
  nativeDeclineWebDownload(ip);
  markWebDownloadDeclined(ip);
  logger.info('Web 下载已拒绝 ip=' + ip);
  notifyChange();
}

/**
 * 待确认超时：结束原生侧决策通道，使浏览器收到「等待确认超时」而不是无限等待。
 * 本地会话终态由适配器同帧收口，此处只负责协议侧。
 */
export function expireWebDownloadByIp(ip: string): void {
  if (ip.length === 0) {
    return;
  }
  try {
    nativeExpireWebDownload(ip);
    logger.info('Web 下载等待确认超时 ip=' + ip);
  } catch (_e) {
    // 决策已被处理或会话已过期：属正常竞态，不改变本地终态
  }
}

/**
 * 是否存在活跃的网页下载会话。
 * 网页下载不占用原生层的活动传输表，证书重置等会中断长连接的操作需单独判定；
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

// 注册 Web 下载确认/拒绝入口：任务的待确认操作经适配器回调本仓库
setWebDownloadInvokers(
  (ip: string): void => {
    acceptWebDownloadByIp(ip);
  },
  (ip: string): void => {
    declineWebDownloadByIp(ip);
  },
  (ip: string): void => {
    expireWebDownloadByIp(ip);
  }
);
