// OpenHarmonyTestRunner：Instrument Test 标准测试运行器
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit'
import { UIAbility, common, application } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

let abilityDelegator: abilityDelegatorRegistry.AbilityDelegator
let abilityDelegatorArguments: abilityDelegatorRegistry.AbilityDelegatorArgs
const TAG: string = 'HandySendTest'
const UNLOCK_ERROR: number = -3

async function onAbilityCreateCallback(data: UIAbility): Promise<void> {
  hilog.info(0x0000, TAG, 'onAbilityCreateCallback')
}

async function addAbilityMonitorCallback(err: BusinessError): Promise<void> {
  hilog.info(0x0000, TAG, 'addAbilityMonitorCallback: %{public}s', JSON.stringify(err) ?? '')
}

export default class OpenHarmonyTestRunner implements TestRunner {
  onPrepare(): void {
    hilog.info(0x0000, TAG, 'OpenHarmonyTestRunner onPrepare')
  }

  async onRun(): Promise<void> {
    hilog.info(0x0000, TAG, 'OpenHarmonyTestRunner onRun')
    abilityDelegatorArguments = abilityDelegatorRegistry.getArguments()
    abilityDelegator = abilityDelegatorRegistry.getAbilityDelegator()
    let moduleName: string = abilityDelegatorArguments.parameters['-m']
    try {
      let context: Context = await application.createModuleContext(
        abilityDelegator.getAppContext().getApplicationContext(), moduleName)
      doOnRun(context, moduleName)
    } catch (error) {
      let e = error as BusinessError
      hilog.error(0x0000, TAG,
        `createModuleContext failed, code: ${e.code}, message: ${e.message}`)
    }
  }
}

async function doOnRun(context: common.Context, moduleName: string): Promise<void> {
  let bundleName: string = abilityDelegatorArguments.bundleName
  let testAbilityName: string = 'TestAbility'
  let parameters: Record<string, string> = abilityDelegatorArguments.parameters
  let isDebug: boolean = parameters['-D'] === 'true'
  let lMonitor: abilityDelegatorRegistry.AbilityMonitor = {
    abilityName: testAbilityName,
    onAbilityCreate: onAbilityCreateCallback,
    moduleName: moduleName
  }
  abilityDelegator.addAbilityMonitor(lMonitor, addAbilityMonitorCallback)
  await startAbility(bundleName, testAbilityName, moduleName, isDebug)
  hilog.info(0x0000, TAG, 'OpenHarmonyTestRunner onRun end')
}

async function startAbility(bundleName: string, abilityName: string, moduleName: string, isDebug: boolean): Promise<void> {
  let command: string = `aa start -b ${bundleName} -a ${abilityName} -m ${moduleName}`
  if (isDebug) {
    command += ' -D'
  }
  try {
    let result = await abilityDelegator.executeShellCommand(command)
    if (result.stdResult.includes('error: unlock screen failed in developer mode')
      || result.stdResult.includes('10106102')) {
      hilog.info(0x0000, TAG, 'startAbility failed: %{public}s', result.stdResult)
      abilityDelegator.finishTest('', UNLOCK_ERROR, () => {
      })
    }
  } catch (err) {
    hilog.info(0x0000, TAG, 'startAbility error: %{public}s', JSON.stringify(err) ?? '')
  }
}
