// FileTypeIconUtil 设备端单测：覆盖文件类型 → 图标资源映射的判定链
// （isMessage → MIME 前缀 → MIME 精确匹配 → 扩展名回退 → unknown 兜底）

import { describe, it, expect } from '@ohos/hypium'
import { getFileTypeIconResource } from '../../../../main/ets/utils/FileTypeIconUtil'

// 断言两个资源指向同一媒体资源（按编译期资源 id 判定）
function expectIcon(actual: Resource, expected: Resource): void {
  expect(actual.id).assertEqual(expected.id)
}

export default function FileTypeIconUtilTest() {
  describe('FileTypeIconUtilTest', () => {
    // ── isMessage：纯文本消息最优先 ──

    it('isMessage_true_returns_message', 0, () => {
      expectIcon(
        getFileTypeIconResource(true, 'message.txt', 'text/plain'),
        $r('app.media.ic_file_message')
      )
    })

    it('isMessage_true_overrides_media_mime', 0, () => {
      // isMessage 优先级最高，即使 MIME 是图片也显示消息图标
      expectIcon(
        getFileTypeIconResource(true, 'a.png', 'image/png'),
        $r('app.media.ic_file_message')
      )
    })

    // ── MIME 前缀：image / video / audio ──

    it('image_prefix_returns_image', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'a.png', 'image/png'),
        $r('app.media.ic_file_image')
      )
      expectIcon(
        getFileTypeIconResource(false, 'b.jpg', 'image/jpeg'),
        $r('app.media.ic_file_image')
      )
    })

    it('video_prefix_returns_video', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'c.mp4', 'video/mp4'),
        $r('app.media.ic_file_video')
      )
    })

    it('audio_prefix_returns_audio', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'd.mp3', 'audio/mpeg'),
        $r('app.media.ic_file_audio')
      )
    })

    // ── MIME 精确匹配：逐类抽查 ──

    it('pdf_exact_match', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'doc.pdf', 'application/pdf'),
        $r('app.media.ic_file_pdf')
      )
    })

    it('word_family_exact_match', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'a.doc', 'application/msword'),
        $r('app.media.ic_file_word')
      )
      expectIcon(
        getFileTypeIconResource(
          false,
          'b.docx',
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
        ),
        $r('app.media.ic_file_word')
      )
      expectIcon(
        getFileTypeIconResource(false, 'c.wps', 'application/kswps'),
        $r('app.media.ic_file_word')
      )
    })

    it('excel_family_exact_match', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'a.xls', 'application/vnd.ms-excel'),
        $r('app.media.ic_file_excel')
      )
      expectIcon(
        getFileTypeIconResource(
          false,
          'b.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        ),
        $r('app.media.ic_file_excel')
      )
      expectIcon(
        getFileTypeIconResource(false, 'c.et', 'application/kset'),
        $r('app.media.ic_file_excel')
      )
    })

    it('ppt_family_exact_match', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'a.ppt', 'application/vnd.ms-powerpoint'),
        $r('app.media.ic_file_ppt')
      )
      expectIcon(
        getFileTypeIconResource(
          false,
          'b.pptx',
          'application/vnd.openxmlformats-officedocument.presentationml.presentation'
        ),
        $r('app.media.ic_file_ppt')
      )
      expectIcon(
        getFileTypeIconResource(false, 'c.dps', 'application/ksdps'),
        $r('app.media.ic_file_ppt')
      )
    })

    it('ofd_exact_match', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, '发票.ofd', 'application/ofd'),
        $r('app.media.ic_file_ofd')
      )
    })

    it('flow_family_octet_stream_fallback', 0, () => {
      // 六种流程图格式：MIME 为 octet-stream 时经扩展名回退统一命中流程图图标
      expectIcon(
        getFileTypeIconResource(false, 'a.pom', 'application/octet-stream'),
        $r('app.media.ic_file_flow')
      )
      expectIcon(
        getFileTypeIconResource(false, 'b.vsd', 'application/octet-stream'),
        $r('app.media.ic_file_flow')
      )
      expectIcon(
        getFileTypeIconResource(false, 'c.vsdx', 'application/octet-stream'),
        $r('app.media.ic_file_flow')
      )
      expectIcon(
        getFileTypeIconResource(false, 'd.drawio', 'application/octet-stream'),
        $r('app.media.ic_file_flow')
      )
      expectIcon(
        getFileTypeIconResource(false, 'e.eddx', 'application/octet-stream'),
        $r('app.media.ic_file_flow')
      )
      expectIcon(
        getFileTypeIconResource(false, 'f.pos', 'application/octet-stream'),
        $r('app.media.ic_file_flow')
      )
    })

    it('flow_family_exact_match', 0, () => {
      // 对端已声明真实流程图 MIME 时直接精确命中
      expectIcon(
        getFileTypeIconResource(false, 'a.vsdx', 'application/vnd.ms-visio.drawing'),
        $r('app.media.ic_file_flow')
      )
      expectIcon(
        getFileTypeIconResource(false, 'b.drawio', 'application/x-drawio'),
        $r('app.media.ic_file_flow')
      )
    })

    it('mindmap_exact_match', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'a.xmind', 'application/x-xmind'),
        $r('app.media.ic_file_mindmap')
      )
      expectIcon(
        getFileTypeIconResource(false, 'b.mm', 'application/x-freemind'),
        $r('app.media.ic_file_mindmap')
      )
      expectIcon(
        getFileTypeIconResource(false, 'c.opml', 'text/x-opml'),
        $r('app.media.ic_file_mindmap')
      )
    })

    it('archive_exact_match', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'a.zip', 'application/zip'),
        $r('app.media.ic_file_archive')
      )
      expectIcon(
        getFileTypeIconResource(false, 'b.rar', 'application/vnd.rar'),
        $r('app.media.ic_file_archive')
      )
      expectIcon(
        getFileTypeIconResource(false, 'c.7z', 'application/x-7z-compressed'),
        $r('app.media.ic_file_archive')
      )
      expectIcon(
        getFileTypeIconResource(false, 'd.tar', 'application/x-tar'),
        $r('app.media.ic_file_archive')
      )
      expectIcon(
        getFileTypeIconResource(false, 'e.gz', 'application/gzip'),
        $r('app.media.ic_file_archive')
      )
    })

    it('txt_exact_match', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, '笔记.txt', 'text/plain'),
        $r('app.media.ic_file_txt')
      )
    })

    it('code_family_exact_match', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'a.html', 'text/html'),
        $r('app.media.ic_file_code')
      )
      expectIcon(
        getFileTypeIconResource(false, 'b.css', 'text/css'),
        $r('app.media.ic_file_code')
      )
      expectIcon(
        getFileTypeIconResource(false, 'c.js', 'application/javascript'),
        $r('app.media.ic_file_code')
      )
      expectIcon(
        getFileTypeIconResource(false, 'd.js', 'text/javascript'),
        $r('app.media.ic_file_code')
      )
      expectIcon(
        getFileTypeIconResource(false, 'e.json', 'application/json'),
        $r('app.media.ic_file_code')
      )
      expectIcon(
        getFileTypeIconResource(false, 'f.xml', 'application/xml'),
        $r('app.media.ic_file_code')
      )
      expectIcon(
        getFileTypeIconResource(false, 'g.xml', 'text/xml'),
        $r('app.media.ic_file_code')
      )
    })

    it('apk_exact_match', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'app.apk', 'application/vnd.android.package-archive'),
        $r('app.media.ic_file_apk')
      )
    })

    it('exe_exact_match', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'tool.exe', 'application/x-msdownload'),
        $r('app.media.ic_file_exe')
      )
    })

    // ── octet-stream / MIME 缺失：按扩展名回退 ──

    it('octet_stream_fallback_by_ext', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'report.pdf', 'application/octet-stream'),
        $r('app.media.ic_file_pdf')
      )
      expectIcon(
        getFileTypeIconResource(false, 'app.apk', 'application/octet-stream'),
        $r('app.media.ic_file_apk')
      )
      expectIcon(
        getFileTypeIconResource(false, '存档.zip', 'application/octet-stream'),
        $r('app.media.ic_file_archive')
      )
    })

    it('empty_mime_fallback_by_ext', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, '歌曲.mp3', ''),
        $r('app.media.ic_file_audio')
      )
    })

    it('uppercase_ext_fallback', 0, () => {
      // 扩展名大小写不敏感（getMimeForFileName 已统一转小写）
      expectIcon(
        getFileTypeIconResource(false, 'A.PDF', 'application/octet-stream'),
        $r('app.media.ic_file_pdf')
      )
    })

    // ── unknown 兜底 ──

    it('octet_stream_no_ext_returns_unknown', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'noext', 'application/octet-stream'),
        $r('app.media.ic_file_unknown')
      )
    })

    it('unrecognized_ext_returns_unknown', 0, () => {
      expectIcon(
        getFileTypeIconResource(false, 'file.xyz', 'application/octet-stream'),
        $r('app.media.ic_file_unknown')
      )
    })
  })
}
