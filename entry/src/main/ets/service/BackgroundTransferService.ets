/**
 * BackgroundTransferService.ets — 后台长时任务与通知服务
 *
 * 编排两条独立的 dataTransfer 长时任务与系统实况通知（downloadTemplate）：
 * - 传输任务：后台存在活跃传输时申请，1s 节流发布进度；终态发布普通通知后立即停止；
 * - 保活任务：允许后台接收且网页/LocalSend 服务运行时，退后台固定 5 分钟，
 *   每 30 秒推进进度，到期静默停止（不发布 100%）；
 * - onForeground → 停止两条任务并撤销终态通知；
 * - 用户删除通知（continuousTaskCancel USER_CANCEL）→ 只影响对应任务；
 *   删除传输任务通知时取消活跃传输。
 *
 * 数据源：统一会话注册表的协议无关聚合快照（TransferSessionRegistry.getOverallSnapshot）。
 * 模块级单例组织方式与 MtaRepository 一致。
 */

import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, WantAgent } from '@kit.AbilityKit';
import { getAppContext, subscribe, isAppForeground, setAppForeground } from './repository/AppCore';
import { getWebActualPort } from './repository/WebShareRepository';
import { isServerRunning } from './repository/ServerRepository';
import { isBackgroundReceiveEnabled } from './repository/SettingsRepository';
import {
  cancel as cancelSession,
  getAllSessions,
  getSession,
  getOverallSnapshot
} from './transfer/TransferSessionRegistry';
import {
  OverallSnapshot,
  SessionStage,
  TransferSession,
  isSuccessStage,
  isTerminalStage
} from '../model/transfer/TransferSession';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import {
  buildBackToFrontWantAgent,
  NAV_TARGET_SESSION_DETAIL,
  NAV_TARGET_TRANSFER_CENTER
} from '../utils/WantAgentUtil';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:BackgroundTransferService', '后台传输');

// 进度通知发布节流间隔（毫秒）
const PUBLISH_INTERVAL_MS = 1000;
// 空闲保活时长（毫秒）：网页服务或 LocalSend 服务器运行且无传输时保留 5 分钟
const WEB_KEEPALIVE_MS = 5 * 60 * 1000;
// 保活心跳间隔（毫秒）：每 30 秒更新一次进度；5 分钟后发 100% 并立即结束
const WEB_KEEPALIVE_HEARTBEAT_MS = 30 * 1000;
// 终态普通通知 id（与后台关注通知 10001、长时任务通知 id 区分）
const TERMINAL_NOTICE_ID = 10002;
const TERMINAL_NOTICE_FALLBACK_ID = 10003;
// 实况通知 typeCode：数据传输（dataTransfer）类型固定为 8（官方约定）
const LIVE_VIEW_TYPE_CODE = 8;

// ── 状态机 ──

// idle：无任务；starting：申请中（异步未决）；running：任务生效中
export enum TransferTaskState {
  idle = 'idle',
  starting = 'starting',
  running = 'running'
}

// 终态通知文案类别
export enum TransferTerminalKind {
  success = 'success',
  partial = 'partial',
  failed = 'failed'
}

// 两条独立长时任务：传输任务与空闲保活任务
export enum LongTaskKind {
  transfer = 'transfer',
  keepalive = 'keepalive'
}

// ── 模块状态 ──

// 传输长时任务
let state: TransferTaskState = TransferTaskState.idle;
// 申请代次：stop/新 start 使旧代次的异步回调失效（防启停竞态）
let startGeneration: number = 0;
// 长时任务返回的通知 Id 与任务 Id（进度更新必须复用通知 Id）
let notificationId: number = -1;
let continuousTaskId: number = -1;
// 通知发布串行链：停止任务前等待在途发布结束，避免 publish 与 cancel 竞态
let notificationPublishChain: Promise<void> = Promise.resolve();
// 申请时使用的上下文（停止时复用）
let taskContext: common.UIAbilityContext | undefined = undefined;
// 缓存的 UIAbilityContext：申请时记录（缺省回退 AppCore 既有上下文），
// 供 changeBus 在后台任务空闲时主动申请（后台自发开始的新传输）
let cachedContext: common.UIAbilityContext | undefined = undefined;
// 上次进度发布时间（节流基准；<0 表示任务周期内尚未发布过）
let lastPublishMs: number = -1;
// 上次已发布的进度值（传入聚合函数做单调防回跳）
let lastPublishedPercent: number = 0;
let pendingTimer: number = -1;
// 终态停止代次：新传输出现时使在途的终态停止失效
let terminalStopGeneration: number = 0;
// 空闲保活截止时刻、窗口起点（0 表示无）与停止定时器
let webKeepaliveUntil: number = 0;
let webKeepaliveStartMs: number = 0;
let webKeepaliveTimer: number = -1;
// 保活心跳定时器（-1 表示未运行）
let webKeepaliveHeartbeatTimer: number = -1;
// 保活结束流程是否已开始（防止心跳与到期定时器重复结束）
let webKeepaliveFinishing: boolean = false;
// 保活长时任务自身状态
let keepaliveState: TransferTaskState = TransferTaskState.idle;
let keepaliveStartGeneration: number = 0;
let keepaliveNotificationId: number = -1;
let keepaliveContinuousTaskId: number = -1;
let keepaliveContext: common.UIAbilityContext | undefined = undefined;
// 本任务周期内已发布终态
let terminalPublished: boolean = false;
// 应用是否前台由 AppCore 统一提供（EntryAbility 生命周期驱动，见 repository/AppCore）
// 通知授权引导是否已发起（进程级一次）
let authPrompted: boolean = false;
// 通知授权检查节流（前台每次数据变化都检查代价高，限频）
let lastAuthCheckMs: number = -1;
// 进程级初始化标志（changeBus 订阅 + 长时任务取消监听）
let inited: boolean = false;

// ── 纯决策函数（可单测） ──

/**
 * 进度发布节流决策：返回需要延迟的毫秒数，0 表示应立即发布。
 * lastPublishMs < 0 表示任务周期内尚未发布（首帧立即发）。
 */
export function throttleDelayMs(nowMs: number, lastPublishMs: number, intervalMs: number): number {
  if (lastPublishMs < 0) {
    return 0;
  }
  let elapsed: number = nowMs - lastPublishMs;
  if (elapsed >= intervalMs) {
    return 0;
  }
  return intervalMs - elapsed;
}

/**
 * 终态文案决策：无失败 → success；全部失败 → failed；部分失败 → partial。
 * allFailed 为 false 且 hasFailure 为 true 时表示混合终态。
 */
export function resolveTerminalKind(hasFailure: boolean, allFailed: boolean): TransferTerminalKind {
  if (!hasFailure) {
    return TransferTerminalKind.success;
  }
  return allFailed ? TransferTerminalKind.failed : TransferTerminalKind.partial;
}

// ── 数据聚合（协议无关：唯一来源为统一会话注册表） ──

/** 当前整体传输快照（协议无关聚合，供长时任务申请与通知渲染）。 */
function currentOverall(prevPercent: number): OverallSnapshot {
  return getOverallSnapshot(prevPercent);
}

/** 是否存在活跃会话。 */
export function hasActiveSessions(): boolean {
  return currentOverall(0).active;
}

/** 当前是否有可接收的后台服务（网页传输或 LocalSend 服务器）。 */
function backgroundServiceRunning(): boolean {
  return getWebActualPort() > 0 || isServerRunning();
}

/**
 * 网页访问只补启动尚未启动的保活任务，不延长固定 5 分钟窗口；不创建统一会话。
 * 调用方为 AppService 的 webAccess 事件路由。
 */
export function noteWebAccess(): void {
  if (!isBackgroundReceiveEnabled() || !backgroundServiceRunning()) {
    return;
  }
  if (keepaliveState === TransferTaskState.idle && webKeepaliveUntil > Date.now()) {
    startKeepaliveTaskInternal();
  }
}

function cancelWebKeepaliveTimer(): void {
  if (webKeepaliveTimer >= 0) {
    clearTimeout(webKeepaliveTimer);
    webKeepaliveTimer = -1;
  }
}

/** 停止保活心跳（保活任务停止或保活失效时调用）。 */
function stopWebKeepaliveHeartbeat(): void {
  if (webKeepaliveHeartbeatTimer >= 0) {
    clearInterval(webKeepaliveHeartbeatTimer);
    webKeepaliveHeartbeatTimer = -1;
  }
}

/** 当前保活窗口的时间进度（0-100，按 5 分钟线性映射）。 */
function webKeepalivePercent(nowMs: number): number {
  if (webKeepaliveStartMs <= 0) {
    return 0;
  }
  let percent: number = Math.floor((nowMs - webKeepaliveStartMs) * 100 / WEB_KEEPALIVE_MS);
  if (percent < 0) {
    return 0;
  }
  return percent > 100 ? 100 : percent;
}

/**
 * 结束保活：先发布 100% 结束帧，随即停止保活长时任务，通知随任务取消消失。
 * 与传输任务一致：发完 100% 立即结束通知不会触发系统完成提醒。
 */
function finishWebKeepalive(): void {
  if (webKeepaliveFinishing) {
    return;
  }
  if (webKeepaliveStartMs <= 0) {
    if (keepaliveState !== TransferTaskState.idle) {
      stopKeepaliveTaskInternal();
    }
    return;
  }
  // 已被新窗口接手：不结束新窗口
  if (webKeepaliveUntil > Date.now()) {
    return;
  }
  webKeepaliveFinishing = true;
  stopWebKeepaliveHeartbeat();
  cancelWebKeepaliveTimer();
  webKeepaliveUntil = 0;
  // 停止放在发布完成之后：发布链中的帧会按代次失效，先停会丢掉这帧 100%
  let gen: number = keepaliveStartGeneration;
  let stopKeepalive = (): void => {
    // 期间已被新窗口接手（回前台后再次进入后台）：不停止新任务
    if (gen !== keepaliveStartGeneration) {
      return;
    }
    stopKeepaliveTaskInternal();
  };
  publishFrame(LongTaskKind.keepalive, getString($r('app.string.bg_transfer_title_keepalive').id),
    getString($r('app.string.bg_transfer_content_keepalive').id), 100).then(stopKeepalive, stopKeepalive);
}

/**
 * 启动保活心跳：每 30 秒更新一次进度；到期发布 100% 后立即停止保活任务。
 */
function startWebKeepaliveHeartbeat(): void {
  if (webKeepaliveHeartbeatTimer >= 0) {
    return;
  }
  webKeepaliveHeartbeatTimer = setInterval(() => {
    if (keepaliveState !== TransferTaskState.running || !backgroundServiceRunning()) {
      stopWebKeepaliveHeartbeat();
      return;
    }
    let now: number = Date.now();
    if (now - webKeepaliveStartMs >= WEB_KEEPALIVE_MS) {
      finishWebKeepalive();
      return;
    }
    let percent: number = webKeepalivePercent(now);
    logger.debug('保活心跳：progress=' + percent);
    publishFrame(LongTaskKind.keepalive, getString($r('app.string.bg_transfer_title_keepalive').id),
      getString($r('app.string.bg_transfer_content_keepalive').id), percent);
  }, WEB_KEEPALIVE_HEARTBEAT_MS);
}

/** 复位保活计时与任务状态（不主动停止系统任务）。 */
function resetKeepaliveState(): void {
  cancelWebKeepaliveTimer();
  stopWebKeepaliveHeartbeat();
  webKeepaliveUntil = 0;
  webKeepaliveStartMs = 0;
  webKeepaliveFinishing = false;
  keepaliveState = TransferTaskState.idle;
  keepaliveNotificationId = -1;
  keepaliveContinuousTaskId = -1;
  keepaliveContext = undefined;
}

/** 停止保活长时任务（回前台、用户删除保活通知、到期结束）。 */
function stopKeepaliveTaskInternal(): void {
  keepaliveStartGeneration++;
  let context = keepaliveContext;
  let taskId = keepaliveContinuousTaskId;
  resetKeepaliveState();
  if (context !== undefined) {
    logger.debug('停止保活长时任务 taskId=' + taskId);
    stopLongTask(context, taskId);
  }
}

/** 全部输入是否已终态且全部失败（终态文案判定用）。
 * 只统计本轮后台周期关注的会话：注册表中的历史终态会话（如既往失败）
 * 不参与判定，避免污染本轮「全部成功/部分失败」的文案。 */
function allTerminalFailed(): boolean {
  let hasTerminal: boolean = false;
  let allFailed: boolean = true;
  for (let i = 0; i < cycleSessionIds.length; i++) {
    let session = getSession(cycleSessionIds[i]);
    if (session !== undefined && isTerminalStage(session.stage)) {
      hasTerminal = true;
      if (session.stage === SessionStage.succeeded ||
        session.stage === SessionStage.partiallyFailed) {
        allFailed = false;
      }
    }
  }
  return hasTerminal && allFailed;
}

// 本轮后台周期关注的会话 id：进入后台后新增或当时仍在进行的会话。
// 终态文案判定（hasFailure/allTerminalFailed）只看本轮集合
let cycleSessionIds: Array<string> = [];

/** 把当前所有非终态会话纳入本轮关注集合（新会话出现即纳入，幂等）。 */
function trackCycleSessions(): void {
  let sessions: Array<TransferSession> = getAllSessions();
  for (let i = 0; i < sessions.length; i++) {
    if (!isTerminalStage(sessions[i].stage) && cycleSessionIds.indexOf(sessions[i].id) < 0) {
      cycleSessionIds.push(sessions[i].id);
    }
  }
}

/** 本轮关注会话中是否存在失败类终态（终态文案判定用，不受历史会话污染）。 */
function cycleHasFailure(): boolean {
  for (let i = 0; i < cycleSessionIds.length; i++) {
    let session = getSession(cycleSessionIds[i]);
    if (session !== undefined && isTerminalStage(session.stage) && !isSuccessStage(session.stage)) {
      return true;
    }
  }
  return false;
}

// ── 通知发布 ──

function getString(resId: number, ...args: number[]): string {
  let ctx = getAppContext();
  if (ctx === undefined) {
    return '';
  }
  return ctx.resourceManager.getStringSync(resId, ...args);
}

function taskNotificationId(kind: LongTaskKind): number {
  return kind === LongTaskKind.transfer ? notificationId : keepaliveNotificationId;
}

function taskGeneration(kind: LongTaskKind): number {
  return kind === LongTaskKind.transfer ? startGeneration : keepaliveStartGeneration;
}

// 以指定长时任务的通知 Id 发布实况通知帧（downloadTemplate + SYSTEM_LIVE_VIEW）
// 发布串行执行并携带启停代次：停止/重启后，队列中的旧帧直接跳过，
// 在途发布也不会再以过期的通知 Id 记录误导性成功/失败日志。
function publishFrame(kind: LongTaskKind, title: string, content: string,
  progressValue: number): Promise<void> {
  let targetId: number = taskNotificationId(kind);
  if (targetId < 0) {
    return Promise.resolve();
  }
  let publishedId: number = targetId;
  let generation: number = taskGeneration(kind);
  let template: notificationManager.NotificationTemplate = {
    name: 'downloadTemplate',
    data: {
      title: title,
      fileName: content,
      progressValue: progressValue
    }
  };
  let request: notificationManager.NotificationRequest = {
    id: publishedId,
    notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
    template: template,
    content: {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
      systemLiveView: {
        typeCode: LIVE_VIEW_TYPE_CODE,
        title: title,
        text: content
      }
    }
  };
  notificationPublishChain = notificationPublishChain.then((): Promise<void> => {
    if (generation !== taskGeneration(kind) || publishedId !== taskNotificationId(kind)) {
      return Promise.resolve();
    }
    return notificationManager.publish(request).then((): void => {
      if (generation !== taskGeneration(kind) || publishedId !== taskNotificationId(kind)) {
        return;
      }
      logger.debug(kind + ' 通知已发布 id=' + publishedId + ' progress=' + progressValue);
    }).catch((e: Object): void => {
      if (generation !== taskGeneration(kind) || publishedId !== taskNotificationId(kind)) {
        return;
      }
      // 拒绝原因不止业务错误（如权限/系统异常对象），按可恢复降级记录（传输本身继续）
      logger.warn(kind + ' 通知发布失败：' + String(e));
    });
  }).catch((): void => {
  });
  return notificationPublishChain;
}

function emitProgress(overall: OverallSnapshot): void {
  // 终态已发布后不再发布任何进度帧（防过期节流帧回跳覆盖终态）
  if (terminalPublished) {
    return;
  }
  lastPublishMs = Date.now();
  lastPublishedPercent = overall.percent;
  publishFrame(LongTaskKind.transfer, getString($r('app.string.bg_transfer_title_transfer').id),
    getString($r('app.string.bg_transfer_content_transfer').id), Math.floor(overall.percent));
}

/** 发布保活任务帧（独立于传输任务）。 */
function publishWebKeepaliveFrame(): void {
  publishFrame(LongTaskKind.keepalive, getString($r('app.string.bg_transfer_title_keepalive').id),
    getString($r('app.string.bg_transfer_content_keepalive').id), webKeepalivePercent(Date.now()));
  // 保活任务按时间推进进度
  startWebKeepaliveHeartbeat();
}

// 发布最新聚合进度：在发布时刻重读快照并计算，避免使用调度时刻的过期快照；
// 期间传输已终态则直接转终态发布。
function publishLatestProgress(): void {
  let overall = currentOverall(lastPublishedPercent);
  if (overall.active) {
    emitProgress(overall);
    return;
  }
  if (!terminalPublished) {
    publishTerminal(overall);
  }
}

// 节流发布：间隔已到立即发；未到则合并到 pending 并在间隔边界发布最新值
function scheduleProgressPublish(_overall: OverallSnapshot): void {
  let delay: number = throttleDelayMs(Date.now(), lastPublishMs, PUBLISH_INTERVAL_MS);
  if (delay === 0) {
    cancelPendingPublish();
    publishLatestProgress();
    return;
  }
  if (pendingTimer < 0) {
    pendingTimer = setTimeout(() => {
      pendingTimer = -1;
      if (state === TransferTaskState.running) {
        publishLatestProgress();
      }
    }, delay);
  }
}

function cancelPendingPublish(): void {
  if (pendingTimer >= 0) {
    clearTimeout(pendingTimer);
    pendingTimer = -1;
  }
}

/** 本轮终态文案类别（只统计本轮后台周期关注的会话）。 */
function terminalKind(): TransferTerminalKind {
  return resolveTerminalKind(cycleHasFailure(), allTerminalFailed());
}

/** 终态标题资源。 */
function terminalTitleRes(kind: TransferTerminalKind): number {
  if (kind === TransferTerminalKind.failed) {
    return $r('app.string.bg_transfer_title_failed').id;
  }
  if (kind === TransferTerminalKind.partial) {
    return $r('app.string.bg_transfer_title_partial').id;
  }
  return $r('app.string.bg_transfer_title_done').id;
}

/**
 * 发布终态普通通知（独立 id，可震动响铃；回前台时统一撤销）。
 * 本轮仅一个任务时点击直达该任务详情；多个任务合并后点击回到任务中心，
 * 与发送失败浮卡「单条进详情、多条进任务页」的口径一致。
 */
function publishTerminalNotice(overall: OverallSnapshot): Promise<void> {
  let context = getAppContext();
  if (context === undefined) {
    return Promise.resolve();
  }
  let kind: TransferTerminalKind = terminalKind();
  let title: string = getString(terminalTitleRes(kind));
  let taskCount: number = cycleSessionIds.length;
  let content: string = getString($r('app.string.bg_transfer_content_tasks_percent').id,
    taskCount, Math.floor(overall.percent));
  let target: string = taskCount === 1 ? NAV_TARGET_SESSION_DETAIL : NAV_TARGET_TRANSFER_CENTER;
  let sessionId: string = taskCount === 1 ? cycleSessionIds[0] : '';
  return buildBackToFrontWantAgent(context, target, sessionId).then((agent: WantAgent): Promise<void> => {
    let noticeId: number = notificationId === TERMINAL_NOTICE_ID ? TERMINAL_NOTICE_FALLBACK_ID : TERMINAL_NOTICE_ID;
    let request: notificationManager.NotificationRequest = {
      id: noticeId,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: content
        }
      },
      wantAgent: agent
    };
    return notificationManager.publish(request).then((): void => {
      logger.debug('终态通知已发布 id=' + noticeId);
    }).catch((e: BusinessError): void => {
      logger.warn('终态通知发布失败：' + e.code + ' ' + e.message);
    });
  }).catch((e: BusinessError): void => {
    logger.warn('构建终态通知 WantAgent 失败：' + e.code + ' ' + e.message);
  });
}

/** 回前台撤销终态普通通知（无论是否通过点击通知进入应用）。 */
export function clearTerminalNotice(): void {
  // 固定 id 与备用 id 都撤一次：覆盖进程重启后内存状态丢失、旧通知仍在系统的情况
  notificationManager.cancel(TERMINAL_NOTICE_ID).catch((_e: BusinessError): void => {
  });
  notificationManager.cancel(TERMINAL_NOTICE_FALLBACK_ID).catch((_e: BusinessError): void => {
  });
}

/** 开启一个新的 5 分钟空闲保活窗口（进入后台时使用）。 */
function restartIdleKeepaliveWindow(): void {
  let now: number = Date.now();
  webKeepaliveStartMs = now;
  webKeepaliveUntil = now + WEB_KEEPALIVE_MS;
  webKeepaliveFinishing = false;
}

// 终态发布：成功和失败都发普通终态通知，保证新消息提醒；
// 普通通知发布完成后立即停止传输长时任务，避免“正在传输”通知继续误导。
function publishTerminal(overall: OverallSnapshot): void {
  cancelPendingPublish();
  terminalPublished = true;
  lastPublishMs = Date.now();
  lastPublishedPercent = overall.percent;
  let stopGen: number = ++terminalStopGeneration;
  let stopTransfer = (): void => {
    if (stopGen !== terminalStopGeneration) {
      return;
    }
    stopTaskInternal();
  };
  publishTerminalNotice(overall).then(stopTransfer, stopTransfer);
}

/**
 * 保活任务到期检查：固定 5 分钟，与传输任务完全独立。
 * 到期发布 100% 结束帧后停止保活任务，不影响仍在进行的传输。
 */
function scheduleWebKeepaliveStop(): void {
  cancelWebKeepaliveTimer();
  if (!backgroundServiceRunning()) {
    return;
  }
  let remaining: number = webKeepaliveUntil - Date.now();
  if (remaining <= 0) {
    finishWebKeepalive();
    return;
  }
  webKeepaliveTimer = setTimeout(() => {
    webKeepaliveTimer = -1;
    if (isAppForeground()) {
      return;
    }
    finishWebKeepalive();
  }, remaining);
}

// ── changeBus 驱动（进度事件 → 通知更新） ──

function onTransferChanged(): void {
  if (isAppForeground()) {
    maybePromptNotificationAuth();
    return;
  }
  let overall = currentOverall(lastPublishedPercent);
  // 任何后台事件都先把当前进行中的会话纳入本轮关注集合（终态文案判定依据）
  trackCycleSessions();
  if (overall.active) {
    // 新传输出现：使在途终态停止失效并复位终态标记，
    // 使传输长时任务继续有效并恢复进度通知；
    // 后台由 changeBus 驱动（重新）申请，覆盖"非切后台瞬间"自发开始的新传输
    terminalStopGeneration++;
    terminalPublished = false;
    ensureTransferTaskForBackground();
    if (state === TransferTaskState.running) {
      scheduleProgressPublish(overall);
    }
    return;
  }
  if (state !== TransferTaskState.running) {
    return;
  }
  if (!terminalPublished) {
    publishTerminal(overall);
  }
}

// 通知授权前台引导（T9）：前台有数据流动时引导一次，拒绝不阻塞传输
function maybePromptNotificationAuth(): void {
  if (authPrompted) {
    return;
  }
  let now: number = Date.now();
  if (lastAuthCheckMs >= 0 && now - lastAuthCheckMs < 2000) {
    return;
  }
  lastAuthCheckMs = now;
  let overall = currentOverall(0);
  if (!overall.active) {
    return;
  }
  authPrompted = true;
  notificationManager.isNotificationEnabled().then((enabled: boolean) => {
    if (enabled) {
      return;
    }
    let ctx = getAppContext();
    if (ctx === undefined) {
      return;
    }
    // 用户拒绝时 Promise 抛错（1600004 等），静默即可
    notificationManager.requestEnableNotification(ctx).then(() => {
      logger.debug('通知授权已通过');
    }).catch((e: BusinessError) => {
      logger.debug('通知授权被拒绝：' + e.code);
    });
  }).catch((e: BusinessError) => {
    logger.warn('查询通知开关失败：' + e.code + ' ' + e.message);
  });
}

// ── 长时任务生命周期 ──

// 点击通知回前台的 WantAgent 由共享工具构建（与后台关注通知一致）

function resetCycleState(): void {
  cancelPendingPublish();
  terminalStopGeneration++;
  notificationId = -1;
  continuousTaskId = -1;
  lastPublishMs = -1;
  lastPublishedPercent = 0;
  terminalPublished = false;
  cycleSessionIds = [];
}

function stopTaskInternal(): void {
  // 令未决的申请回调失效
  startGeneration++;
  let stopGeneration: number = startGeneration;
  let wasRunning: boolean = state === TransferTaskState.running;
  let ctx = taskContext;
  let taskId = continuousTaskId;
  resetCycleState();
  state = TransferTaskState.idle;
  taskContext = undefined;
  continuousTaskId = -1;
  if (wasRunning && ctx !== undefined) {
    let context: common.UIAbilityContext = ctx;
    let stopTask = (): void => {
      // 等待期间已有新周期启动：旧周期的停止不得误停新任务
      if (stopGeneration !== startGeneration) {
        return;
      }
      stopLongTask(context, taskId);
      logger.debug('传输长时任务已停止');
    };
    // 先让队列中的过期帧失效并等待在途发布结束，再取消通知，消除 publish 与 cancel 的竞态
    let pending: Promise<void> = notificationPublishChain;
    pending.then(stopTask, stopTask);
  }
}

// 长时任务取消回调：用户删除通知 → 取消全部活跃传输；系统取消 → 仅复位状态
function onContinuousTaskCancel(info: backgroundTaskManager.ContinuousTaskCancelInfo): void {
  let detailedReason: string = info.detailedReason !== undefined ? String(info.detailedReason) : '-';
  let byUser: boolean = info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL;
  logger.debug('长时任务已取消 id=' + info.id + ' reason=' + info.reason +
    ' detailedReason=' + detailedReason);
  // 保活任务被取消：只结束保活，不影响仍在进行的传输
  if (info.id === keepaliveContinuousTaskId) {
    keepaliveStartGeneration++;
    resetKeepaliveState();
    logger.debug('保活长时任务已取消');
    return;
  }
  if (state === TransferTaskState.idle) {
    return;
  }
  // 传输任务被取消：立即复位，抑制后续终态发布
  resetCycleState();
  startGeneration++;
  state = TransferTaskState.idle;
  taskContext = undefined;
  continuousTaskId = -1;
  if (byUser) {
    cancelAllActiveTransfers();
  }
}

// 删通知取消链路：经统一取消入口分发到各协议适配器（替代按方向硬编码分支）。
// 取消后由各协议事件回调驱动会话清理与 UI 刷新，无需额外状态处理。
function cancelAllActiveTransfers(): void {
  let sessions: Array<TransferSession> = getAllSessions();
  for (let i = 0; i < sessions.length; i++) {
    let session = sessions[i];
    if (isTerminalStage(session.stage)) {
      continue;
    }
    logger.debug('通知关闭取消活跃会话：' + session.id +
      ' protocol=' + session.protocolKey);
    cancelSession(session.id);
  }
}

// ── 公共 API ──

/**
 * 初始化服务：订阅 changeBus、注册长时任务取消监听（进程级幂等）。
 * 在 EntryAbility.onCreate 中调用。
 */
export function initBackgroundTransferService(): void {
  if (inited) {
    return;
  }
  inited = true;
  subscribe(onTransferChanged);
  try {
    backgroundTaskManager.on('continuousTaskCancel', onContinuousTaskCancel);
    logger.debug('长时任务取消监听已注册');
  } catch (e) {
    logger.warn('注册长时任务取消监听失败：' + JSON.stringify(e));
  }
}

/**
 * 进入后台（EntryAbility.onBackground）：记录上下文并同步前台状态，
 * 有活跃传输则申请 dataTransfer 长时任务并发布进度通知首帧。
 * 无传输则不做任何事（与既有行为一致）。幂等：任务已存在时直接返回。
 */
export function startTransferTaskIfActive(context: common.UIAbilityContext): void {
  setAppForeground(false);
  cachedContext = context;
  startTaskIfActiveInternal();
}

/**
 * 传输驱动的长时任务启动入口（幂等）：后台存在进行中传输且任务空闲时申请。
 * 由 changeBus 在后台检出传输变化时调用，使后台自发开始的新传输同样获得保护。
 * 前台、任务已存在、无活跃传输或缺少上下文时为空操作。
 */
export function ensureTransferTaskForBackground(): void {
  if (isAppForeground()) {
    return;
  }
  startTaskIfActiveInternal();
}

/** 申请一条 dataTransfer 实况窗长时任务。 */
function requestLongTask(context: common.UIAbilityContext,
  agent: WantAgent): Promise<backgroundTaskManager.ContinuousTaskNotification> {
  let request = new backgroundTaskManager.ContinuousTaskRequest();
  request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
  request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];
  request.wantAgent = agent;
  request.combinedTaskNotification = false;
  return backgroundTaskManager.startBackgroundRunning(context, request);
}

/** 停止指定长时任务；任务 Id 缺失时回退为停止当前 UIAbility 全部任务。 */
function stopLongTask(context: common.UIAbilityContext, taskId: number): void {
  if (taskId >= 0) {
    backgroundTaskManager.stopBackgroundRunning(context, taskId).catch((_e: BusinessError): void => {
    });
    return;
  }
  backgroundTaskManager.stopBackgroundRunning(context).catch((_e: BusinessError): void => {
  });
}

// 传输长时任务申请内部实现（调用方须已确认为后台场景）
function startTaskIfActiveInternal(): void {
  if (state !== TransferTaskState.idle) {
    return;
  }
  // 优先使用入口记录的上下文，缺省回退 AppCore 缓存的 UIAbilityContext
  let context = cachedContext ?? getAppContext();
  if (context === undefined) {
    logger.debug('无 Ability 上下文，跳过传输长时任务');
    return;
  }
  cachedContext = context;
  let overall = currentOverall(0);
  if (!overall.active) {
    logger.debug('无活跃传输，跳过传输长时任务');
    return;
  }
  let abilityContext: common.UIAbilityContext = context;
  let gen: number = ++startGeneration;
  state = TransferTaskState.starting;
  taskContext = abilityContext;
  resetCycleState();
  // 新周期开始：把当前进行中的会话重新纳入本轮关注集合
  trackCycleSessions();
  logger.debug('正在启动传输长时任务 sessions=' + overall.sessionCount);
  buildBackToFrontWantAgent(abilityContext, NAV_TARGET_TRANSFER_CENTER)
    .then((agent: WantAgent): Promise<backgroundTaskManager.ContinuousTaskNotification> => {
      return requestLongTask(abilityContext, agent);
    })
    .then((res: backgroundTaskManager.ContinuousTaskNotification) => {
      // 启停竞态：等待期间被 stop/新 start 取代 → 静默回收本次申请
      if (gen !== startGeneration) {
        logger.debug('传输任务启动已被取代，停止过期任务');
        stopLongTask(abilityContext, res.continuousTaskId !== undefined ? res.continuousTaskId : -1);
        return;
      }
      notificationId = res.notificationId;
      continuousTaskId = res.continuousTaskId !== undefined ? res.continuousTaskId : -1;
      state = TransferTaskState.running;
      logger.debug('传输长时任务运行中 notificationId=' + res.notificationId +
        ' taskId=' + continuousTaskId);
      // 首帧立即发布（同时满足实况进度“首次更新”的系统时限要求）
      emitProgress(overall);
    })
    .catch((e: BusinessError) => {
      if (gen === startGeneration) {
        state = TransferTaskState.idle;
        taskContext = undefined;
        // 申请失败（如通知校验未通过）不阻塞传输：退化为无保护后台
        logger.warn('启动传输长时任务失败，退化为无保护后台：' + e.code + ' ' + e.message);
      }
    });
}

/** 启动保活长时任务（独立于传输任务，固定 5 分钟）。 */
function startKeepaliveTaskInternal(): void {
  if (keepaliveState !== TransferTaskState.idle) {
    return;
  }
  let context = cachedContext ?? getAppContext();
  if (context === undefined) {
    logger.debug('无 Ability 上下文，跳过保活长时任务');
    return;
  }
  if (!isBackgroundReceiveEnabled() || !backgroundServiceRunning()) {
    return;
  }
  let abilityContext: common.UIAbilityContext = context;
  let gen: number = ++keepaliveStartGeneration;
  keepaliveState = TransferTaskState.starting;
  keepaliveContext = abilityContext;
  logger.debug('正在启动保活长时任务');
  buildBackToFrontWantAgent(abilityContext, NAV_TARGET_TRANSFER_CENTER)
    .then((agent: WantAgent): Promise<backgroundTaskManager.ContinuousTaskNotification> => {
      return requestLongTask(abilityContext, agent);
    })
    .then((res: backgroundTaskManager.ContinuousTaskNotification) => {
      if (gen !== keepaliveStartGeneration) {
        logger.debug('保活任务启动已被取代，停止过期任务');
        stopLongTask(abilityContext, res.continuousTaskId !== undefined ? res.continuousTaskId : -1);
        return;
      }
      keepaliveNotificationId = res.notificationId;
      keepaliveContinuousTaskId = res.continuousTaskId !== undefined ? res.continuousTaskId : -1;
      keepaliveState = TransferTaskState.running;
      logger.debug('保活长时任务运行中 notificationId=' + res.notificationId +
        ' taskId=' + keepaliveContinuousTaskId);
      publishWebKeepaliveFrame();
      scheduleWebKeepaliveStop();
    })
    .catch((e: BusinessError) => {
      if (gen === keepaliveStartGeneration) {
        keepaliveState = TransferTaskState.idle;
        keepaliveContext = undefined;
        logger.warn('启动保活长时任务失败：' + e.code + ' ' + e.message);
      }
    });
}

/**
 * 进入后台时启动空闲保活：为网页或 LocalSend 请求保留 5 分钟。
 * 开关关闭、无后台服务或已有任务运行时空操作/幂等。
 */
export function startWebKeepaliveIfEnabled(context: common.UIAbilityContext): void {
  setAppForeground(false);
  cachedContext = context;
  if (!isBackgroundReceiveEnabled() || !backgroundServiceRunning()) {
    return;
  }
  restartIdleKeepaliveWindow();
  startKeepaliveTaskInternal();
}

/**
 * 回到前台（EntryAbility.onForeground）/Ability 销毁（onDestroy 兜底）：
 * 停止长时任务，通知随之消失，展示交还前台传输页。
 */
export function stopTransferTask(): void {
  setAppForeground(true);
  // 两条长时任务独立，回前台都停止
  stopKeepaliveTaskInternal();
  // 回前台即视为用户已看到终态通知，统一撤销
  clearTerminalNotice();
  if (state === TransferTaskState.idle) {
    return;
  }
  logger.debug('回到前台/销毁时停止传输长时任务');
  stopTaskInternal();
}
