import { describe, it, expect } from '@ohos/hypium'
import {
  RECEIVE_STORAGE_RESERVE_BYTES,
  StorageCheckVerdict,
  decideStorageCheck
} from '../../../../main/ets/utils/StorageCheck'

// 存储预留检查纯逻辑单测（无 UIContext/native 依赖；可用空间查询由调用方执行）。
export default function StorageCheckTest() {
  describe('StorageCheckTest', () => {
    it('sufficient_when_free_covers_declared_plus_reserve', 0, () => {
      expect(decideStorageCheck(2000, 1000, 500)).assertEqual(StorageCheckVerdict.sufficient)
      // 恰好相等即通过
      expect(decideStorageCheck(1500, 1000, 500)).assertEqual(StorageCheckVerdict.sufficient)
    })

    it('insufficient_when_free_below_required', 0, () => {
      expect(decideStorageCheck(1499, 1000, 500)).assertEqual(StorageCheckVerdict.insufficient)
      expect(decideStorageCheck(0, 1000, 500)).assertEqual(StorageCheckVerdict.insufficient)
    })

    it('unknown_when_free_unavailable', 0, () => {
      // 可用空间查询失败（-1）：调用方放行并留痕，不阻断合法接收
      expect(decideStorageCheck(-1, 1000, 500)).assertEqual(StorageCheckVerdict.unknown)
    })

    it('reserve_constant_matches_mta_reserve', 0, () => {
      // 接收预留量与 MTA 预留量同值，避免两处口径分叉
      expect(RECEIVE_STORAGE_RESERVE_BYTES).assertEqual(256 * 1024 * 1024)
    })
  })
}
