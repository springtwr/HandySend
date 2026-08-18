import { describe, it, expect } from '@ohos/hypium'
import {
  isImage, isVideo, hasDirectoryPath,
  getMimeForExt, getMimeForFileName, isImageExtension
} from '../main/ets/utils/MimeUtils'

export default function MimeUtilsTest() {
  describe('MimeUtilsTest', () => {
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
      // startsWith is case-sensitive: uppercase MIME is not recognized
      expect(isImage('IMAGE/PNG')).assertFalse()
    })

    it('isVideo_typical_true', 0, () => {
      expect(isVideo('video/mp4')).assertTrue()
    })

    it('isVideo_non_video_false', 0, () => {
      expect(isVideo('image/png')).assertFalse()
    })












    it('getMimeForExt_jpg', 0, () => {
      expect(getMimeForExt('jpg')).assertEqual('image/jpeg')
    })

    it('getMimeForExt_png', 0, () => {
      expect(getMimeForExt('png')).assertEqual('image/png')
    })

    it('getMimeForExt_mp4', 0, () => {
      expect(getMimeForExt('mp4')).assertEqual('video/mp4')
    })

    it('getMimeForExt_pdf', 0, () => {
      expect(getMimeForExt('pdf')).assertEqual('application/pdf')
    })

    it('getMimeForExt_txt', 0, () => {
      expect(getMimeForExt('txt')).assertEqual('text/plain')
    })

    it('getMimeForExt_unknown_default', 0, () => {
      expect(getMimeForExt('xyz')).assertEqual('application/octet-stream')
    })

    it('getMimeForFileName_normal', 0, () => {
      expect(getMimeForFileName('a.png')).assertEqual('image/png')
    })

    it('getMimeForFileName_noext_default', 0, () => {
      expect(getMimeForFileName('noext')).assertEqual('application/octet-stream')
    })

    it('getMimeForFileName_uppercase_ext', 0, () => {
      expect(getMimeForFileName('A.JPG')).assertEqual('image/jpeg')
    })

    it('hasDirectoryPath_with_slash_true', 0, () => {
      expect(hasDirectoryPath('a/b.png')).assertTrue()
    })

    it('hasDirectoryPath_no_slash_false', 0, () => {
      expect(hasDirectoryPath('a.png')).assertFalse()
    })

    it('isImageExtension_lowercase_true', 0, () => {
      expect(isImageExtension('png')).assertTrue()
    })

    it('isImageExtension_uppercase_true', 0, () => {
      expect(isImageExtension('PNG')).assertTrue()
    })

    it('isImageExtension_unknown_false', 0, () => {
      expect(isImageExtension('xyz')).assertFalse()
    })

    it('getMimeForExt_more_common_extensions', 0, () => {
      expect(getMimeForExt('jpeg')).assertEqual('image/jpeg')
      expect(getMimeForExt('gif')).assertEqual('image/gif')
      expect(getMimeForExt('webp')).assertEqual('image/webp')
      expect(getMimeForExt('heic')).assertEqual('image/heic')
      expect(getMimeForExt('svg')).assertEqual('image/svg+xml')
      expect(getMimeForExt('bmp')).assertEqual('image/bmp')
      expect(getMimeForExt('avi')).assertEqual('video/x-msvideo')
      expect(getMimeForExt('mkv')).assertEqual('video/x-matroska')
      expect(getMimeForExt('mov')).assertEqual('video/quicktime')
      expect(getMimeForExt('webm')).assertEqual('video/webm')
      expect(getMimeForExt('mp3')).assertEqual('audio/mpeg')
      expect(getMimeForExt('wav')).assertEqual('audio/wav')
      expect(getMimeForExt('ogg')).assertEqual('audio/ogg')
      expect(getMimeForExt('flac')).assertEqual('audio/flac')
      expect(getMimeForExt('aac')).assertEqual('audio/aac')
      expect(getMimeForExt('m4a')).assertEqual('audio/mp4')
      expect(getMimeForExt('zip')).assertEqual('application/zip')
      expect(getMimeForExt('rar')).assertEqual('application/vnd.rar')
      expect(getMimeForExt('7z')).assertEqual('application/x-7z-compressed')
      expect(getMimeForExt('tar')).assertEqual('application/x-tar')
      expect(getMimeForExt('gz')).assertEqual('application/gzip')
      expect(getMimeForExt('docx')).assertEqual('application/vnd.openxmlformats-officedocument.wordprocessingml.document')
      expect(getMimeForExt('xlsx')).assertEqual('application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
      expect(getMimeForExt('pptx')).assertEqual('application/vnd.openxmlformats-officedocument.presentationml.presentation')
      expect(getMimeForExt('json')).assertEqual('application/json')
      expect(getMimeForExt('html')).assertEqual('text/html')
      expect(getMimeForExt('apk')).assertEqual('application/vnd.android.package-archive')
      expect(getMimeForExt('exe')).assertEqual('application/x-msdownload')
    })

    it('getMimeForFileName_uppercase_jpeg', 0, () => {
      expect(getMimeForFileName('photo.JPEG')).assertEqual('image/jpeg')
    })

    it('getMimeForFileName_trailing_dot_default', 0, () => {
      expect(getMimeForFileName('file.')).assertEqual('application/octet-stream')
    })

    it('isImageExtension_more_values', 0, () => {
      expect(isImageExtension('jpeg')).assertTrue()
      expect(isImageExtension('JPG')).assertTrue()
      expect(isImageExtension('svg')).assertTrue()
      expect(isImageExtension('heic')).assertTrue()
      expect(isImageExtension('zip')).assertFalse()
      expect(isImageExtension('')).assertFalse()
    })
  })
}
