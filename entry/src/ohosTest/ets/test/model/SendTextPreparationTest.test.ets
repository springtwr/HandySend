import { describe, it, expect } from '@ohos/hypium'
import { collectManualTextUris, isAllManualText, isSingleTextMessageSend } from '../../../../main/ets/model/SendTextPreparation'
import { SendFileItem, StagedFile } from '../../../../main/ets/model/Types'

// 构造手动文本来源的暂存条目样本（用户手动输入/粘贴/分享的文本）
function manualTextStaged(uri: string): StagedFile {
  return {
    uri: uri,
    fileName: 'manual.txt',
    fileType: 'text/plain',
    isImage: false,
    isManualText: true
  };
}

// 构造未标记来源的暂存条目样本（用户主动选择的文件，含 .txt）
function pickedFileStaged(uri: string): StagedFile {
  return {
    uri: uri,
    fileName: 'picked.txt',
    fileType: 'text/plain',
    isImage: false
  };
}

// 构造文本类型的发送条目样本；未传 preview 表示不承载文本内容信息
// （用户主动选择的 .txt 文件即属此类，不得被判为文本消息）
function sendTextItem(preview?: string): SendFileItem {
  return {
    fileId: 'text-id',
    filePath: '/tmp/manual.txt',
    fileName: 'manual.txt',
    fileType: 'text/plain',
    size: 10,
    preview: preview
  };
}

// 构造非文本类型的发送条目样本（图片）；即便带有 preview 也不得被判为文本消息
function sendImageItem(preview?: string): SendFileItem {
  return {
    fileId: 'image-id',
    filePath: '/tmp/photo.png',
    fileName: 'photo.png',
    fileType: 'image/png',
    size: 10,
    preview: preview
  };
}

// 手动文本纯函数测试：
// 1. 筛选函数：空集合、全为手动文本、混合集合排除普通文件、显式非手动标记排除、
//    无标记条目、顺序保持与入参不变。
// 2. 「全部为手动文本」判定：空集合返回假、全部为真、含未标记/显式非手动条目为假。
// 3. 「单条文本消息」判据：单条文本消息（带 preview）为真，单条无 preview 的文本文件、
//    preview 为空的文本条目、多条文本消息、单个非文本条目、空集合均为假。
export default function SendTextPreparationTest() {
  describe('SendTextPreparationTest', () => {
    it('manual_text_empty_input', 0, () => {
      let input: Array<StagedFile> = [];
      let result: Array<string> = collectManualTextUris(input);
      expect(result.length).assertEqual(0);
    })

    it('manual_text_all_manual', 0, () => {
      let input: Array<StagedFile> = [manualTextStaged('a'), manualTextStaged('b')];
      let result: Array<string> = collectManualTextUris(input);
      expect(result.length).assertEqual(2);
      expect(result[0]).assertEqual('a');
      expect(result[1]).assertEqual('b');
    })

    it('manual_text_mixed_excludes_picked_files', 0, () => {
      let input: Array<StagedFile> = [manualTextStaged('a'), pickedFileStaged('b'), manualTextStaged('c')];
      let result: Array<string> = collectManualTextUris(input);
      expect(result.length).assertEqual(2);
      expect(result[0]).assertEqual('a');
      expect(result[1]).assertEqual('c');
    })

    it('manual_text_explicit_false_excluded', 0, () => {
      let input: Array<StagedFile> = [pickedFileStaged('a'), manualTextStaged('b')];
      input[0].isManualText = false;
      let result: Array<string> = collectManualTextUris(input);
      expect(result.length).assertEqual(1);
      expect(result[0]).assertEqual('b');
    })

    it('manual_text_none_marked', 0, () => {
      let input: Array<StagedFile> = [pickedFileStaged('a'), pickedFileStaged('b')];
      let result: Array<string> = collectManualTextUris(input);
      expect(result.length).assertEqual(0);
    })

    it('manual_text_preserves_input_order', 0, () => {
      let input: Array<StagedFile> = [
        manualTextStaged('t1'),
        pickedFileStaged('f1'),
        manualTextStaged('t2'),
        pickedFileStaged('f2'),
        manualTextStaged('t3')
      ];
      let result: Array<string> = collectManualTextUris(input);
      expect(result.length).assertEqual(3);
      expect(result[0]).assertEqual('t1');
      expect(result[1]).assertEqual('t2');
      expect(result[2]).assertEqual('t3');
    })

    it('manual_text_does_not_mutate_input', 0, () => {
      let input: Array<StagedFile> = [manualTextStaged('a'), pickedFileStaged('b')];
      let result: Array<string> = collectManualTextUris(input);
      expect(input.length).assertEqual(2);
      expect(input[0].uri).assertEqual('a');
      expect(input[1].uri).assertEqual('b');
      expect(input[0].isManualText === true).assertTrue();
      expect(input[1].isManualText === true).assertFalse();
      expect(result.length).assertEqual(1);
      expect(result[0]).assertEqual('a');
    })

    // ── 「全部为手动文本」判定 ──

    it('all_manual_text_empty_is_false', 0, () => {
      let input: Array<StagedFile> = [];
      expect(isAllManualText(input)).assertFalse();
    })

    it('all_manual_text_all_manual_is_true', 0, () => {
      let input: Array<StagedFile> = [manualTextStaged('a'), manualTextStaged('b')];
      expect(isAllManualText(input)).assertTrue();
      // 判定不修改入参
      expect(input.length).assertEqual(2);
      expect(input[0].isManualText === true).assertTrue();
      expect(input[1].isManualText === true).assertTrue();
    })

    it('all_manual_text_non_manual_is_false', 0, () => {
      // 未标记来源的条目（用户主动选择的文件）
      let picked: Array<StagedFile> = [manualTextStaged('a'), pickedFileStaged('b')];
      expect(isAllManualText(picked)).assertFalse();
      // 显式标记为非手动文本的条目
      let explicitFalse: Array<StagedFile> = [manualTextStaged('a'), manualTextStaged('b')];
      explicitFalse[1].isManualText = false;
      expect(isAllManualText(explicitFalse)).assertFalse();
    })

    // ── 「单条文本消息」判据 ──

    it('single_text_message_with_preview_is_true', 0, () => {
      let input: Array<SendFileItem> = [sendTextItem('你好，世界')];
      expect(isSingleTextMessageSend(input)).assertTrue();
      // 判定不修改入参
      expect(input.length).assertEqual(1);
      expect(input[0].preview).assertEqual('你好，世界');
      expect(input[0].fileType).assertEqual('text/plain');
    })

    it('single_text_file_without_preview_is_false', 0, () => {
      // 用户主动选择的 .txt 文件：文本类型但不承载文本内容信息
      let input: Array<SendFileItem> = [sendTextItem()];
      expect(isSingleTextMessageSend(input)).assertFalse();
    })

    it('single_text_item_with_empty_preview_is_false', 0, () => {
      // 文本内容信息为空串不算承载文本内容
      let input: Array<SendFileItem> = [sendTextItem('')];
      expect(isSingleTextMessageSend(input)).assertFalse();
    })

    it('multiple_text_messages_is_false', 0, () => {
      let input: Array<SendFileItem> = [sendTextItem('a'), sendTextItem('b')];
      expect(isSingleTextMessageSend(input)).assertFalse();
    })

    it('single_non_text_item_is_false', 0, () => {
      // 非文本类型即使带 preview 也不构成文本消息
      let input: Array<SendFileItem> = [sendImageItem('not-a-text-message')];
      expect(isSingleTextMessageSend(input)).assertFalse();
    })

    it('single_text_message_empty_input_is_false', 0, () => {
      let input: Array<SendFileItem> = [];
      expect(isSingleTextMessageSend(input)).assertFalse();
    })
  })
}
