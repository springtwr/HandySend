/**
 * WantAgentUtil.ets — 可点击回前台 WantAgent 共用构建工具
 *
 * 后台实况通知（BackgroundTransferService）与待确认提示通知（PendingRequestNotifier）
 * 的点击行为一致：拉起主 Ability 并置于前台，可附带一次性导航意图。此处收敛唯一的构建实现。
 */

import { common, wantAgent, WantAgent } from '@kit.AbilityKit';

/** 通知深链参数键：承载点击通知后应到达的导航目标。 */
export const NAVIGATION_PARAM_KEY: string = 'handysend.navigate';

/** 深链导航目标：任务中心列表。 */
export const NAV_TARGET_TRANSFER_CENTER: string = 'transferCenter';

/**
 * 构建点击通知回前台的 WantAgent（拉起主 Ability 并置前）。
 * @param navigationTarget 可选深链目标：非空时写入 Want 参数，供 EntryAbility 解析后置位导航信号；
 *   缺省（不传）时不携带任何参数，保持既有无参调用兼容。
 */
export function buildBackToFrontWantAgent(context: common.UIAbilityContext,
  navigationTarget?: string): Promise<WantAgent> {
  let parameters: Record<string, Object> = {};
  if (navigationTarget !== undefined) {
    parameters[NAVIGATION_PARAM_KEY] = navigationTarget;
  }
  let info: wantAgent.WantAgentInfo = {
    wants: [{
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name,
      parameters: parameters
    }],
    actionType: wantAgent.OperationType.START_ABILITY,
    requestCode: 0,
    wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
  };
  return wantAgent.getWantAgent(info);
}
