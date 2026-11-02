// ShareLinkViewModelTest：网页面板页视图模型的开关同步测试
// 覆盖网页传输总开关与允许上传开关变化时的实时同步（经既有 changeBus）。
// 用例采用「记录-恢复」模式：结束后还原宿主应用的持久化设置，避免污染。
import { describe, it, expect, beforeAll } from '@ohos/hypium'
import { ShareLinkViewModel } from '../../../../main/ets/viewmodel/ShareLinkViewModel'
import {
  getWebSendAllowed,
  setWebSendAllowed,
  getWebReceiveAllowed,
  setWebReceiveAllowed
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

    it('sendDisabled_reflectsToggleAndSyncsViaChangeBus', 0, () => {
      let origSend: boolean = getWebSendAllowed()
      let vm = new ShareLinkViewModel()
      try {
        // 开关开启：初始同步为可用
        setWebSendAllowed(true)
        vm.loadShareInfo()
        expect(vm.sendDisabled).assertFalse()

        // 开关关闭：既有 changeBus 订阅即同步禁用态为真（无需新增订阅通道）
        setWebSendAllowed(false)
        expect(vm.sendDisabled).assertTrue()

        // 重新开启：恢复为可用
        setWebSendAllowed(true)
        expect(vm.sendDisabled).assertFalse()
      } finally {
        vm.unsubscribeFromRepository()
        setWebSendAllowed(origSend)
      }
    })

    it('noFileWarning_suppressedDuringInitialSync', 0, () => {
      let vm = new ShareLinkViewModel()
      // 无文件且未处于开启瞬间：展示警告
      expect(vm.shouldShowNoFileWarning()).assertTrue()
      // 刚开启网页传输：等服务挂载暂存文件期间不展示，避免横幅闪现
      vm.suppressNoFileWarning = true
      expect(vm.shouldShowNoFileWarning()).assertFalse()
      // 文件已挂载：无论抑制状态如何都不展示
      vm.suppressNoFileWarning = false
      vm.sharedFileCount = 1
      expect(vm.shouldShowNoFileWarning()).assertFalse()
    })

    it('uploadAllowed_reflectsToggle', 0, () => {
      let origReceive: boolean = getWebReceiveAllowed()
      let vm = new ShareLinkViewModel()
      try {
        setWebReceiveAllowed(true)
        vm.loadShareInfo()
        expect(vm.uploadAllowed).assertTrue()

        setWebReceiveAllowed(false)
        expect(vm.uploadAllowed).assertFalse()
      } finally {
        vm.unsubscribeFromRepository()
        setWebReceiveAllowed(origReceive)
      }
    })
  })
}
