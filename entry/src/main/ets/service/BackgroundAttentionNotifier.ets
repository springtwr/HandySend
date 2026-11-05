/**
 * BackgroundAttentionNotifier.ets — 后台关注通知层
 *
 * 应用退到后台或 PC 主窗口最小化时，把需要用户关注的待确认请求
 * （LocalSend / MTA 接收、Web 上传）收敛为**一条**系统通知，并在 PC/2in1 上同步应用角标。
 * 网页访问与下载不进入该通知：访问只写诊断日志并续期有界后台保活，
 * 下载批次由后台传输实况通知承载。
 *
 * 通知使用独立 id（与后台传输实况通知区分）：单条待确认点击直达该请求详情，
 * 多条待确认点击回到任务中心。模块级单例，由 EntryAbility 生命周期与注册表变更共同驱动。
 */

import { notificationManager } from '@kit.NotificationKit';
import { common, WantAgent } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { getAppContext, isAppForeground } from './repository/AppCore';
import { isNotificationPermissionGranted } from './PermissionService';
import {
  getPendingSessionIds,
  subscribeSessions
} from './transfer/TransferSessionRegistry';
import {
  buildBackToFrontWantAgent,
  NAV_TARGET_SESSION_DETAIL,
  NAV_TARGET_TRANSFER_CENTER
} from '../utils/WantAgentUtil';
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
// 撤回代际：撤回使在途发布失效，发布完成后比对以补回收
let withdrawGeneration: number = 0;
// 同步串行链与排队标记：连续变化只保留一次排队，轮到本次时按最新注册表状态重算，
// 避免旧状态（数量 / 点击目标）的发布晚于新状态完成而覆盖通知
let attentionSyncChain: Promise<void> = Promise.resolve();
let attentionSyncQueued: boolean = false;
// 撤回取消动作的串行链尾：发布前等待其完成，避免迟到的取消误删刚发布的新通知
let lastWithdrawCancel: Promise<void> = Promise.resolve();
// 缓存的可点击回前台 WantAgent（进程级复用；目标或会话标识变化时重建）
let attentionWantAgent: WantAgent | undefined = undefined;
let attentionWantAgentKey: string = '';
// 注册表订阅状态
let subscribed: boolean = false;
// PC 主窗口是否最小化：最小化与 UIAbility 前后台切换不是同一口径，
// 部分机型最小化时 onBackground 未触发，需单独据此决定是否发布通知与角标
let desktopWindowMinimized: boolean = false;
// 角标设置串行链与最近一次已请求的角标数：避免异步设置乱序与重复调用
let badgeChain: Promise<void> = Promise.resolve();
let requestedBadgeNumber: number = -1;

/**
 * 关注类别决策（纯函数）：仅有待确认请求时发布通知，其余情况不发布。
 */
export function resolveAttentionKind(pendingCount: number): AttentionKind {
  return pendingCount > 0 ? AttentionKind.pendingRequest : AttentionKind.none;
}

/**
 * 是否需要以系统通知/角标提醒用户（纯函数）：
 * 应用退到后台，或 PC 主窗口最小化时为真；最小化不能只按 onBackground 判断。
 */
export function shouldPublishAttention(appForeground: boolean, windowMinimized: boolean): boolean {
  return !appForeground || windowMinimized;
}

/**
 * 同步 PC 主窗口最小化状态：窗口状态变化时由 EntryAbility 调用。
 * 最小化与恢复都会触发一次关注通知重算，保证已有待确认请求能补发/撤回。
 */
export function setDesktopWindowMinimized(minimized: boolean): void {
  if (deviceInfo.deviceType !== '2in1') {
    return;
  }
  if (desktopWindowMinimized === minimized) {
    return;
  }
  desktopWindowMinimized = minimized;
  logger.debug('PC 主窗口最小化状态变化：' + String(minimized));
  refreshBackgroundAttention();
}

/** PC 主窗口是否最小化：供页面判断是否适合弹应用内新传输提示。 */
export function isDesktopWindowMinimized(): boolean {
  return desktopWindowMinimized;
}

/**
 * 设置应用角标（仅 PC/2in1）：数量与后台关注通知保持一致（均为待确认数），
 * 通知撤回或待确认请求清零时清空角标；手机/平板只保留后台通知，不设置系统角标。
 */
function syncBadge(count: number): void {
  if (deviceInfo.deviceType !== '2in1') {
    return;
  }
  let target: number = count > 0 ? count : 0;
  if (target === requestedBadgeNumber) {
    return;
  }
  if (!isNotificationPermissionGranted()) {
    // 未授权时不记录目标值：用户后续在设置中开启通知后，下一次同步仍能补设
    requestedBadgeNumber = -1;
    return;
  }
  requestedBadgeNumber = target;
  badgeChain = badgeChain.then(async (): Promise<void> => {
    try {
      await notificationManager.setBadgeNumber(target);
      logger.debug('应用角标已设置：' + String(target));
    } catch (e) {
      // 设置失败时复位目标值，下一次待确认变化或回到前台时仍可重试
      requestedBadgeNumber = -1;
      logger.warn('设置应用角标失败：' + JSON.stringify(e));
    }
  });
}

function getString(resId: number): string {
  let ctx = getAppContext();
  if (ctx === undefined) {
    return '';
  }
  return ctx.resourceManager.getStringSync(resId);
}

// 获取（惰性创建并缓存）点击通知回前台的 WantAgent，构建细节收敛于共享工具；
// 目标（任务中心 / 单条待确认详情）或会话标识变化时重建缓存
async function ensureWantAgent(context: common.UIAbilityContext, target: string,
  sessionId: string): Promise<WantAgent> {
  let key: string = target + '|' + sessionId;
  let existing = attentionWantAgent;
  if (existing !== undefined && attentionWantAgentKey === key) {
    return existing;
  }
  let agent = await buildBackToFrontWantAgent(context, target, sessionId);
  attentionWantAgent = agent;
  attentionWantAgentKey = key;
  return agent;
}

function buildPendingText(count: number): string {
  let template: string = getString($r('app.string.background_attention_pending_text').id);
  return template.replace('%d', String(count));
}

/** 单条待确认时的目标会话标识；多条或数量异常时为空串（回任务中心）。 */
function singleSessionId(sessionIds: Array<string>): string {
  return sessionIds.length === 1 ? sessionIds[0] : '';
}

function buildSignature(kind: AttentionKind, sessionIds: Array<string>): string {
  if (kind === AttentionKind.pendingRequest) {
    // 数量与单条时的会话标识都参与判重：数量不变但换成另一条请求时也要重发，
    // 否则通知的点击目标仍指向已被处理掉的旧请求
    return 'pending:' + String(sessionIds.length) + ':' + singleSessionId(sessionIds);
  }
  return '';
}

/** 将取消通知动作排入串行链（同一通知 id 的取消不并发），返回链尾供发布前等待。 */
function enqueueAttentionCancel(): Promise<void> {
  lastWithdrawCancel = lastWithdrawCancel.then((): Promise<void> => {
    return notificationManager.cancel(BACKGROUND_ATTENTION_NOTIFICATION_ID).then((): void => {
      logger.debug('后台关注通知已撤回');
    }).catch((e: BusinessError): void => {
      logger.warn('撤回后台关注通知失败：' + e.code + ' ' + e.message);
    });
  });
  return lastWithdrawCancel;
}

/**
 * 发布/更新后台关注通知。权限未授予或发布失败时静默，
 * 事件本身仍保留在任务列表，回到前台可继续处理。
 * @param signature 本次内容签名：发布成功后记为已发布状态，供后续变更判重
 */
async function publishAttention(kind: AttentionKind, sessionIds: Array<string>,
  signature: string): Promise<void> {
  let context = getAppContext();
  if (context === undefined) {
    return;
  }
  let title: string;
  let text: string;
  if (kind === AttentionKind.pendingRequest) {
    title = getString($r('app.string.pending_request_notification_title').id);
    text = buildPendingText(sessionIds.length);
  } else {
    return;
  }
  try {
    // 单条直达该请求详情（进页即可接受/拒绝）；多条合并后不替用户挑其中一条
    let genAtPublish: number = withdrawGeneration;
    let target: string = sessionIds.length === 1 ? NAV_TARGET_SESSION_DETAIL : NAV_TARGET_TRANSFER_CENTER;
    let agent = await ensureWantAgent(context, target, singleSessionId(sessionIds));
    if (genAtPublish !== withdrawGeneration ||
      !shouldPublishAttention(isAppForeground(), desktopWindowMinimized)) {
      // 构建点击目标期间已撤回，或应用已回到前台/窗口已恢复：不再发布
      return;
    }
    // 等待仍在途的撤回取消完成：避免其迟到后删掉本次发布
    await lastWithdrawCancel;
    if (genAtPublish !== withdrawGeneration ||
      !shouldPublishAttention(isAppForeground(), desktopWindowMinimized)) {
      return;
    }
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
    await notificationManager.publish(request);
    if (genAtPublish !== withdrawGeneration) {
      // await 期间已发生撤回：排入取消链，避免与后续发布交错（迟到取消会误删新通知）
      enqueueAttentionCancel();
      return;
    }
    published = true;
    publishedSignature = signature;
    // 角标与通知同源：仅在有未处理待确认请求时显示数量
    syncBadge(sessionIds.length);
    logger.debug('后台关注通知已发布 kind=' + kind);
  } catch (e) {
    logger.warn('发布后台关注通知失败：' + JSON.stringify(e));
  }
}

/**
 * 按当前注册表状态同步关注通知（串行执行，状态在轮到本次时重新读取）：
 * - 前台：撤回通知；
 * - 后台/最小化且有待确认请求：单条直达详情，多条展示数量并回任务中心；
 * - 其余：撤回。
 */
async function applyAttentionState(): Promise<void> {
  if (!shouldPublishAttention(isAppForeground(), desktopWindowMinimized)) {
    withdrawBackgroundAttention();
    return;
  }
  let pendingIds: Array<string> = getPendingSessionIds();
  let kind: AttentionKind = resolveAttentionKind(pendingIds.length);
  if (kind === AttentionKind.none) {
    withdrawBackgroundAttention();
    return;
  }
  let signature: string = buildSignature(kind, pendingIds);
  if (published && signature === publishedSignature) {
    return;
  }
  await publishAttention(kind, pendingIds, signature);
}

/**
 * 请求同步后台关注通知：连续变化合并为一次排队，轮到本次时按最新注册表状态重算，
 * 避免较早的发布晚于较新状态完成而覆盖通知内容与点击目标。
 */
export function refreshBackgroundAttention(): void {
  if (attentionSyncQueued) {
    return;
  }
  attentionSyncQueued = true;
  attentionSyncChain = attentionSyncChain.then((): Promise<void> => {
    attentionSyncQueued = false;
    return applyAttentionState();
  }).catch((e: Object): void => {
    logger.warn('同步后台关注通知失败：' + String(e));
  });
}

/**
 * 撤回后台关注通知（回到前台或待确认请求已全部处理时调用，幂等）。
 */
export function withdrawBackgroundAttention(): void {
  // 无论是否已发布均递增代际：拦截「撤回先于 publish 完成」的在途发布
  withdrawGeneration++;
  // 回到前台或待确认请求清零时同步清空角标；即使通知未发布也要清
  syncBadge(0);
  if (!published) {
    return;
  }
  published = false;
  publishedSignature = '';
  enqueueAttentionCancel();
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
