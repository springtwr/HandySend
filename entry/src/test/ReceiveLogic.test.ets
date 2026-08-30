// ReceiveLogic.test：自动接收决策纯逻辑测试
// 覆盖 computeShouldAutoAccept 的所有条件组合
import { describe, it, expect } from '@ohos/hypium'
import { computeShouldAutoAccept } from '../../../main/ets/service/repository/ReceiveRepository'
import { AutoConfirmMode, FavoriteDevice } from '../../../main/ets/model/Types'

export default function ReceiveLogicTest() {
  describe('ReceiveLogicTest', () => {

    // ── off 模式 ──

    it('off_mode_never_auto_accepts', 0, () => {
      let favs: Array<FavoriteDevice> = []
      expect(computeShouldAutoAccept(AutoConfirmMode.off, favs, 'fp1', false)).assertFalse()
    })

    // ── on 模式 ──

    it('on_mode_auto_accepts_without_message', 0, () => {
      let favs: Array<FavoriteDevice> = []
      expect(computeShouldAutoAccept(AutoConfirmMode.on, favs, 'fp1', false)).assertTrue()
    })

    it('on_mode_does_not_auto_accept_with_message', 0, () => {
      let favs: Array<FavoriteDevice> = []
      expect(computeShouldAutoAccept(AutoConfirmMode.on, favs, 'fp1', true)).assertFalse()
    })

    // ── paired 模式 ──

    it('paired_mode_accepts_favorite_device', 0, () => {
      let favs: Array<FavoriteDevice> = [{
        id: '1', fingerprint: 'fp1', ip: '192.168.1.100', port: 53317,
        alias: 'TestDevice', customAlias: false
      }]
      expect(computeShouldAutoAccept(AutoConfirmMode.paired, favs, 'fp1', false)).assertTrue()
    })

    it('paired_mode_rejects_unknown_device', 0, () => {
      let favs: Array<FavoriteDevice> = [{
        id: '1', fingerprint: 'fp1', ip: '192.168.1.100', port: 53317,
        alias: 'TestDevice', customAlias: false
      }]
      expect(computeShouldAutoAccept(AutoConfirmMode.paired, favs, 'fp2', false)).assertFalse()
    })

    it('paired_mode_rejects_favorite_device_with_message', 0, () => {
      let favs: Array<FavoriteDevice> = [{
        id: '1', fingerprint: 'fp1', ip: '192.168.1.100', port: 53317,
        alias: 'TestDevice', customAlias: false
      }]
      expect(computeShouldAutoAccept(AutoConfirmMode.paired, favs, 'fp1', true)).assertFalse()
    })

    it('paired_mode_rejects_with_empty_favorites', 0, () => {
      let favs: Array<FavoriteDevice> = []
      expect(computeShouldAutoAccept(AutoConfirmMode.paired, favs, 'fp1', false)).assertFalse()
    })

  })
}
