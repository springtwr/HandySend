// FilePreviewPolicyTest：文本预览阈值与可预览性判定的纯函数用例
// 覆盖三态结论、大小不可得按可预览、阈值边界值，以及「菜单是否需说明超限」派生判定。
import { describe, it, expect } from '@ohos/hypium'
import {
  TextPreviewVerdict,
  TEXT_PREVIEW_MAX_BYTES,
  TEXT_PREVIEW_MAX_BYTES_FALLBACK,
  TEXT_PREVIEW_READ_MAX_BYTES,
  decideTextPreview,
  isTextPreviewable,
  needsOverLimitHint
} from '../../../../main/ets/utils/FilePreviewPolicy'

const LOCATION: string = '/data/storage/el2/base/files/note.txt'

export default function FilePreviewPolicyTest() {
  describe('FilePreviewPolicyTest', () => {
    it('thresholds_singleSource', 0, () => {
      // 预览阈值 128KB，读取上限与判定同源，回退值为 64KB
      expect(TEXT_PREVIEW_MAX_BYTES).assertEqual(128 * 1024)
      expect(TEXT_PREVIEW_MAX_BYTES_FALLBACK).assertEqual(64 * 1024)
      expect(TEXT_PREVIEW_READ_MAX_BYTES).assertEqual(TEXT_PREVIEW_MAX_BYTES)
    })

    it('decide_previewable_whenTextWithLocationWithinLimit', 0, () => {
      expect(decideTextPreview(true, LOCATION, 1024)).assertEqual(TextPreviewVerdict.previewable)
      expect(isTextPreviewable(true, LOCATION, 1024)).assertTrue()
      expect(needsOverLimitHint(true, LOCATION, 1024)).assertFalse()
    })

    it('decide_overLimit_whenTextWithLocationExceedsLimit', 0, () => {
      expect(decideTextPreview(true, LOCATION, TEXT_PREVIEW_MAX_BYTES + 1))
        .assertEqual(TextPreviewVerdict.overLimit)
      expect(isTextPreviewable(true, LOCATION, TEXT_PREVIEW_MAX_BYTES + 1)).assertFalse()
      expect(needsOverLimitHint(true, LOCATION, TEXT_PREVIEW_MAX_BYTES + 1)).assertTrue()
    })

    it('decide_locationUnavailable_whenNotTextOrNoLocation', 0, () => {
      // 非文本类不可预览（不进入超限态，菜单不展示预览项）
      expect(decideTextPreview(false, LOCATION, 1024)).assertEqual(TextPreviewVerdict.locationUnavailable)
      expect(needsOverLimitHint(false, LOCATION, TEXT_PREVIEW_MAX_BYTES + 1)).assertFalse()
      // 定位为空不可预览；即使大小超限也不归入超限态（无需解释预览超限）
      expect(decideTextPreview(true, '', 1024)).assertEqual(TextPreviewVerdict.locationUnavailable)
      expect(decideTextPreview(true, '', TEXT_PREVIEW_MAX_BYTES + 1))
        .assertEqual(TextPreviewVerdict.locationUnavailable)
      expect(needsOverLimitHint(true, '', TEXT_PREVIEW_MAX_BYTES + 1)).assertFalse()
    })

    it('decide_previewable_whenSizeUnknown', 0, () => {
      // 大小不可得（0 或负数）按可预览处理，不因缺信息误禁
      expect(decideTextPreview(true, LOCATION, 0)).assertEqual(TextPreviewVerdict.previewable)
      expect(decideTextPreview(true, LOCATION, -1)).assertEqual(TextPreviewVerdict.previewable)
      expect(isTextPreviewable(true, LOCATION, 0)).assertTrue()
    })

    it('decide_boundary_atThresholdIsPreviewable', 0, () => {
      // 阈值边界：恰好等于阈值按可预览处理，仅严格超过才降级
      expect(decideTextPreview(true, LOCATION, TEXT_PREVIEW_MAX_BYTES))
        .assertEqual(TextPreviewVerdict.previewable)
      expect(decideTextPreview(true, LOCATION, TEXT_PREVIEW_MAX_BYTES + 1))
        .assertEqual(TextPreviewVerdict.overLimit)
      // 回退阈值同样按「严格超过」判定
      expect(decideTextPreview(true, LOCATION, TEXT_PREVIEW_MAX_BYTES_FALLBACK))
        .assertEqual(TextPreviewVerdict.previewable)
    })
  })
}
