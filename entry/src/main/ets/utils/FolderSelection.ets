// 文件夹选择能力的统一判定：发送页与接收目录设置共用同一门槛。
// DocumentSelectMode.FOLDER：手机/平板 API 26+，2in1 API 13+；本项目最低兼容 API 23，
// 故 2in1 实际只取决于系统能力。
import { deviceInfo } from '@kit.BasicServicesKit';

const FOLDER_SELECT_MIN_API: number = 26;
const FOLDER_SELECT_MIN_API_2IN1: number = 13;

/** 设备是否具备文件夹选择能力。 */
export function isFolderSelectionSupported(): boolean {
  try {
    if (!canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
      return false;
    }
    let minApi: number = deviceInfo.deviceType === '2in1' ?
      FOLDER_SELECT_MIN_API_2IN1 : FOLDER_SELECT_MIN_API;
    return deviceInfo.sdkApiVersion >= minApi;
  } catch (_e) {
    return false;
  }
}
