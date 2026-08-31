// Instrument Test Ability：承载 ohosTest 运行时的 Ability 生命周期
import { abilityDelegatorRegistry } from '@kit.TestKit'
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { Hypium } from '@ohos/hypium'
import { setTestAppContext } from '../test/helper/TestContext'
import testsuite from '../test/List.test'

export default class TestAbility extends UIAbility {
  abilityDelegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator()

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 注入测试进程 context（测试文件经 TestContext 获取沙箱路径）
    setTestAppContext(this.context)
    let abilityDelegatorArguments: abilityDelegatorRegistry.AbilityDelegatorArgs =
      abilityDelegatorRegistry.getArguments()
    // 初始化 Hypium 测试框架，注册测试套件
    Hypium.hypiumTest(this.abilityDelegator, abilityDelegatorArguments, testsuite)
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 加载测试入口页面
    windowStage.loadContent('testability/pages/Index', (err) => {
      if (err.code) {
        return
      }
    })
  }
}
