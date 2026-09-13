import { describe, it, expect } from '@ohos/hypium'
import {
  isImage,
  isVideo,
  isMediaMime,
  hasDirectoryPath,
  getMimeForExt,
  getMimeForFileName,
  isImageExtension
} from '../main/ets/utils/MimeUtils'

export default function MimeUtilsTest() {
  describe('MimeUtilsTest', () => {
    // ── isImage / isVideo ──

    it('isImage_typical_true', 0, () => {
      expect(isImage('image/png')).assertTrue()
    })

    it('isImage_text_false', 0, () => {
      expect(isImage('text/plain')).assertFalse()
    })

    it('isImage_empty_false', 0, () => {
      expect(isImage('')).assertFalse()
    })

    it('isImage_uppercase_false', 0, () => {
      // startsWith 区分大小写：大写 MIME 不被识别
      expect(isImage('IMAGE/PNG')).assertFalse()
    })

    it('isVideo_typical_true', 0, () => {
      expect(isVideo('video/mp4')).assertTrue()
    })

    it('isVideo_non_video_false', 0, () => {
      expect(isVideo('image/png')).assertFalse()
    })

    // ── isMediaMime：媒体判定（图片/视频为真，其余为假） ──

    it('isMediaMime_image_true', 0, () => {
      expect(isMediaMime('image/jpeg')).assertTrue()
    })

    it('isMediaMime_video_true', 0, () => {
      expect(isMediaMime('video/mp4')).assertTrue()
    })

    it('isMediaMime_non_media_false', 0, () => {
      expect(isMediaMime('audio/mpeg')).assertFalse()
      expect(isMediaMime('application/pdf')).assertFalse()
      expect(isMediaMime('application/octet-stream')).assertFalse()
    })

    it('isMediaMime_unknown_ext_fallback_false', 0, () => {
      // 未知扩展名回退通用二进制类型，不应被判为媒体
      expect(isMediaMime(getMimeForFileName('unknown.xyz'))).assertFalse()
    })

    it('isMediaMime_from_file_name_true', 0, () => {
      expect(isMediaMime(getMimeForFileName('a.JPG'))).assertTrue()
      expect(isMediaMime(getMimeForFileName('b.mp4'))).assertTrue()
      expect(isMediaMime(getMimeForFileName('c.pdf'))).assertFalse()
    })

    // ── getMimeForExt：各类别抽样 + fallback ──

    it('getMimeForExt_image_category', 0, () => {
      expect(getMimeForExt('jpg')).assertEqual('image/jpeg')
      expect(getMimeForExt('jpeg')).assertEqual('image/jpeg')
      expect(getMimeForExt('gif')).assertEqual('image/gif')
      expect(getMimeForExt('svg')).assertEqual('image/svg+xml')
    })

    it('getMimeForExt_video_category', 0, () => {
      expect(getMimeForExt('mp4')).assertEqual('video/mp4')
      expect(getMimeForExt('mkv')).assertEqual('video/x-matroska')
    })

    it('getMimeForExt_audio_category', 0, () => {
      expect(getMimeForExt('mp3')).assertEqual('audio/mpeg')
      expect(getMimeForExt('flac')).assertEqual('audio/flac')
    })

    it('getMimeForExt_archive_category', 0, () => {
      expect(getMimeForExt('zip')).assertEqual('application/zip')
      expect(getMimeForExt('7z')).assertEqual('application/x-7z-compressed')
    })

    it('getMimeForExt_document_category', 0, () => {
      expect(getMimeForExt('pdf')).assertEqual('application/pdf')
      expect(getMimeForExt('docx'))
        .assertEqual('application/vnd.openxmlformats-officedocument.wordprocessingml.document')
    })

    it('getMimeForExt_text_category', 0, () => {
      expect(getMimeForExt('txt')).assertEqual('text/plain')
      expect(getMimeForExt('html')).assertEqual('text/html')
      expect(getMimeForExt('json')).assertEqual('application/json')
    })

    it('getMimeForExt_unknown_default', 0, () => {
      expect(getMimeForExt('xyz')).assertEqual('application/octet-stream')
    })

    // ── getMimeForFileName ──

    it('getMimeForFileName_normal', 0, () => {
      expect(getMimeForFileName('a.png')).assertEqual('image/png')
    })

    it('getMimeForFileName_noext_default', 0, () => {
      expect(getMimeForFileName('noext')).assertEqual('application/octet-stream')
    })

    it('getMimeForFileName_uppercase_ext', 0, () => {
      expect(getMimeForFileName('A.JPG')).assertEqual('image/jpeg')
    })

    it('getMimeForFileName_trailing_dot_default', 0, () => {
      expect(getMimeForFileName('file.')).assertEqual('application/octet-stream')
    })

    // ── hasDirectoryPath ──

    it('hasDirectoryPath_with_slash_true', 0, () => {
      expect(hasDirectoryPath('a/b.png')).assertTrue()
    })

    it('hasDirectoryPath_no_slash_false', 0, () => {
      expect(hasDirectoryPath('a.png')).assertFalse()
    })

    // ── isImageExtension ──

    it('isImageExtension_lowercase_true', 0, () => {
      expect(isImageExtension('png')).assertTrue()
    })

    it('isImageExtension_uppercase_true', 0, () => {
      expect(isImageExtension('PNG')).assertTrue()
    })

    it('isImageExtension_unknown_false', 0, () => {
      expect(isImageExtension('xyz')).assertFalse()
    })

    it('isImageExtension_more_values', 0, () => {
      expect(isImageExtension('jpeg')).assertTrue()
      expect(isImageExtension('svg')).assertTrue()
      expect(isImageExtension('heic')).assertTrue()
      expect(isImageExtension('zip')).assertFalse()
      expect(isImageExtension('')).assertFalse()
    })
  })
}
