/**
 * ReceiveDirectory.ets — 接收文件保存目录的唯一来源
 *
 * 目录来源：
 * - 用户自定义：设置页经 DocumentViewPicker 以 FOLDER 模式选择，URI 做读写持久化授权；
 * - 默认：DocumentViewPicker.save 的 DOWNLOAD 模式，落 Download/<包名>/。
 *
 * LocalSend、网页上传、MTA 三条接收链路都必须经本模块取目录，禁止各自解析路径。
 */

import { common, bundleManager } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { getReceiveDirectoryUri, setReceiveDirectoryUri } from './SettingsRepository';
import { getAppContext } from './AppCore';
import { ensureWritableUriAccess, persistWritableUri } from '../../utils/UriPermission';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ReceiveDirectory', '接收目录');

// 目录选择能力最低 API：手机/平板 26.0.0 起支持（2in1 13+）。
// 设置项按产品要求统一以 API 26 为界，低于该版本置灰。
const FOLDER_SELECT_MIN_API: number = 26;

// 文档类 URI 前缀：文件管理器以 currentUser 根目录为视角展示相对路径
const DOC_USER_ROOT: string = 'file://docs/storage/Users/currentUser/';
const DOC_STORAGE_ROOT: string = 'file://docs/storage/';

/** 目录选择结果：success 带回 URI，default 表示用户选中了默认目录，cancelled 为用户取消，failed 为调用失败 */
export type ReceiveDirectoryPickStatus = 'cancelled' | 'default' | 'failed' | 'success';

/** 目录选择结果（URI 仅在 success 时非空） */
export class ReceiveDirectoryPickResult {
  status: ReceiveDirectoryPickStatus;
  uri: string;

  constructor(status: ReceiveDirectoryPickStatus, uri: string) {
    this.status = status;
    this.uri = uri;
  }
}

// 当前生效目录缓存：cachedSettingUri 记录缓存对应的设置值，设置变更后自动重新解析
let cachedSettingUri: string = '';
let cachedPath: string = '';
// 默认下载目录单独缓存：自定义目录切换到默认时无需重新拉起 Picker
let defaultDirPath: string = '';
let defaultDirUri: string = '';
// 自定义目录失效回退默认目录后，等待向用户提示一次
let fallbackNoticePending: boolean = false;

function normalizeDirectoryPath(path: string): string {
  let result: string = path;
  while (result.length > 1 && result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

/** 设备是否具备目录选择能力（API 26+ 且系统声明 FolderSelection） */
export function isReceiveDirectorySelectionSupported(): boolean {
  try {
    return deviceInfo.sdkApiVersion >= FOLDER_SELECT_MIN_API &&
      canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection');
  } catch (_e) {
    return false;
  }
}

// 文件管理器的特殊目录在 URI 中使用内部名，界面按系统语言展示不同名称。
// 官方未提供“内部名 → 显示名”的查询接口，这里维护已确认的映射（其余段原样保留）。
function localizedDirectorySegment(segment: string): string {
  let res: Resource | undefined = undefined;
  if (segment === 'Huawei Share') {
    res = $r('app.string.receive_directory_huawei_share');
  } else if (segment === 'HO_DATA_EXT_MISC') {
    res = $r('app.string.receive_directory_compatible_data');
  }
  if (res === undefined) {
    return segment;
  }
  try {
    let appCtx: common.UIAbilityContext | undefined = getAppContext();
    if (appCtx !== undefined) {
      let text: string = appCtx.resourceManager.getStringSync(res.id);
      if (text.length > 0) {
        return text;
      }
    }
  } catch (_e) {
  }
  return segment;
}

/** URI 对应的展示名称（目录名）；解析失败时回退原 URI */
export function receiveDirectoryDisplayName(uri: string): string {
  try {
    return localizedDirectorySegment(new fileUri.FileUri(uri).name);
  } catch (_e) {
    return uri;
  }
}

/**
 * URI 对应的用户可见路径：文件管理器里展示的是相对用户根目录的路径
 * （如 `Download/test`），而非 `/storage/Users/currentUser/...` 真实路径。
 * 特殊目录按系统语言替换为文件管理器中的显示名称（如 HO_DATA_EXT_MISC → 兼容应用数据）。
 */
export function receiveDirectoryUserPath(uri: string): string {
  if (uri.length === 0) {
    return '';
  }
  let raw: string = uri;
  if (raw.startsWith(DOC_USER_ROOT)) {
    raw = raw.substring(DOC_USER_ROOT.length);
  } else if (raw.startsWith(DOC_STORAGE_ROOT)) {
    raw = raw.substring(DOC_STORAGE_ROOT.length);
  } else {
    return '';
  }
  raw = normalizeDirectoryPath(raw);
  let segments: Array<string> = raw.split('/');
  for (let i = 0; i < segments.length; i++) {
    let decoded: string = segments[i];
    try {
      decoded = decodeURIComponent(decoded);
    } catch (_e) {
    }
    segments[i] = localizedDirectorySegment(decoded);
  }
  return segments.join('/');
}

/** URI 对应的本机路径；解析失败返回空串 */
export function receiveDirectoryPathOf(uri: string): string {
  try {
    return normalizeDirectoryPath(new fileUri.FileUri(uri).path);
  } catch (_e) {
    return '';
  }
}

/**
 * 拉起系统目录选择器并持久化读写授权。
 * 返回 success 时 uri 为目录 URI；用户取消返回 cancelled；其他异常返回 failed。
 */
export async function pickReceiveDirectory(context: common.UIAbilityContext): Promise<ReceiveDirectoryPickResult> {
  let options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
  options.selectMode = picker.DocumentSelectMode.FOLDER;
  options.maxSelectNumber = 1;
  // 打开选择器时定位到当前生效目录：恢复默认后即默认目录，而不是上次停留的自定义目录
  let currentUri: string = await resolveReceiveDirectoryUri();
  if (currentUri.length > 0) {
    options.defaultFilePathUri = currentUri;
  }
  try {
    let documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    let uris: Array<string> = await documentPicker.select(options);
    if (uris === undefined || uris.length === 0) {
      return new ReceiveDirectoryPickResult('cancelled', '');
    }
    let selectedPath: string = receiveDirectoryPathOf(uris[0]);
    // 先确认 URI 能转成本机路径，避免保存一个接收时必然不可用的目录
    if (selectedPath.length === 0) {
      logger.warn('选择的目录无法解析为路径 uri=' + uris[0]);
      return new ReceiveDirectoryPickResult('failed', '');
    }
    // 用户直接选中应用的默认目录时按「恢复默认」处理，避免界面显示 Download/<包名>。
    // 当前为自定义目录时前面不会解析默认目录，这里兜底解析一次用于路径比较。
    if (defaultDirPath.length === 0) {
      await ensureDefaultDirectory();
    }
    if (defaultDirPath.length > 0 && selectedPath === defaultDirPath) {
      // 记住用户从选择器里拿到的默认目录 URI，下次打开选择器时优先用它定位
      defaultDirUri = uris[0];
      return new ReceiveDirectoryPickResult('default', '');
    }
    await persistWritableUri(uris[0]);
    return new ReceiveDirectoryPickResult('success', uris[0]);
  } catch (e) {
    let errText: string = String(e);
    // Picker 取消在部分版本以错误码 801 / code 0 抛出，按取消处理而非失败
    if (errText.includes('801') || errText.includes('code: 0')) {
      return new ReceiveDirectoryPickResult('cancelled', '');
    }
    logger.warn('选择接收目录失败：' + errText);
    return new ReceiveDirectoryPickResult('failed', '');
  }
}

// 默认目录：优先经 DOWNLOAD 模式获取（返回持久授权 URI 且自动建目录）；
// Picker 失败时回退直接构造 Download/<包名> URI，与旧 MTA 路径保持一致。
async function ensureDefaultDirectory(): Promise<string> {
  // 路径与 URI 同时缓存：目录选择器需要 URI 才能定位到默认目录
  if (defaultDirPath.length > 0 && defaultDirUri.length > 0) {
    try {
      if (fs.accessSync(defaultDirPath)) {
        return defaultDirPath;
      }
    } catch (_e) {
    }
    defaultDirPath = '';
    defaultDirUri = '';
  }
  let dirUri: string = '';
  try {
    let saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    saveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    // 有 UIAbility 上下文时使用推荐构造（无参构造存在概率性拉起失败）；早期无上下文时回退无参
    let appCtx: common.UIAbilityContext | undefined = getAppContext();
    let documentPicker: picker.DocumentViewPicker = appCtx !== undefined ?
      new picker.DocumentViewPicker(appCtx) : new picker.DocumentViewPicker();
    let uris: Array<string> = await documentPicker.save(saveOptions);
    if (uris !== undefined && uris.length > 0) {
      dirUri = uris[0];
    }
  } catch (e) {
    logger.warn('DOWNLOAD 模式获取默认接收目录失败：' + String(e));
  }
  let path: string = dirUri.length > 0 ? receiveDirectoryPathOf(dirUri) : '';
  if (path.length === 0) {
    try {
      let bundleFlags: number = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
      let info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(bundleFlags);
      dirUri = `file://docs/storage/Users/currentUser/Download/${info.name}`;
      path = receiveDirectoryPathOf(dirUri);
    } catch (e) {
      logger.warn('构造默认接收目录失败：' + String(e));
      return '';
    }
  }
  if (path.length === 0) {
    return '';
  }
  try {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path, true);
    }
  } catch (e) {
    logger.warn('创建默认接收目录失败 path=' + path + '：' + String(e));
    return '';
  }
  defaultDirPath = path;
  defaultDirUri = dirUri;
  return path;
}

// 自定义目录：激活持久授权后校验目录是否仍可访问；失效返回空串，由调用方回退默认目录
async function resolveCustomDirectory(uri: string): Promise<string> {
  try {
    await ensureWritableUriAccess(uri);
    let path: string = receiveDirectoryPathOf(uri);
    if (path.length === 0 || !fs.accessSync(path)) {
      return '';
    }
    return path;
  } catch (e) {
    logger.warn('解析自定义接收目录失败 uri=' + uri + '：' + String(e));
    return '';
  }
}

// 当前生效目录 URI：自定义目录可用时返回自定义 URI，否则返回默认目录 URI；
// 供目录选择器定位起始目录（恢复默认后不会停留在上次选择的自定义目录）
async function resolveReceiveDirectoryUri(): Promise<string> {
  let configuredUri: string = getReceiveDirectoryUri();
  if (configuredUri.length > 0) {
    let customPath: string = await resolveCustomDirectory(configuredUri);
    if (customPath.length > 0) {
      return configuredUri;
    }
  }
  let defaultPath: string = await ensureDefaultDirectory();
  return defaultPath.length > 0 ? defaultDirUri : '';
}

/**
 * 确保接收目录可用并返回其路径（已去尾斜杠）；不可得返回空串。
 * 自定义目录不可用（被删除、授权被撤销等）时回退默认目录并清除该设置，
 * 保证接收不因设置失效而中断，且设置页同步回到默认目录。
 */
export async function ensureReceiveDirectory(): Promise<string> {
  let configuredUri: string = getReceiveDirectoryUri();
  if (configuredUri === cachedSettingUri && cachedPath.length > 0) {
    // 运行中目录可能被删除：缓存命中也要校验，失效则重新解析
    try {
      if (fs.accessSync(cachedPath)) {
        return cachedPath;
      }
    } catch (_e) {
    }
    cachedPath = '';
    cachedSettingUri = '';
  }
  cachedSettingUri = configuredUri;
  cachedPath = '';
  if (configuredUri.length > 0) {
    let customPath: string = await resolveCustomDirectory(configuredUri);
    if (customPath.length > 0) {
      cachedPath = customPath;
      return customPath;
    }
    logger.warn('自定义接收目录不可用，回退默认目录并清除设置 uri=' + configuredUri);
    // 目录已删除/授权失效：清除设置，设置页经 notifyChange 同步刷新为默认目录
    setReceiveDirectoryUri('');
    cachedSettingUri = '';
    fallbackNoticePending = true;
  }
  let path: string = await ensureDefaultDirectory();
  if (path.length > 0) {
    cachedPath = path;
  }
  return path;
}

/** 当前生效目录路径的同步快照（尚未解析过时为空串） */
export function getReceiveDirectoryPath(): string {
  return cachedPath;
}

/**
 * 消费一次“目录失效已回退默认目录”提示。
 * 返回 true 表示应提示用户；用户随后手动改过目录时旧提示不再适用，直接丢弃。
 */
export function consumeReceiveDirectoryFallbackNotice(): boolean {
  if (!fallbackNoticePending) {
    return false;
  }
  fallbackNoticePending = false;
  return getReceiveDirectoryUri().length === 0;
}

/**
 * 应用启动时激活自定义接收目录的持久授权。
 * 接收历史与详情页按路径读取已接收文件时，依赖该授权在进程内生效。
 */
export async function activateConfiguredReceiveDirectory(): Promise<void> {
  let uri: string = getReceiveDirectoryUri();
  if (uri.length === 0) {
    return;
  }
  await ensureWritableUriAccess(uri);
}

/** 清除目录缓存：设置变更后调用，下次取目录时按新设置重新解析 */
export function invalidateReceiveDirectoryCache(): void {
  cachedSettingUri = '';
  cachedPath = '';
}
