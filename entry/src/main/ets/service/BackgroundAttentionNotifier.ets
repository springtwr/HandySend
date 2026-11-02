/**
 * BackgroundAttentionNotifier.ets — 后台关注通知层
 *
 * 应用在后台时，把需要用户关注的待确认请求（LocalSend / MTA 接收、Web 上传）
 * 收敛为**一条**系统通知。网页访问与下载不进入该通知：访问只写诊断日志并续期
 * 有界后台保活，下载批次由后台传输实况通知承载。
 *
 * 通知使用独立 id（与后台传输实况通知区分），点击回到任务中心。
 * 模块级单例，由 EntryAbility 生命周期与注册表变更共同驱动。
 */

import { notificationManager } from '@kit.NotificationKit';
import { common, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { getAppContext, isAppForeground } from './repository/AppCore';
import {
  getPendingCount,
  subscribeSessions
} from './transfer/TransferSessionRegistry';
import { buildBackToFrontWantAgent, NAV_TARGET_TRANSFER_CENTER } from '../utils/WantAgentUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:BackgroundAttentionNotifier', '后台关注');

// 后台关注通知 id：与后台传输任务的实况通知区分，避免相互覆盖
const BACKGROUND_ATTENTION_NOTIFICATION_ID = 10001;

/** 后台关注类别。 */
export enum AttentionKind {
  none = 'none',
  pendingRequest = 'pendingRequest'
}
// 是否已发布（撤回幂等依据）与已发布时间
let published: boolean = false;
let publishedSignature: string = '';
// 撤回代际：publish 在途期间发生撤回时递增，publish 完成后比对以补回收
let withdrawGeneration: number = 0;
// 缓存的可点击回前台 WantAgent（进程级复用）
let attentionWantAgent: WantAgent | undefined = undefined;
// 注册表订阅状态
let subscribed: boolean = false;

/**
 * 关注类别决策（纯函数）：仅有待确认请求时发布通知，其余情况不发布。
 */
export function resolveAttentionKind(pendingCount: number): AttentionKind {
  return pendingCount > 0 ? AttentionKind.pendingRequest : AttentionKind.none;
}

function getString(resId: number): string {
  let ctx = getAppContext();
  if (ctx === undefined) {
    return '';
  }
  return ctx.resourceManager.getStringSync(resId);
}

// 获取（惰性创建并缓存）点击通知回前台的 WantAgent，构建细节收敛于共享工具
async function ensureWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
  let existing = attentionWantAgent;
  if (existing !== undefined) {
    return existing;
  }
  let agent = await buildBackToFrontWantAgent(context, NAV_TARGET_TRANSFER_CENTER);
  attentionWantAgent = agent;
  return agent;
}

function buildPendingText(count: number): string {
  let template: string = getString($r('app.string.background_attention_pending_text').id);
  return template.replace('%d', String(count));
}

function buildSignature(kind: AttentionKind, pendingCount: number): string {
  if (kind === AttentionKind.pendingRequest) {
    return 'pending:' + String(pendingCount);
  }
  return '';
}

/**
 * 发布/更新后台关注通知。权限未授予或发布失败时静默，
 * 事件本身仍保留在任务列表，回到前台可继续处理。
 */
async function publishAttention(kind: AttentionKind, pendingCount: number): Promise<void> {
  let context = getAppContext();
  if (context === undefined) {
    return;
  }
  let title: string;
  let text: string;
  if (kind === AttentionKind.pendingRequest) {
    title = getString($r('app.string.pending_request_notification_title').id);
    text = buildPendingText(pendingCount);
  } else {
    return;
  }
  let signature: string = buildSignature(kind, pendingCount);
  try {
    let agent = await ensureWantAgent(context);
    let request: notificationManager.NotificationRequest = {
      id: BACKGROUND_ATTENTION_NOTIFICATION_ID,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text
        }
      },
      wantAgent: agent
    };
    let genAtPublish: number = withdrawGeneration;
    await notificationManager.publish(request);
    if (genAtPublish !== withdrawGeneration) {
      // await 期间已发生撤回：立即回收刚发布的通知，避免残留
      notificationManager.cancel(BACKGROUND_ATTENTION_NOTIFICATION_ID)
        .catch((e: BusinessError): void => {
          logger.warn('撤回后台关注通知失败：' + e.code + ' ' + e.message);
        });
      return;
    }
    published = true;
    publishedSignature = signature;
    logger.debug('后台关注通知已发布 kind=' + kind);
  } catch (e) {
    logger.warn('发布后台关注通知失败：' + JSON.stringify(e));
  }
}

/**
 * 按当前后台状态同步关注通知（幂等）：
 * - 前台：撤回通知；
 * - 后台且有待确认请求：展示待确认数量；
 * - 其余：撤回。
 */
export function refreshBackgroundAttention(): void {
  if (isAppForeground()) {
    withdrawBackgroundAttention();
    return;
  }
  let pendingCount: number = getPendingCount();
  let kind: AttentionKind = resolveAttentionKind(pendingCount);
  if (kind === AttentionKind.none) {
    withdrawBackgroundAttention();
    return;
  }
  let signature: string = buildSignature(kind, pendingCount);
  if (published && signature === publishedSignature) {
    return;
  }
  publishAttention(kind, pendingCount).catch((e: Object): void => {
    logger.warn('发布后台关注通知失败：' + String(e));
  });
}

/**
 * 撤回后台关注通知（回到前台或待确认请求已全部处理时调用，幂等）。
 */
export function withdrawBackgroundAttention(): void {
  // 无论是否已发布均递增代际：拦截「撤回先于 publish 完成」的在途发布
  withdrawGeneration++;
  if (!published) {
    return;
  }
  published = false;
  publishedSignature = '';
  notificationManager.cancel(BACKGROUND_ATTENTION_NOTIFICATION_ID).then(() => {
    logger.debug('后台关注通知已撤回');
  }).catch((e: BusinessError) => {
    logger.warn('撤回后台关注通知失败：' + e.code + ' ' + e.message);
  });
}

/** 初始化：订阅注册表变化，按后台关注事件发布/撤回通知（进程级幂等）。 */
export function initBackgroundAttentionNotifier(): void {
  if (subscribed) {
    return;
  }
  subscribed = true;
  subscribeSessions(refreshBackgroundAttention);
  logger.debug('后台关注通知已订阅注册表');
}
