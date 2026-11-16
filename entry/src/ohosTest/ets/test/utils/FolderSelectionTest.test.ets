// FolderSelectionTest：文件夹选择能力的统一判定
// 发送页与接收目录设置必须使用同一门槛；同时验证判定结果与系统能力、设备类型门槛一致。
import { describe, it, expect } from '@ohos/hypium'
import { deviceInfo } from '@kit.BasicServicesKit'
import { isFolderSelectionSupported } from '../../../../main/ets/utils/FolderSelection'
import { isReceiveDirectorySelectionSupported } from '../../../../main/ets/service/repository/ReceiveDirectory'

export default function FolderSelectionTest() {
  describe('FolderSelectionTest', () => {
    it('send_and_receive_share_same_capability', 0, () => {
      let sendSupported: boolean = isFolderSelectionSupported();
      let receiveSupported: boolean = isReceiveDirectorySelectionSupported();
      expect(sendSupported).assertEqual(receiveSupported);
    })

    it('capability_matches_api_and_syscap', 0, () => {
      let expected: boolean = false;
      try {
        let minApi: number = deviceInfo.deviceType === '2in1' ? 13 : 26;
        expected = deviceInfo.sdkApiVersion >= minApi &&
          canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection');
      } catch (_e) {
        expected = false;
      }
      expect(isFolderSelectionSupported()).assertEqual(expected);
    })
  })
}
