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
import { common, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { getAppContext, isAppForeground } from './repository/AppCore';
import { getPendingCount, subscribeSessions } from './transfer/TransferSessionRegistry';
import { buildBackToFrontWantAgent, NAV_TARGET_TRANSFER_CENTER } from '../utils/WantAgentUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:PendingRequestNotifier', '待确认提示');

// 待确认请求提示通知 id：与后台传输任务的实况通知区分，避免相互覆盖
const PENDING_REQUEST_NOTIFICATION_ID = 10001;

// 是否已发布（撤回幂等依据）
let published: boolean = false;
// 撤回代际：publish 在途期间发生撤回时递增，publish 完成后比对以补回收，
// 避免通知在「发布完成晚于撤回」时滞留
let withdrawGeneration: number = 0;
// 缓存的可点击回前台 WantAgent（进程级复用）
let pendingWantAgent: WantAgent | undefined = undefined;
// 注册表订阅状态
let subscribed: boolean = false;

function getString(resId: number): string {
  let ctx = getAppContext();
  if (ctx === undefined) {
    return '';
  }
  return ctx.resourceManager.getStringSync(resId);
}

// 获取（惰性创建并缓存）点击通知回前台的 WantAgent，构建细节收敛于共享工具
async function ensureWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
  let existing = pendingWantAgent;
  if (existing !== undefined) {
    return existing;
  }
  let agent = await buildBackToFrontWantAgent(context, NAV_TARGET_TRANSFER_CENTER);
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
    let genAtPublish = withdrawGeneration;
    await notificationManager.publish(request);
    if (genAtPublish !== withdrawGeneration) {
      // await 期间已发生撤回：立即回收刚发布的通知，避免残留
      notificationManager.cancel(PENDING_REQUEST_NOTIFICATION_ID).catch((e: BusinessError): void => {
        logger.warn('withdraw pending request notification failed: ' + e.code + ' ' + e.message);
      });
      return;
    }
    published = true;
    logger.info('pending request notification published');
  } catch (e) {
    logger.warn('publish pending request notification failed: ' + JSON.stringify(e));
  }
}

/** 撤回后台待确认请求提示通知（应用回到前台或请求已处理时调用，幂等） */
export function withdrawPendingRequestNotification(): void {
  // 无论是否已发布均递增代际：拦截「撤回先于 publish 完成」的在途发布
  withdrawGeneration++;
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

/**
 * 按统一注册表同步待确认提示通知（前台订阅协议事件的发布/撤回由本函数收口）：
 * - 后台且存在待确认会话 → 发布/保持提示；
 * - 无待确认会话或已回到前台 → 撤回提示。
 */
function syncByRegistry(): void {
  if (getPendingCount() > 0 && !isAppForeground()) {
    publishPendingRequestNotification().catch((e: Object): void => {
      logger.warn('publish pending request notification failed: ' + String(e));
    });
  } else {
    withdrawPendingRequestNotification();
  }
}

/** 初始化：订阅注册表变化，按待确认会话发布/撤回提示通知（进程级幂等）。 */
export function initPendingRequestNotifier(): void {
  if (subscribed) {
    return;
  }
  subscribed = true;
  subscribeSessions(syncByRegistry);
  logger.debug('pending request notifier subscribed to registry');
}

