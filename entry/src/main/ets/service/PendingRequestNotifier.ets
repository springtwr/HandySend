/**
 * PendingRequestNotifier.ets — 后台待确认请求提示通知
 *
 * 应用处于后台时到达"需用户手动确认"的接收/下载请求（LocalSend 接收、
 * Web 分享下载）时，发布一条可点击回到前台的系统通知，提示用户存在待确认的
 * 传入传输；请求本身仍保留在既有待确认列表中，用户回到前台后正常处理。
 *
 * 通知使用独立 id（与后台传输实况通知区分），避免相互覆盖或错配。
 * 模块级单例组织方式与 BackgroundTransferService 一致。
 */

import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { getAppContext } from './repository/AppCore';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:PendingRequestNotifier', '待确认提示');

// 待确认请求提示通知 id：与后台传输任务的实况通知区分，避免相互覆盖
const PENDING_REQUEST_NOTIFICATION_ID = 10001;

// 是否已发布（撤回幂等依据）
let published: boolean = false;
// 缓存的可点击回前台 WantAgent（进程级复用）
let pendingWantAgent: WantAgent | undefined = undefined;

function getString(resId: number): string {
  let ctx = getAppContext();
  if (ctx === undefined) {
    return '';
  }
  return ctx.resourceManager.getStringSync(resId);
}

// 获取（惰性创建）点击通知回前台的 WantAgent
async function ensureWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
  let existing = pendingWantAgent;
  if (existing !== undefined) {
    return existing;
  }
  let info: wantAgent.WantAgentInfo = {
    wants: [{
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name
    }],
    actionType: wantAgent.OperationType.START_ABILITY,
    requestCode: 0,
    wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
  };
  let agent = await wantAgent.getWantAgent(info);
  pendingWantAgent = agent;
  return agent;
}

/**
 * 发布后台待确认请求提示通知（可点击回到前台）。已发布时幂等。
 * 通知权限未授予/发布失败时静默处理，不影响请求保留在待确认列表。
 */
export async function publishPendingRequestNotification(): Promise<void> {
  let context = getAppContext();
  if (context === undefined) {
    return;
  }
  try {
    let agent = await ensureWantAgent(context);
    let request: notificationManager.NotificationRequest = {
      id: PENDING_REQUEST_NOTIFICATION_ID,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: getString($r('app.string.pending_request_notification_title').id),
          text: getString($r('app.string.pending_request_notification_text').id)
        }
      },
      wantAgent: agent
    };
    await notificationManager.publish(request);
    published = true;
    logger.info('pending request notification published');
  } catch (e) {
    logger.warn('publish pending request notification failed: ' + JSON.stringify(e));
  }
}

/** 撤回后台待确认请求提示通知（应用回到前台或请求已处理时调用，幂等） */
export function withdrawPendingRequestNotification(): void {
  if (!published) {
    return;
  }
  published = false;
  notificationManager.cancel(PENDING_REQUEST_NOTIFICATION_ID).then(() => {
    logger.info('pending request notification withdrawn');
  }).catch((e: BusinessError) => {
    logger.warn('withdraw pending request notification failed: ' + e.code + ' ' + e.message);
  });
}
