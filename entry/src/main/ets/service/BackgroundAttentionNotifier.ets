/**
 * BackgroundAttentionNotifier.ets — 后台关注通知层
 *
 * 应用在后台时，把需要用户关注的事件收敛为**一条**系统通知：
 * - 待确认请求：LocalSend / MTA 接收、Web 上传；
 * - 网页访问：已由扫码或本次访问码直接放行、或本次免确认放行的 Web 下载。
 *
 * 待确认请求优先展示；没有待确认时展示最近一次仍存活的网页访问。
 * 通知使用独立 id（与后台传输实况通知区分），点击回到任务中心。
 * 模块级单例，由 EntryAbility 生命周期与注册表变更共同驱动。
 */

import { notificationManager } from '@kit.NotificationKit';
import { common, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { getAppContext, isAppForeground } from './repository/AppCore';
import {
  getPendingCount,
  getSession,
  subscribeSessions
} from './transfer/TransferSessionRegistry';
import { isTerminalStage } from '../model/transfer/TransferSession';
import { buildBackToFrontWantAgent, NAV_TARGET_TRANSFER_CENTER } from '../utils/WantAgentUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:BackgroundAttentionNotifier', '后台关注');

// 后台关注通知 id：与后台传输任务的实况通知区分，避免相互覆盖
const BACKGROUND_ATTENTION_NOTIFICATION_ID = 10001;

/** 后台关注类别（待确认请求优先于网页访问）。 */
export enum AttentionKind {
  none = 'none',
  pendingRequest = 'pendingRequest',
  webAccess = 'webAccess'
}

/** 已放行的网页访问（会话仍存活时展示）。 */
interface WebAccessAttention {
  sessionId: string
  ip: string
  fileCount: number
}

let webAccess: WebAccessAttention | undefined = undefined;
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
 * 关注类别决策（纯函数）：待确认请求优先，其次是没有待确认时的网页访问。
 */
export function resolveAttentionKind(pendingCount: number, hasWebAccess: boolean): AttentionKind {
  if (pendingCount > 0) {
    return AttentionKind.pendingRequest;
  }
  return hasWebAccess ? AttentionKind.webAccess : AttentionKind.none;
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

/** 网页访问会话是否仍存活（页面关闭/任务结束后不再展示访问提示）。 */
function webAccessAlive(): boolean {
  if (webAccess === undefined) {
    return false;
  }
  let session = getSession(webAccess.sessionId);
  return session !== undefined && !isTerminalStage(session.stage);
}

function buildPendingText(count: number): string {
  let template: string = getString($r('app.string.background_attention_pending_text').id);
  return template.replace('%d', String(count));
}

function buildWebAccessText(access: WebAccessAttention): string {
  let template: string = getString($r('app.string.background_attention_web_access_text').id);
  return template.replace('%s', access.ip).replace('%d', String(access.fileCount));
}

function buildSignature(kind: AttentionKind, pendingCount: number): string {
  if (kind === AttentionKind.pendingRequest) {
    return 'pending:' + String(pendingCount);
  }
  if (kind === AttentionKind.webAccess && webAccess !== undefined) {
    return 'web:' + webAccess.sessionId + ':' + String(webAccess.fileCount);
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
  } else if (kind === AttentionKind.webAccess && webAccess !== undefined) {
    title = getString($r('app.string.web_access_notice_title').id);
    text = buildWebAccessText(webAccess);
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
 * - 前台：撤回并清空网页访问关注；
 * - 后台且有待确认请求：展示待确认（优先）；
 * - 后台且无待确认、但有存活网页访问：展示网页访问；
 * - 其余：撤回。
 */
export function refreshBackgroundAttention(): void {
  if (isAppForeground()) {
    withdrawBackgroundAttention();
    return;
  }
  let pendingCount: number = getPendingCount();
  let kind: AttentionKind = resolveAttentionKind(pendingCount, webAccessAlive());
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
 * 记录一次已放行的网页访问（扫码/访问码或本次免确认）。
 * 前台不发布通知（应用内提示已覆盖）；后台立即进入关注通知层。
 */
export function notifyWebAccessAttention(sessionId: string, ip: string, fileCount: number): void {
  if (sessionId.length === 0 || isAppForeground()) {
    return;
  }
  if (webAccess !== undefined && webAccess.sessionId === sessionId) {
    return;
  }
  webAccess = {
    sessionId: sessionId,
    ip: ip,
    fileCount: fileCount
  };
  refreshBackgroundAttention();
}

/**
 * 撤回后台关注通知并清空网页访问关注（回到前台或事件已全部处理时调用，幂等）。
 */
export function withdrawBackgroundAttention(): void {
  // 无论是否已发布均递增代际：拦截「撤回先于 publish 完成」的在途发布
  withdrawGeneration++;
  webAccess = undefined;
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
