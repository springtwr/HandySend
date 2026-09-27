// FileLocationUtilTest：文件定位归一的来源判定用例
// 覆盖图库来源（媒体库图片 / 视频标识）识别、非图库来源识别、图库来源定位归一无须本机路径成立，
// 以及图库资源不可用时的收口依据与打开结果态映射。
// 界面层「打开所在位置」置灰依据 isGalleryLocation 与来源判定同源，一并覆盖。
// 依赖系统调起与上下文的行为（文件管理器定位）不做自动化断言，由设备端手动 / UI 验证覆盖。
import { describe, it, expect } from '@ohos/hypium'
import {
  FileLocation,
  FileOpenResult,
  isGalleryLocation,
  isFileMissing,
  normalizeFileLocation
} from '../../../../main/ets/utils/FileLocationUtil'

// 图库资源标识样例（与官方媒体文件 URI 形式一致：file://media/Photo/<ID>/<真实文件名>/<displayName>）
const GALLERY_IMAGE_URI: string = 'file://media/Photo/111/IMG_1234567890_123/A.jpg'
const GALLERY_VIDEO_URI: string = 'file://media/Photo/222/VID_1234567890_321/B.mp4'
// 媒体库音频标识（AudioViewPicker 来源）：本特性明确不纳入图库处理
const MEDIA_AUDIO_URI: string = 'file://media/Audio/1/AUD_1234567890_1/C.mp3'
// 文档类资源标识（DocumentViewPicker 来源）
const DOC_URI: string = 'file://docs/storage/Users/currentUser/Documents/note.txt'
// 本机 / 沙箱绝对路径
const LOCAL_PATH: string = '/data/storage/el2/base/files/note.txt'

export default function FileLocationUtilTest() {
  describe('FileLocationUtilTest', () => {
    // ── 来源判定：图库图片来源识别为真 ──

    it('gallery_image_isGalleryResource_true', 0, () => {
      let location: FileLocation = normalizeFileLocation(GALLERY_IMAGE_URI)
      expect(location.isGalleryResource).assertTrue()
    })

    // ── 来源判定：图库视频与图片共用同一能力路径 ──

    it('gallery_video_isGalleryResource_true', 0, () => {
      let location: FileLocation = normalizeFileLocation(GALLERY_VIDEO_URI)
      expect(location.isGalleryResource).assertTrue()
    })

    it('gallery_video_same_routing_as_image', 0, () => {
      // 视频与图片同为媒体库 Photo 类标识，来源判定与定位归一结果一致
      let image: FileLocation = normalizeFileLocation(GALLERY_IMAGE_URI)
      let video: FileLocation = normalizeFileLocation(GALLERY_VIDEO_URI)
      expect(video.isGalleryResource).assertEqual(image.isGalleryResource)
      expect(video.locatable).assertEqual(image.locatable)
      expect(video.localPath).assertEqual(image.localPath)
    })

    // ── 来源判定：非图库来源识别为假 ──

    it('doc_uri_isGalleryResource_false', 0, () => {
      let location: FileLocation = normalizeFileLocation(DOC_URI)
      expect(location.isGalleryResource).assertFalse()
    })

    it('local_path_isGalleryResource_false', 0, () => {
      let location: FileLocation = normalizeFileLocation(LOCAL_PATH)
      expect(location.isGalleryResource).assertFalse()
    })

    it('media_audio_uri_isGalleryResource_false', 0, () => {
      // 媒体库音频不属于图库（相册）语义，不纳入本特性处理
      let location: FileLocation = normalizeFileLocation(MEDIA_AUDIO_URI)
      expect(location.isGalleryResource).assertFalse()
    })

    // ── 界面置灰依据：isGalleryLocation 与来源判定同源 ──

    it('gallery_image_isGalleryLocation_true', 0, () => {
      // 图库图片标识判定为图库来源（「打开所在位置」据此置灰）
      expect(isGalleryLocation(GALLERY_IMAGE_URI)).assertTrue()
    })

    it('gallery_video_isGalleryLocation_true', 0, () => {
      expect(isGalleryLocation(GALLERY_VIDEO_URI)).assertTrue()
    })

    it('doc_uri_isGalleryLocation_false', 0, () => {
      expect(isGalleryLocation(DOC_URI)).assertFalse()
    })

    it('local_path_isGalleryLocation_false', 0, () => {
      expect(isGalleryLocation(LOCAL_PATH)).assertFalse()
    })

    it('media_audio_uri_isGalleryLocation_false', 0, () => {
      // 媒体库音频不纳入图库置灰范围
      expect(isGalleryLocation(MEDIA_AUDIO_URI)).assertFalse()
    })

    it('empty_isGalleryLocation_false', 0, () => {
      expect(isGalleryLocation('')).assertFalse()
    })

    it('empty_location_unlocatable', 0, () => {
      let location: FileLocation = normalizeFileLocation('')
      expect(location.locatable).assertFalse()
      expect(location.isGalleryResource).assertFalse()
    })

    // ── 定位归一：图库来源无须本机路径即成立 ──

    it('gallery_normalize_without_local_path', 0, () => {
      let location: FileLocation = normalizeFileLocation(GALLERY_IMAGE_URI)
      // 图库来源不产出用于存在性判定的本机路径，但资源标识本身即可定位
      expect(location.localPath).assertEqual('')
      expect(location.uri).assertEqual(GALLERY_IMAGE_URI)
      expect(location.locatable).assertTrue()
      expect(location.isGalleryResource).assertTrue()
    })

    // ── 图库来源不可用与打开结果态收口 ──

    it('gallery_missing_resource_isFileMissing_true', 0, () => {
      // 不存在的图库资源标识：按资源标识校验不通过，收口依据为「文件缺失」
      let missing: FileLocation = normalizeFileLocation('file://media/Photo/1/IMG_0/not_exist.jpg')
      expect(missing.isGalleryResource).assertTrue()
      expect(isFileMissing(missing)).assertTrue()
    })

    it('empty_location_isFileMissing_true', 0, () => {
      // 空定位无法判定来源，视为不可用（收口为定位不可用 / 缺失）
      let empty: FileLocation = normalizeFileLocation('')
      expect(empty.locatable).assertFalse()
      expect(isFileMissing(empty)).assertTrue()
    })

    it('open_result_states_mapping', 0, () => {
      // 结果态集合完整且取值稳定：调用方据此给出明确提示，不静默
      expect(FileOpenResult.success).assertEqual('success')
      expect(FileOpenResult.fileMissing).assertEqual('fileMissing')
      expect(FileOpenResult.unavailable).assertEqual('unavailable')
      expect(FileOpenResult.noApp).assertEqual('noApp')
      expect(FileOpenResult.failed).assertEqual('failed')
    })
  })
}
