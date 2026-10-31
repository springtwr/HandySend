// GallerySavePolicyTest：条目「保存到相册」可用性判定用例
// 覆盖图片 / 视频、非媒体类型、图库来源排除、类型缺失时按扩展名兜底与空路径。
import { describe, it, expect } from '@ohos/hypium'
import {
  gallerySaveLocalPath,
  isGalleryImage,
  isSaveToGalleryCandidate
} from '../../../../main/ets/utils/GallerySavePolicy'

// 本机下载目录路径（接收文件实际落盘位置）
const LOCAL_IMAGE: string = '/data/storage/el2/base/files/Download/a.jpg'
const LOCAL_VIDEO: string = '/data/storage/el2/base/files/Download/b.mp4'
const LOCAL_PDF: string = '/data/storage/el2/base/files/Download/c.pdf'
// 图库来源标识（媒体库图片 / 视频虚拟路径）
const GALLERY_IMAGE_URI: string = 'file://media/Photo/111/IMG_1234567890_123/A.jpg'
const GALLERY_VIDEO_URI: string = 'file://media/Photo/222/VID_1234567890_321/B.mp4'

export default function GallerySavePolicyTest() {
  describe('GallerySavePolicyTest', () => {
    it('local_image_is_candidate', 0, () => {
      expect(isSaveToGalleryCandidate(LOCAL_IMAGE, 'image/jpeg', 'a.jpg')).assertTrue()
    })

    it('local_video_is_candidate', 0, () => {
      expect(isSaveToGalleryCandidate(LOCAL_VIDEO, 'video/mp4', 'b.mp4')).assertTrue()
    })

    it('gallery_image_is_not_candidate', 0, () => {
      // 图库来源本身已在相册中，不提供保存入口
      expect(isSaveToGalleryCandidate(GALLERY_IMAGE_URI, 'image/jpeg', 'A.jpg')).assertFalse()
    })

    it('gallery_video_is_not_candidate', 0, () => {
      expect(isSaveToGalleryCandidate(GALLERY_VIDEO_URI, 'video/mp4', 'B.mp4')).assertFalse()
    })

    it('non_media_is_not_candidate', 0, () => {
      expect(isSaveToGalleryCandidate(LOCAL_PDF, 'application/pdf', 'c.pdf')).assertFalse()
    })

    it('empty_type_falls_back_to_extension', 0, () => {
      // 类型缺失时按文件名扩展名兜底：jpg 可保存，txt 不可保存
      expect(isSaveToGalleryCandidate(LOCAL_IMAGE, '', 'a.jpg')).assertTrue()
      expect(isSaveToGalleryCandidate('/data/storage/el2/base/files/Download/d.txt', '', 'd.txt')).assertFalse()
    })

    it('octet_stream_type_falls_back_to_extension', 0, () => {
      // 通用二进制类型不能作为媒体依据，按扩展名兜底
      expect(isSaveToGalleryCandidate(LOCAL_IMAGE, 'application/octet-stream', 'a.jpg')).assertTrue()
      expect(isGalleryImage('application/octet-stream', 'a.jpg')).assertTrue()
      expect(isGalleryImage('application/octet-stream', 'b.mp4')).assertFalse()
    })

    it('empty_path_is_not_candidate', 0, () => {
      expect(isSaveToGalleryCandidate('', 'image/jpeg', 'a.jpg')).assertFalse()
    })

    it('local_path_normalized_for_save', 0, () => {
      // 保存服务要求本机路径；图库来源不产出可保存路径
      expect(gallerySaveLocalPath(LOCAL_IMAGE)).assertEqual(LOCAL_IMAGE)
      expect(gallerySaveLocalPath(GALLERY_IMAGE_URI)).assertEqual('')
    })

    it('image_flag_uses_type_or_extension', 0, () => {
      expect(isGalleryImage('image/png', 'a.png')).assertTrue()
      expect(isGalleryImage('video/mp4', 'b.mp4')).assertFalse()
      expect(isGalleryImage('', 'c.jpg')).assertTrue()
      expect(isGalleryImage('', 'd.mp4')).assertFalse()
    })
  })
}
