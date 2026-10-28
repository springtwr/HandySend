// GallerySaveService：封装 photoAccessHelper 相册保存逻辑
// 使用 SaveButton 安全控件获取临时授权后，通过 MediaAssetChangeRequest 保存媒体文件

import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { MediaFileInfo, GallerySaveResult } from '../model/Types';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:GallerySaveService', '相册');

// 相册媒体库的旧版标题校验拒绝这些字符（点号在列），且显示名不能以点号开头。
// 网页发送的文件名常带点号（如 Android 截图的 Screenshot_..._com.huawei.android.launcher.jpg），
// 此类名称走 createImageAssetRequest 会报 Invalid fileName。
const FORBIDDEN_TITLE_CHARS: string = '.\\/:*?"\'`<>|{}[]';

/** 取路径末段文件名。 */
function fileNameOf(path: string): string {
  let slash: number = path.lastIndexOf('/');
  return slash >= 0 ? path.substring(slash + 1) : path;
}

/** 显示名是否会被媒体库的标题校验拒绝。 */
export function galleryDisplayNameNeedsSanitize(displayName: string): boolean {
  if (displayName.length === 0 || displayName.charAt(0) === '.') {
    return true;
  }
  let dot: number = displayName.lastIndexOf('.');
  // 无扩展名时媒体库取不到标题，同样按拒绝处理
  if (dot <= 0) {
    return true;
  }
  let title: string = displayName.substring(0, dot);
  for (let i = 0; i < title.length; i++) {
    if (FORBIDDEN_TITLE_CHARS.indexOf(title.charAt(i)) >= 0) {
      return true;
    }
  }
  return false;
}

/** 把媒体库不接受的标题字符替换为下划线，保留其余可读部分。 */
export function gallerySanitizedTitle(title: string): string {
  let result: string = '';
  for (let i = 0; i < title.length; i++) {
    let ch: string = title.charAt(i);
    result += FORBIDDEN_TITLE_CHARS.indexOf(ch) >= 0 ? '_' : ch;
  }
  return result.length > 0 ? result : 'media_' + Date.now();
}

/** 取扩展名（不含点）；无扩展名时按声明类型兜底。 */
function extensionOf(file: MediaFileInfo): string {
  let name: string = fileNameOf(file.filePath);
  let dot: number = name.lastIndexOf('.');
  if (dot > 0 && dot < name.length - 1) {
    return name.substring(dot + 1).toLowerCase();
  }
  let slash: number = file.fileType.indexOf('/');
  let sub: string = slash >= 0 ? file.fileType.substring(slash + 1) : '';
  if (sub === 'jpeg') {
    return 'jpg';
  }
  if (sub === 'quicktime') {
    return 'mov';
  }
  return sub;
}

export async function saveMediaToGallery(
  context: common.UIAbilityContext,
  mediaFiles: Array<MediaFileInfo>
): Promise<GallerySaveResult> {
  let successCount: number = 0;
  let failCount: number = 0;
  let errors: Array<string> = [];

  let phAccessHelper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);

  for (let i = 0; i < mediaFiles.length; i++) {
    let file: MediaFileInfo = mediaFiles[i];
    try {
      // 将沙箱路径转为 file URI 格式
      let fileUriStr: string = fileUri.getUriFromPath(file.filePath);
      let request: photoAccessHelper.MediaAssetChangeRequest;
      let displayName: string = fileNameOf(file.filePath);
      if (galleryDisplayNameNeedsSanitize(displayName)) {
        // 标题含媒体库不接受的字符：改为「按扩展名建资产 + 直接引用原文件」，
        // 资产名用替换后的标题，文件内容不复制。
        let title: string = gallerySanitizedTitle(displayName.substring(0, displayName.lastIndexOf('.')));
        let extension: string = extensionOf(file);
        request = photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(context,
          file.isImage ? photoAccessHelper.PhotoType.IMAGE : photoAccessHelper.PhotoType.VIDEO,
          extension.length > 0 ? extension : (file.isImage ? 'jpg' : 'mp4'),
          { title: title });
        request.addResource(file.isImage ? photoAccessHelper.ResourceType.IMAGE_RESOURCE :
          photoAccessHelper.ResourceType.VIDEO_RESOURCE, fileUriStr);
      } else if (file.isImage) {
        request = photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(context, fileUriStr);
      } else {
        request = photoAccessHelper.MediaAssetChangeRequest.createVideoAssetRequest(context, fileUriStr);
      }
      await phAccessHelper.applyChanges(request);
      successCount = successCount + 1;
      logger.debug('已保存: ' + file.fileName);
    } catch (e) {
      failCount = failCount + 1;
      let errMsg: string = file.fileName + ': ' + String(e);
      errors.push(errMsg);
      logger.error('保存失败: ' + errMsg);
    }
  }

  let result: GallerySaveResult = {
    successCount: successCount,
    failCount: failCount,
    errors: errors
  };
  return result;
}
