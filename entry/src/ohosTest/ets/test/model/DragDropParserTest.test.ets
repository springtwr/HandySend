import { describe, it, expect } from '@ohos/hypium'
import { unifiedDataChannel } from '@kit.ArkData'
import {
  parseDroppedRecords,
  DragDropParseResult,
  DroppedTextItem
} from '../../../../main/ets/model/DragDropParser'

// ── 记录构造辅助 ──
// 按官方统一数据内容（UDC）写入模式构造：子类无参构造 + 设置各自 uri/内容属性，
// getType() 由框架按子类返回对应 UTD（与拖拽落盘时系统传递的记录形态一致）。

// 普通文件记录（File 基类，uri 指向文件）
function fileRecord(uri: string): unifiedDataChannel.UnifiedRecord {
  let record = new unifiedDataChannel.File();
  record.uri = uri;
  return record;
}

// 图片记录（Image 子类，独立属性 imageUri）
function imageRecord(uri: string): unifiedDataChannel.UnifiedRecord {
  let record = new unifiedDataChannel.Image();
  record.imageUri = uri;
  return record;
}

// 视频记录（Video 子类，独立属性 videoUri）
function videoRecord(uri: string): unifiedDataChannel.UnifiedRecord {
  let record = new unifiedDataChannel.Video();
  record.videoUri = uri;
  return record;
}

// 音频记录（Audio 子类，独立属性 audioUri）
function audioRecord(uri: string): unifiedDataChannel.UnifiedRecord {
  let record = new unifiedDataChannel.Audio();
  record.audioUri = uri;
  return record;
}

// 纯文本记录（PlainText 子类）
function plainTextRecord(content: string): unifiedDataChannel.UnifiedRecord {
  let record = new unifiedDataChannel.PlainText();
  record.textContent = content;
  return record;
}

// 超链接记录（Hyperlink 子类：url 为链接地址，description 为链接描述）
function hyperlinkRecord(url: string, description: string): unifiedDataChannel.UnifiedRecord {
  let record = new unifiedDataChannel.Hyperlink();
  record.url = url;
  record.description = description;
  return record;
}

// 文件夹记录（Folder 子类，属不支持类型）
function folderRecord(uri: string): unifiedDataChannel.UnifiedRecord {
  let record = new unifiedDataChannel.Folder();
  record.folderUri = uri;
  return record;
}

// 拖入记录解析纯函数测试：
// 1. 文件类分流：File 基类读 uri，Image/Video/Audio 读各自独立 uri 属性，均进入 uris。
// 2. 文本类分流：PlainText 取 textContent（isLink=false）；Hyperlink 按
//    「描述+换行+URL」组合（isLink=true），仅其一非空时用其值，均空则跳过。
// 3. 边界：不支持类型（Folder 等）跳过、空数组返回空结果、全不支持返回空结果、空内容文本跳过。
export default function DragDropParserTest() {
  describe('DragDropParserTest', () => {
    // ── 文件类分流 ──

    it('file_record_goes_to_uris', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([fileRecord('file://docs/report.pdf')]);
      expect(result.uris.length).assertEqual(1);
      expect(result.uris[0]).assertEqual('file://docs/report.pdf');
      expect(result.texts.length).assertEqual(0);
    })

    it('image_record_reads_image_uri', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([imageRecord('file://media/photo.jpg')]);
      expect(result.uris.length).assertEqual(1);
      expect(result.uris[0]).assertEqual('file://media/photo.jpg');
    })

    it('video_record_reads_video_uri', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([videoRecord('file://media/movie.mp4')]);
      expect(result.uris.length).assertEqual(1);
      expect(result.uris[0]).assertEqual('file://media/movie.mp4');
    })

    it('audio_record_reads_audio_uri', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([audioRecord('file://media/song.mp3')]);
      expect(result.uris.length).assertEqual(1);
      expect(result.uris[0]).assertEqual('file://media/song.mp3');
    })

    // ── 文本类分流 ──

    it('plain_text_record_goes_to_texts_without_link_flag', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([plainTextRecord('这是一段纯文本')]);
      expect(result.uris.length).assertEqual(0);
      expect(result.texts.length).assertEqual(1);
      expect(result.texts[0].content).assertEqual('这是一段纯文本');
      expect(result.texts[0].isLink).assertFalse();
    })

    it('hyperlink_combines_description_and_url', 0, () => {
      let result: DragDropParseResult =
        parseDroppedRecords([hyperlinkRecord('https://example.com', '示例站点')]);
      expect(result.texts.length).assertEqual(1);
      expect(result.texts[0].content).assertEqual('示例站点\nhttps://example.com');
      expect(result.texts[0].isLink).assertTrue();
    })

    it('hyperlink_only_url_uses_url', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([hyperlinkRecord('https://example.com', '')]);
      expect(result.texts.length).assertEqual(1);
      expect(result.texts[0].content).assertEqual('https://example.com');
      expect(result.texts[0].isLink).assertTrue();
    })

    it('hyperlink_only_description_uses_description', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([hyperlinkRecord('', '示例站点')]);
      expect(result.texts.length).assertEqual(1);
      expect(result.texts[0].content).assertEqual('示例站点');
      expect(result.texts[0].isLink).assertTrue();
    })

    it('hyperlink_both_empty_is_skipped', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([hyperlinkRecord('', '')]);
      expect(result.uris.length).assertEqual(0);
      expect(result.texts.length).assertEqual(0);
    })

    it('empty_plain_text_is_skipped', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([plainTextRecord('')]);
      expect(result.texts.length).assertEqual(0);
    })

    // ── 混合与边界 ──

    it('mixed_records_split_by_type', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([
        fileRecord('file://docs/a.txt'),
        plainTextRecord('hello'),
        imageRecord('file://media/b.png'),
        hyperlinkRecord('https://example.com', '站点')
      ]);
      expect(result.uris.length).assertEqual(2);
      expect(result.uris[0]).assertEqual('file://docs/a.txt');
      expect(result.uris[1]).assertEqual('file://media/b.png');
      expect(result.texts.length).assertEqual(2);
      expect(result.texts[0].content).assertEqual('hello');
      expect(result.texts[1].content).assertEqual('站点\nhttps://example.com');
    })

    it('unsupported_folder_is_skipped', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([folderRecord('file://docs/folder')]);
      expect(result.uris.length).assertEqual(0);
      expect(result.texts.length).assertEqual(0);
    })

    it('empty_records_returns_empty_result', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([]);
      expect(result.uris.length).assertEqual(0);
      expect(result.texts.length).assertEqual(0);
    })

    it('only_unsupported_records_returns_empty_result', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([
        folderRecord('file://docs/f1'),
        folderRecord('file://docs/f2')
      ]);
      expect(result.uris.length).assertEqual(0);
      expect(result.texts.length).assertEqual(0);
    })

    it('supported_and_unsupported_mixed_keeps_only_supported', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([
        folderRecord('file://docs/folder'),
        fileRecord('file://docs/keep.txt')
      ]);
      expect(result.uris.length).assertEqual(1);
      expect(result.uris[0]).assertEqual('file://docs/keep.txt');
      expect(result.texts.length).assertEqual(0);
    })

    it('records_order_is_preserved', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([
        fileRecord('file://docs/1.txt'),
        fileRecord('file://docs/2.txt'),
        fileRecord('file://docs/3.txt')
      ]);
      expect(result.uris.length).assertEqual(3);
      expect(result.uris[0]).assertEqual('file://docs/1.txt');
      expect(result.uris[1]).assertEqual('file://docs/2.txt');
      expect(result.uris[2]).assertEqual('file://docs/3.txt');
    })

    it('text_item_shape_carries_content_and_link_flag', 0, () => {
      let result: DragDropParseResult = parseDroppedRecords([plainTextRecord('shape-check')]);
      let item: DroppedTextItem = result.texts[0];
      expect(item.content).assertEqual('shape-check');
      expect(item.isLink).assertFalse();
    })
  })
}
