// 文件夹选择能力的统一判定：发送页与接收目录设置共用同一门槛。
import { deviceInfo } from '@kit.BasicServicesKit';

// 手机/平板 API 26+、2in1 13+ 才具备 FolderSelection；产品口径统一以 API 26 为界。
const FOLDER_SELECT_MIN_API: number = 26;

/** 设备是否具备文件夹选择能力。 */
export function isFolderSelectionSupported(): boolean {
  try {
    return deviceInfo.sdkApiVersion >= FOLDER_SELECT_MIN_API &&
      canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection');
  } catch (_e) {
    return false;
  }
}
