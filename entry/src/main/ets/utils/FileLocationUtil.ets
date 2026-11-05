/**
 * FileLocationUtil.ets — 文件定位归一与打开能力（跨页公用）
 *
 * 统一处理条目持有的两种定位形式（沙箱绝对路径 / 文件选择器返回的 file:// URI），并按来源类别区分能力：
 * - 定位归一：得到本机绝对路径与对外统一资源标识（URI），并标注是否为图库来源，解析失败视为不可定位；
 * - 「打开所在位置」：仅对非图库来源提供，经系统文件管理器打开文件所在目录；图库来源由界面层置灰
 *   （见 isGalleryLocation），本层不提供该动作；
 * - 「用其他应用打开」：以隐式 Want 调起系统应用选择框，文件以只读方式对外授权，图库来源在资源可用时同样可用。
 *
 * 所有执行入口只返回结果态，不自行弹提示，由调用方决定文案。
 * 已知限制：文件选择器返回的 file:// 定位，其临时授权通常无法转授给第三方应用，
 * 此时「用其他应用打开」以失败结果收口（不静默、不崩溃）。
 *
 * 图库来源的定位为媒体库虚拟标识（file://media/Photo/...），没有文件管理器可导航的真实目录，
 * 且官方明确禁止截断 / 换算该标识后用于普通文件操作，故其存在性判定以资源标识本身为准。
 * 系统图库也未提供「打开指定媒体资源」的公开入口，故「打开所在位置」对图库来源无合理语义、由界面层置灰；
 * 「用其他应用打开」保留为图库来源的打开出口。
 */

import { common, OpenLinkOptions, Want, wantConstant } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { getMimeForFileName } from './MimeUtils';
import { getLogger } from './Logger';
import { ensureUriAccess, ensureWritableUriAccess } from './UriPermission';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:FileLocation', '文件定位');

/** 隐式 Want 的「查看数据」action（文件打开场景固定值）。 */
const ACTION_VIEW_DATA: string = 'ohos.want.action.viewData';

/** 系统文件管理器的「打开目录」链接。 */
const LINK_OPEN_DIRECTORY: string = 'filemanager://openDirectory';

/**
 * 图库资源标识前缀（媒体库图片 / 视频）：形式为
 * file://media/Photo/<ID>/<真实文件名(无后缀)>/<displayName>。
 * 该标识为媒体库虚拟路径，无文件管理器可导航目录，按官方要求不得截断 / 换算后用于普通文件操作。
 */
const MEDIA_PHOTO_PREFIX: string = 'file://media/Photo/';

/** 文件不存在错误码（文件或目录不存在）。 */
const ERR_NO_SUCH_FILE: number = 13900002;

/** 无访问权限错误码：临时授权过期且未做持久化授权时，打开媒体库 / 选择器标识会命中。 */
const ERR_PERMISSION_DENIED: number = 13900012;

/** 操作不被允许错误码（同样按授权缺失处理）。 */
const ERR_OPERATION_NOT_PERMITTED: number = 13900001;

/** 隐式 Want 未匹配到任何应用时的错误码。 */
const ERR_ABILITY_NOT_EXIST: number = 16000001;

/** MIME 缺省值（按文件名无法推导时使用）。 */
const MIME_OCTET_STREAM: string = 'application/octet-stream';

/** 文件定位归一结果。 */
export interface FileLocation {
  /** 本机绝对路径（解析失败为空串；图库来源为空串，不产出可用于普通文件操作的本机路径） */
  localPath: string
  /** 对外统一资源标识（file:// 形式；解析失败为空串） */
  uri: string
  /** 是否可定位（可执行打开动作） */
  locatable: boolean
  /** 是否为图库来源（媒体库图片 / 视频资源标识）：存在性判定与界面可用性判定的依据 */
  isGalleryResource: boolean
}

/** 打开类操作的结果态（调用方据此给出明确提示）。 */
export enum FileOpenResult {
  success = 'success',
  /** 文件已被移动 / 删除 */
  fileMissing = 'fileMissing',
  /**
   * 访问授权已失效：文件仍在原处，但应用已没有读取权限。
   * 典型来源：文件选择器标识的临时授权超过有效期（与进程是否重启无关）
   * 且该 URI 未做过持久化授权；图库标识无法区分「不存在」与「无授权」，按缺失收口。
   */
  accessDenied = 'accessDenied',
  /** 定位不可用（空定位或解析失败，含授权无法转授） */
  unavailable = 'unavailable',
  /** 系统未找到可处理该文件的应用 */
  noApp = 'noApp',
  /** 调起失败（含用户取消） */
  failed = 'failed'
}

/** 定位探测结果（内部使用，供存在性与授权两类判定共用一次探测）。 */
enum FileProbe {
  readable = 'readable',
  missing = 'missing',
  denied = 'denied'
}

/** 不可定位结果（保留原串仅用于诊断，不参与打开）。 */
function unlocatable(): FileLocation {
  return { localPath: '', uri: '', locatable: false, isGalleryResource: false };
}

/**
 * 定位归一：
 * - 图库来源（媒体库图片 / 视频标识）：原串即对外 URI，标记为图库来源，不产出本机路径；
 * - 沙箱 / 绝对路径：直接作为本机路径，经 fileUri 换算对外 URI；
 * - 其余 file:// 形式：经 FileUri 取出本机路径，原串即对外 URI；
 * 解析失败即视为不可定位。
 */
export function normalizeFileLocation(location: string): FileLocation {
  if (location.length === 0) {
    return unlocatable();
  }
  if (location.startsWith(MEDIA_PHOTO_PREFIX)) {
    return { localPath: '', uri: location, locatable: true, isGalleryResource: true };
  }
  if (!location.startsWith('file://')) {
    try {
      let uri: string = fileUri.getUriFromPath(location);
      if (uri.length === 0) {
        return unlocatable();
      }
      return { localPath: location, uri: uri, locatable: true, isGalleryResource: false };
    } catch (e) {
      logger.warn('路径转 URI 失败 path=' + location + ' 原因=' + String(e));
      return unlocatable();
    }
  }
  try {
    let localPath: string = new fileUri.FileUri(location).path;
    if (localPath.length === 0) {
      return unlocatable();
    }
    return { localPath: localPath, uri: location, locatable: true, isGalleryResource: false };
  } catch (e) {
    logger.warn('URI 解析失败 uri=' + location + ' 原因=' + String(e));
    return unlocatable();
  }
}

/**
 * 是否为图库来源（媒体库图片 / 视频资源标识）：识别规则与 normalizeFileLocation 一致。
 * 供界面层判定「打开所在位置」是否置灰——图库来源无文件管理器可导航目录，该动作无合理语义。
 */
export function isGalleryLocation(path: string): boolean {
  return path.startsWith(MEDIA_PHOTO_PREFIX);
}

/**
 * 按对外 URI 探测（图库标识与选择器 URI 共用）：打开后经文件描述符取属性校验，
 * 正常 / 异常路径都关闭文件对象，不换算本机路径（换算后的路径本应用通常无访问权，
 * 用它判定存在性会把可正常打开的文件误判为缺失）。
 * 失败时按错误码区分「文件确实不存在」「授权已失效」与其他异常。
 */
function probeByUri(uri: string, gallery: boolean = false): FileProbe {
  if (uri.length === 0) {
    return FileProbe.missing;
  }
  let file: fs.File | undefined = undefined;
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    return fs.statSync(file.fd).isFile() ? FileProbe.readable : FileProbe.missing;
  } catch (e) {
    logger.warn('文件定位探测失败 uri=' + uri + ' 原因=' + String(e));
    if (gallery) {
      // 媒体库对「资源不存在」与「无访问授权」返回同类错误，无法区分；
      // 图库标识只需回答「能否打开」，失败即按缺失收口（与原行为一致）
      return FileProbe.missing;
    }
    return probeErrorOf(e);
  } finally {
    if (file !== undefined) {
      try {
        fs.closeSync(file);
      } catch (_closeErr) {
      }
    }
  }
}

/**
 * 探测失败的错误码归类：仅「文件不存在」判为缺失，权限类错误判为授权失效，
 * 其余异常按可读处理（交由打开动作给出真实结果）。
 */
function probeErrorOf(e: Object): FileProbe {
  let code: number = (e as BusinessError).code;
  if (code === ERR_NO_SUCH_FILE) {
    return FileProbe.missing;
  }
  if (code === ERR_PERMISSION_DENIED || code === ERR_OPERATION_NOT_PERMITTED) {
    return FileProbe.denied;
  }
  return FileProbe.readable;
}

/**
 * 定位探测：不可定位视为缺失。
 * 图库标识与选择器 URI 一律按对外 URI 打开校验（与「用其他应用打开」同一方式）——
 * 由 URI 换算出的本机路径本应用通常没有访问权，用它对选择器来源文件判定存在性
 * 会把可正常打开的文件误判为缺失；仅在 URI 探测为非缺失结论、且存在本机路径时，
 * 才用本机路径做补充判定（沙箱文件即属此类）。
 * 存在性与授权两类判定共用本函数的结果，避免重复读盘。
 */
function probeFile(location: FileLocation): FileProbe {
  if (!location.locatable) {
    return FileProbe.missing;
  }
  if (location.isGalleryResource) {
    return probeByUri(location.uri, true);
  }
  let byUri: FileProbe = location.uri.length > 0 ? probeByUri(location.uri) : FileProbe.missing;
  if (byUri === FileProbe.readable) {
    return FileProbe.readable;
  }
  // URI 打不开不等于文件不可用：接收文件等公共目录路径按本机路径可读，
  // 两路结论合并后判定（任一路可读即可读；否则任一路无权限即视为无权限）
  let byPath: FileProbe = FileProbe.missing;
  if (location.localPath.length > 0) {
    try {
      byPath = fs.accessSync(location.localPath) ? FileProbe.readable : FileProbe.missing;
    } catch (e) {
      byPath = probeErrorOf(e);
    }
  }
  if (byPath === FileProbe.readable) {
    return FileProbe.readable;
  }
  if (byUri === FileProbe.denied || byPath === FileProbe.denied) {
    return FileProbe.denied;
  }
  return FileProbe.missing;
}

/**
 * 文件是否确定缺失：按定位探测结果判定。
 * 仅确认「文件不存在」（或不可定位）时返回真；权限类与其他异常交由打开动作给出真实结果。
 */
export function isFileMissing(location: FileLocation): boolean {
  return probeFile(location) === FileProbe.missing;
}

/** MIME 解析：条目类型可用时优先；缺失或为通用二进制时按文件名扩展名推导。 */
function resolveOpenMime(fileType: string, fileName: string): string {
  if (fileType.length > 0 && fileType !== MIME_OCTET_STREAM) {
    return fileType;
  }
  return getMimeForFileName(fileName);
}

/**
 * 打开文件所在目录（经系统文件管理器）：不可定位或文件缺失时不执行打开。
 */
/** 文档类 URI 的父目录 URI：接收目录的持久授权挂在目录上，文件 URI 本身没有单独授权 */
function containingDocsDirectoryUri(uri: string): string {
  if (!uri.startsWith('file://docs/')) {
    return '';
  }
  let slash: number = uri.lastIndexOf('/');
  if (slash <= 'file://docs/'.length) {
    return '';
  }
  return uri.substring(0, slash);
}

/**
 * 探测重试：媒体库 / 文件框架的授权在进程启动初期可能尚未就绪，
 * 此时按 URI 打开会返回 Operation not permitted，稍后重试即可成功。
 * 仅在判定为「无权限」时重试，物理缺失（ENOENT）不重试。
 */
async function probeWithAccess(location: FileLocation): Promise<FileProbe> {
  // 先激活持久化授权：Picker 的临时授权只在一定时间内有效（与进程是否重启无关）
  await ensureUriAccess(location.uri);
  let probe: FileProbe = probeFile(location);
  if (probe !== FileProbe.denied) {
    return probe;
  }
  // 接收目录中的文件：持久化授权记录在目录 URI 上，激活父目录后重试
  let dirUri: string = containingDocsDirectoryUri(location.uri);
  if (dirUri.length > 0) {
    await ensureWritableUriAccess(dirUri);
    probe = probeFile(location);
  }
  return probe;
}

export async function openContainingFolder(context: common.UIAbilityContext,
  location: FileLocation): Promise<FileOpenResult> {
  if (!location.locatable || location.uri.length === 0) {
    return FileOpenResult.unavailable;
  }
  let probe: FileProbe = await probeWithAccess(location);
  if (probe === FileProbe.missing) {
    return FileOpenResult.fileMissing;
  }
  if (probe === FileProbe.denied) {
    return FileOpenResult.accessDenied;
  }
  let options: OpenLinkOptions = {
    parameters: {
      'fileUri': location.uri
    }
  };
  try {
    await context.openLink(LINK_OPEN_DIRECTORY, options);
    return FileOpenResult.success;
  } catch (e) {
    logger.warn('打开所在目录失败 uri=' + location.uri + ' 原因=' + String(e));
    return FileOpenResult.failed;
  }
}

/**
 * 用其他应用打开：隐式 Want（查看数据 action + 文件 URI + MIME 类型 + 只读授权标志 +
 * 强制展示应用选择器），由系统给出可处理该文件的应用列表。
 * 无可用应用、调起失败、用户取消或定位不可转授均返回非成功结果态。
 */
export async function openWithOtherApp(context: common.UIAbilityContext, location: FileLocation,
  fileType: string, fileName: string): Promise<FileOpenResult> {
  if (!location.locatable || location.uri.length === 0) {
    return FileOpenResult.unavailable;
  }
  let probe: FileProbe = await probeWithAccess(location);
  if (probe === FileProbe.missing) {
    return FileOpenResult.fileMissing;
  }
  if (probe === FileProbe.denied) {
    return FileOpenResult.accessDenied;
  }
  let mime: string = resolveOpenMime(fileType, fileName);
  let want: Want = {
    action: ACTION_VIEW_DATA,
    uri: location.uri,
    type: mime,
    // 只读授权：仅授予目标应用读取该文件的权利，不授予写入
    flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
    // 强制展示应用选择框，由用户自行选择打开该文件的应用
    parameters: {
      'ohos.ability.params.showDefaultPicker': true
    }
  };
  try {
    await context.startAbility(want);
    return FileOpenResult.success;
  } catch (e) {
    let err = e as BusinessError;
    if (err.code === ERR_ABILITY_NOT_EXIST) {
      // 设备上没有可处理该类型的应用属预期结果，不是错误
      logger.info('没有可打开该文件的应用');
      logger.debug('无可用应用 uri=' + location.uri + ' 类型=' + mime);
      return FileOpenResult.noApp;
    }
    logger.warn('用其他应用打开失败 uri=' + location.uri + ' 类型=' + mime + ' 错误码=' + err.code);
    return FileOpenResult.failed;
  }
}
