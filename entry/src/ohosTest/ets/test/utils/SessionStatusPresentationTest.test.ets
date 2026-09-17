// SessionStatusPresentation 状态字符串映射测试。
// sessionStatusFromString 是 string 状态（SendViewModel.sendSessionStatuses）
// 转枚举的唯一入口，非法值须返回 undefined 由调用方回退。
import { describe, it, expect } from '@ohos/hypium'
import { sessionStatusFromString } from '../../../../main/ets/utils/SessionStatusPresentation'
import { SendSessionStatus } from '../../../../main/ets/model/Types'

export default function SessionStatusPresentationTest() {
  describe('SessionStatusPresentationTest', () => {
    it('sessionStatusFromString_maps_all_ten_statuses', 0, () => {
      expect(sessionStatusFromString('waiting') === SendSessionStatus.waiting).assertTrue()
      expect(sessionStatusFromString('calculatingHash') === SendSessionStatus.calculatingHash).assertTrue()
      expect(sessionStatusFromString('sending') === SendSessionStatus.sending).assertTrue()
      expect(sessionStatusFromString('finished') === SendSessionStatus.finished).assertTrue()
      expect(sessionStatusFromString('finishedWithErrors') === SendSessionStatus.finishedWithErrors).assertTrue()
      expect(sessionStatusFromString('declined') === SendSessionStatus.declined).assertTrue()
      expect(sessionStatusFromString('tooManyAttempts') === SendSessionStatus.tooManyAttempts).assertTrue()
      expect(sessionStatusFromString('recipientBusy') === SendSessionStatus.recipientBusy).assertTrue()
      expect(sessionStatusFromString('timeout') === SendSessionStatus.timeout).assertTrue()
      expect(sessionStatusFromString('pinRequired') === SendSessionStatus.pinRequired).assertTrue()
    })

    it('sessionStatusFromString_invalid_returns_undefined', 0, () => {
      expect(sessionStatusFromString('') === undefined).assertTrue()
      expect(sessionStatusFromString('unknown') === undefined).assertTrue()
      // 映射区分大小写
      expect(sessionStatusFromString('Waiting') === undefined).assertTrue()
    })
  })
}
