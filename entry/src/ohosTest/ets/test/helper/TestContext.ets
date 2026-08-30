// TestContext：测试进程上下文持有器
// TestAbility.onCreate 注入 UIAbilityContext，测试文件经此获取
// 测试 HAP 自己的沙箱目录（filesDir/cacheDir 与主 entry 模块不同）。
import { common } from '@kit.AbilityKit'

let appContext: common.UIAbilityContext | undefined = undefined

export function setTestAppContext(ctx: common.UIAbilityContext): void {
  appContext = ctx
}

export function getTestAppContext(): common.UIAbilityContext | undefined {
  return appContext
}
