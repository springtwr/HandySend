// TransferLimitsTest：批量上限与软提示阈值的边界。
import { describe, it, expect } from '@ohos/hypium'
import {
  MAX_BATCH_FILES,
  MAX_PICK_SELECT_NUMBER,
  SOFT_WARN_BATCH_FILES,
  SUMMARY_DETAIL_THRESHOLD,
  isOverBatchLimit,
  needsCompressHint
} from '../../../../main/ets/model/TransferLimits'

export default function TransferLimitsTest() {
  describe('TransferLimitsTest', () => {
    it('constants_are_pinned', 0, () => {
      expect(MAX_BATCH_FILES).assertEqual(2000)
      expect(SOFT_WARN_BATCH_FILES).assertEqual(500)
      expect(SUMMARY_DETAIL_THRESHOLD).assertEqual(100)
      expect(MAX_PICK_SELECT_NUMBER).assertEqual(500)
    })

    it('hard_limit_boundary', 0, () => {
      expect(isOverBatchLimit(2000)).assertFalse()
      expect(isOverBatchLimit(2001)).assertTrue()
      expect(isOverBatchLimit(0)).assertFalse()
    })

    it('soft_hint_boundary', 0, () => {
      expect(needsCompressHint(500)).assertFalse()
      expect(needsCompressHint(501)).assertTrue()
      expect(needsCompressHint(2000)).assertTrue()
    })
  })
}
