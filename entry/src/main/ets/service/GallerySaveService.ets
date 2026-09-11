// GallerySaveService：封装 photoAccessHelper 相册保存逻辑
// 使用 SaveButton 安全控件获取临时授权后，通过 MediaAssetChangeRequest 保存媒体文件

import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { common } from '@kit.AbilityKit';
import { MediaFileInfo, GallerySaveResult } from '../model/Types';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:GallerySaveService', '相册');

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
      let fileUri: string = 'file://' + file.filePath;
      let request: photoAccessHelper.MediaAssetChangeRequest;
      if (file.isImage) {
        request = photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(context, fileUri);
      } else {
        request = photoAccessHelper.MediaAssetChangeRequest.createVideoAssetRequest(context, fileUri);
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
