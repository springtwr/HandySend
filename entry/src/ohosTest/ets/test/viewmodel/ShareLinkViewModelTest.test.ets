// ShareLinkViewModelTest：分享链接页视图模型的协议禁用态同步测试
// 覆盖 LocalSend 总开关关闭时 localSendDisabled 为真，以及经既有 changeBus 的实时同步。
// 用例采用「记录-恢复」模式：结束后还原宿主应用的持久化设置，避免污染。
import { describe, it, expect, beforeAll } from '@ohos/hypium'
import { ShareLinkViewModel } from '../../../../main/ets/viewmodel/ShareLinkViewModel'
import {
  getLocalSendEnabled,
  setLocalSendEnabled
} from '../../../../main/ets/service/repository/SettingsRepository'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import { getTestAppContext } from '../helper/TestContext'

export default function ShareLinkViewModelTest() {
  describe('ShareLinkViewModelTest', () => {

    beforeAll(() => {
      // 初始化偏好存储（测试环境未走 App 主流程，preferences 未初始化）
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        initAllPreferences(ctx)
      }
    })

    it('localSendDisabled_reflectsToggleAndSyncsViaChangeBus', 0, () => {
      let orig: boolean = getLocalSendEnabled()
      let vm = new ShareLinkViewModel()
      try {
        // 开关开启：初始同步为可用
        setLocalSendEnabled(true)
        vm.loadShareInfo('http://test.local:53317')
        expect(vm.localSendDisabled).assertFalse()

        // 开关关闭：既有 changeBus 订阅即同步禁用态为真（无需新增订阅通道）
        setLocalSendEnabled(false)
        expect(vm.localSendDisabled).assertTrue()

        // 重新开启：恢复为可用
        setLocalSendEnabled(true)
        expect(vm.localSendDisabled).assertFalse()
      } finally {
        vm.unsubscribeFromRepository()
        setLocalSendEnabled(orig)
      }
    })
  })
}
