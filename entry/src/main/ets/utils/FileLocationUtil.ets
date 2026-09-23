/**
 * FileLocationUtil.ets — 文件定位归一与打开能力（跨页公用）
 *
 * 统一处理条目持有的两种定位形式（沙箱绝对路径 / 文件选择器返回的 file:// URI）：
 * - 定位归一：得到本机绝对路径与对外统一资源标识（URI），解析失败视为不可定位；
 * - 「打开所在位置」：经系统文件管理器打开文件所在目录；
 * - 「用其他应用打开」：以隐式 Want 调起系统应用选择框，文件以只读方式对外授权。
 *
 * 所有执行入口只返回结果态，不自行弹提示，由调用方决定文案。
 * 已知限制：文件选择器返回的 file:// 定位，其临时授权通常无法转授给第三方应用，
 * 此时「用其他应用打开」以失败结果收口（不静默、不崩溃）。
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

/** 文件不存在错误码（文件或目录不存在）。 */
const ERR_NO_SUCH_FILE: number = 13900002;

/** 隐式 Want 未匹配到任何应用时的错误码。 */
const ERR_ABILITY_NOT_EXIST: number = 16000001;

/** MIME 缺省值（按文件名无法推导时使用）。 */
const MIME_OCTET_STREAM: string = 'application/octet-stream';

/** 文件定位归一结果。 */
export interface FileLocation {
  /** 本机绝对路径（解析失败为空串） */
  localPath: string
  /** 对外统一资源标识（file:// 形式；解析失败为空串） */
  uri: string
  /** 是否可定位（两种定位形式都归一成功时为真） */
  locatable: boolean
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
  return { localPath: '', uri: '', locatable: false };
}

/**
 * 定位归一：
 * - 沙箱 / 绝对路径：直接作为本机路径，经 fileUri 换算对外 URI；
 * - file:// 形式：经 FileUri 取出本机路径，原串即对外 URI；
 * 两种情况解析失败即视为不可定位。
 */
export function normalizeFileLocation(location: string): FileLocation {
  if (location.length === 0) {
    return unlocatable();
  }
  if (!location.startsWith('file://')) {
    try {
      let uri: string = fileUri.getUriFromPath(location);
      if (uri.length === 0) {
        return unlocatable();
      }
      return { localPath: location, uri: uri, locatable: true };
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
    return { localPath: localPath, uri: location, locatable: true };
  } catch (e) {
    logger.warn('URI 解析失败 uri=' + location + ' 原因=' + String(e));
    return unlocatable();
  }
}

/**
 * 文件是否确定缺失：不可定位视为缺失；否则按本机路径做存在性检查，
 * 仅「文件不存在」错误码判定为缺失，其余异常按存在处理（交由打开动作给出真实结果）。
 */
export function isFileMissing(location: FileLocation): boolean {
  if (!location.locatable || location.localPath.length === 0) {
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
