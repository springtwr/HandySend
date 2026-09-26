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
  /** 定位不可用（空定位或解析失败，含授权无法转授） */
  unavailable = 'unavailable',
  /** 系统未找到可处理该文件的应用 */
  noApp = 'noApp',
  /** 调起失败（含用户取消） */
  failed = 'failed'
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
 * 图库资源是否可用：按资源标识（URI）打开并读取文件属性校验，正常 / 异常路径都关闭文件对象，
 * 不换算本机路径（媒体库标识为虚拟路径，换算后做普通文件操作会产生非预期结果）。
 */
function galleryResourceExists(uri: string): boolean {
  if (uri.length === 0) {
    return false;
  }
  let file: fs.File | undefined = undefined;
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    return fs.statSync(file.fd).isFile();
  } catch (e) {
    logger.warn('图库资源校验失败 uri=' + uri + ' 原因=' + String(e));
    return false;
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
 * 文件是否确定缺失：不可定位视为缺失；
 * 图库来源按资源标识（URI）打开校验，其余来源按本机路径做存在性检查；
 * 仅「文件不存在」错误码判定为缺失，其余异常按存在处理（交由打开动作给出真实结果）。
 */
export function isFileMissing(location: FileLocation): boolean {
  if (!location.locatable) {
    return true;
  }
  if (location.isGalleryResource) {
    return !galleryResourceExists(location.uri);
  }
  if (location.localPath.length === 0) {
    return true;
  }
  try {
    return !fs.accessSync(location.localPath);
  } catch (e) {
    let err = e as BusinessError;
    return err.code === ERR_NO_SUCH_FILE;
  }
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
export async function openContainingFolder(context: common.UIAbilityContext,
  location: FileLocation): Promise<FileOpenResult> {
  if (!location.locatable || location.uri.length === 0) {
    return FileOpenResult.unavailable;
  }
  if (isFileMissing(location)) {
    return FileOpenResult.fileMissing;
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
  if (isFileMissing(location)) {
    return FileOpenResult.fileMissing;
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
    logger.warn('用其他应用打开失败 uri=' + location.uri + ' 类型=' + mime + ' 错误码=' + err.code);
    return err.code === ERR_ABILITY_NOT_EXIST ? FileOpenResult.noApp : FileOpenResult.failed;
  }
}
