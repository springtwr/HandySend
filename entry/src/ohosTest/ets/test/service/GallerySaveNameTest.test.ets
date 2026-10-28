// 相册保存文件名校验用例：媒体库旧版标题校验拒绝标题中的点号等字符，
// 网页发送的 Android 截图文件名（含 com.xxx.yyy）即属此类。
import { describe, it, expect } from '@ohos/hypium'
import {
  galleryDisplayNameNeedsSanitize,
  gallerySanitizedTitle
} from '../../../../main/ets/service/GallerySaveService'

export default function GallerySaveNameTest() {
  describe('GallerySaveNameTest', () => {
    it('galleryName_dottedTitleNeedsSanitize', 0, () => {
      let displayName: string = 'Screenshot_20261028_095438_com.huawei.android.launcher.jpg'
      expect(galleryDisplayNameNeedsSanitize(displayName)).assertTrue()
      expect(gallerySanitizedTitle('Screenshot_20261028_095438_com.huawei.android.launcher'))
        .assertEqual('Screenshot_20261028_095438_com_huawei_android_launcher')
    })

    it('galleryName_plainNameKept', 0, () => {
      expect(galleryDisplayNameNeedsSanitize('IMG_20240101_123456.jpg')).assertFalse()
      expect(galleryDisplayNameNeedsSanitize('video-2024_0101.mp4')).assertFalse()
    })

    it('galleryName_hiddenOrNoExtensionNeedsSanitize', 0, () => {
      expect(galleryDisplayNameNeedsSanitize('.hidden.jpg')).assertTrue()
      expect(galleryDisplayNameNeedsSanitize('noext')).assertTrue()
      expect(galleryDisplayNameNeedsSanitize('')).assertTrue()
    })
  })
}
