import { describe, it, expect } from '@ohos/hypium'
import { isLargeTransfer } from '../../../../main/ets/utils/LargeTransferUtil'
import { MtaConstants } from '../../../../main/ets/service/mta/MtaConstants'

// 大文件提示阈值纯逻辑单测（无 UIContext/native 依赖）。
export default function LargeTransferUtilTest() {
  describe('LargeTransferUtilTest', () => {
    it('small_transfer_needs_no_hint', 0, () => {
      expect(isLargeTransfer(0)).assertFalse()
      expect(isLargeTransfer(1024)).assertFalse()
      expect(isLargeTransfer(1024 * 1024 * 1024)).assertFalse()
    })

    it('total_at_threshold_needs_hint', 0, () => {
      // 总量恰达 10GB 即提示
      expect(isLargeTransfer(MtaConstants.LARGE_FILE_WARN_BYTES)).assertTrue()
      expect(isLargeTransfer(MtaConstants.LARGE_FILE_WARN_BYTES + 1)).assertTrue()
    })

    it('single_large_file_needs_hint_even_when_total_small', 0, () => {
      // 总量未达阈值但单文件达阈值同样提示
      expect(isLargeTransfer(100, MtaConstants.LARGE_FILE_WARN_BYTES)).assertTrue()
    })

    it('just_below_threshold_needs_no_hint', 0, () => {
      expect(isLargeTransfer(MtaConstants.LARGE_FILE_WARN_BYTES - 1,
        MtaConstants.LARGE_FILE_WARN_BYTES - 1)).assertFalse()
    })
  })
}
