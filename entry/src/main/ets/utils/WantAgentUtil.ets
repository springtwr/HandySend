/**
 * WantAgentUtil.ets — 可点击回前台 WantAgent 共用构建工具
 *
 * 后台实况通知（BackgroundTransferService）与待确认提示通知（PendingRequestNotifier）
 * 的点击行为一致：拉起主 Ability 并置于前台。此处收敛唯一的构建实现。
 */

import { common, wantAgent, WantAgent } from '@kit.AbilityKit';

/** 构建点击通知回前台的 WantAgent（拉起主 Ability 并置前）。 */
export function buildBackToFrontWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
  let info: wantAgent.WantAgentInfo = {
    wants: [{
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name
    }],
    actionType: wantAgent.OperationType.START_ABILITY,
    requestCode: 0,
    wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
  };
  return wantAgent.getWantAgent(info);
}
