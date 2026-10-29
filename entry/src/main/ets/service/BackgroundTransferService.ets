/**
 * BackgroundTransferService.ets — 传输后台续传服务
 *
 * 编排 dataTransfer 长时任务与系统实况通知（downloadTemplate）：
 * - onBackground 时若有活跃传输 → 申请长时任务并发布进度通知（1s 节流 + 同帧合并）；
 * - onForeground → 停止任务（通知随任务取消自动消失）；
 * - 全部会话终态 → 终态通知停留数秒后停止任务；
 * - 用户删除通知（continuousTaskCancel USER_CANCEL）→ 取消全部活跃传输。
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
import { buildBackToFrontWantAgent, NAV_TARGET_TRANSFER_CENTER } from '../utils/WantAgentUtil';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:BackgroundTransferService', '后台传输');

// 进度通知发布节流间隔（毫秒）
const PUBLISH_INTERVAL_MS = 1000;
// 终态通知停留时长（毫秒）：终态帧发布后延迟停止长时任务，
// 停止时通知随任务取消自动消失，此窗口即终态通知的可见期
const TERMINAL_LINGER_MS = 10000;
// 网页分享后台有界保活（毫秒）：进入后台后即使没有传输，也为网页访问保留 5 分钟
const WEB_KEEPALIVE_MS = 5 * 60 * 1000;
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

// ── 模块状态 ──

let state: TransferTaskState = TransferTaskState.idle;
// 申请代次：stop/新 start 使旧代次的异步回调失效（防启停竞态）
let startGeneration: number = 0;
// 长时任务返回的通知 Id（进度更新必须复用）
let notificationId: number = -1;
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
// 终态停留定时器
let terminalTimer: number = -1;
// 网页分享有界保活截止时刻（0 表示无）与停止定时器
let webKeepaliveUntil: number = 0;
let webKeepaliveTimer: number = -1;
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

/** 当前是否有已启动的网页服务（用于判断后台是否值得为网页保留）。 */
function webServiceRunning(): boolean {
  return getWebActualPort() > 0;
}

/** 网页后台有界保活是否仍在有效期内。 */
function hasWebKeepalive(): boolean {
  return webKeepaliveUntil > Date.now() && webServiceRunning();
}

/** 有任何后台活动时续期网页保活窗口（活动期间本就不受 5 分钟限制）。 */
function extendWebKeepalive(): void {
  if (webServiceRunning()) {
    webKeepaliveUntil = Date.now() + WEB_KEEPALIVE_MS;
  }
}

/**
 * 网页访问只续期有界保活并确保后台长时任务存在；不创建统一会话、不发通知。
 * 调用方为 AppService 的 webAccess 事件路由。
 */
export function noteWebAccess(): void {
  if (!webServiceRunning()) {
    return;
  }
  extendWebKeepalive();
  ensureTransferTaskForBackground();
}

function cancelWebKeepaliveTimer(): void {
  if (webKeepaliveTimer >= 0) {
    clearTimeout(webKeepaliveTimer);
    webKeepaliveTimer = -1;
  }
}

/** 结束网页后台保活（回前台、用户删除通知、任务停止时调用）。 */
function clearWebKeepalive(): void {
  cancelWebKeepaliveTimer();
  webKeepaliveUntil = 0;
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

// 进度行文案：单设备「45%」，多设备「3 台设备 · 45%」
function buildProgressContent(overall: OverallSnapshot): string {
  let percent: number = Math.floor(overall.percent);
  if (overall.deviceCount > 1) {
    return getString($r('app.string.bg_transfer_content_devices_percent').id,
      overall.deviceCount, percent);
  }
  return getString($r('app.string.bg_transfer_content_percent').id, percent);
}

// 以长时任务通知 Id 发布实况通知帧（downloadTemplate + SYSTEM_LIVE_VIEW）
// 发布串行执行并携带启停代次：停止/重启后，队列中的旧帧直接跳过，
// 在途发布也不会再以过期的通知 Id 记录误导性成功/失败日志。
function publishFrame(title: string, content: string, progressValue: number): void {
  if (notificationId < 0) {
    return;
  }
  let publishedId: number = notificationId;
  let generation: number = startGeneration;
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
    if (generation !== startGeneration || publishedId !== notificationId) {
      return Promise.resolve();
    }
    return notificationManager.publish(request).then((): void => {
      if (generation !== startGeneration || publishedId !== notificationId) {
        return;
      }
      logger.debug('通知已发布 id=' + publishedId + ' progress=' + progressValue);
    }).catch((e: Object): void => {
      if (generation !== startGeneration || publishedId !== notificationId) {
        return;
      }
      // 拒绝原因不止业务错误（如权限/系统异常对象），按可恢复降级记录（传输本身继续）
      logger.warn('通知发布失败：' + String(e));
    });
  }).catch((): void => {
  });
}

function emitProgress(overall: OverallSnapshot): void {
  // 终态已发布后不再发布任何进度帧（防过期节流帧回跳覆盖终态）
  if (terminalPublished) {
    return;
  }
  lastPublishMs = Date.now();
  lastPublishedPercent = overall.percent;
  publishFrame(getString($r('app.string.bg_transfer_title').id),
    buildProgressContent(overall), Math.floor(overall.percent));
}

/** 无活跃传输但网页后台保活生效时，通知展示“网页分享保持中”。 */
function publishWebKeepaliveFrame(): void {
  cancelPendingPublish();
  cancelTerminalTimer();
  terminalPublished = false;
  lastPublishMs = Date.now();
  lastPublishedPercent = 0;
  publishFrame(getString($r('app.string.bg_transfer_title_web_keepalive').id),
    getString($r('app.string.bg_transfer_content_web_keepalive').id), 0);
}

// 发布最新聚合进度：在发布时刻重读快照并计算，避免使用调度时刻的过期快照；
// 期间传输已终态则直接转终态发布。
function publishLatestProgress(): void {
  if (terminalPublished) {
    return;
  }
  let overall = currentOverall(lastPublishedPercent);
  if (overall.active) {
    emitProgress(overall);
  } else if (hasWebKeepalive()) {
    // 节流帧晚于最后一次会话终结：网页保活仍在有效期，不能按普通终态停止任务
    publishWebKeepaliveFrame();
    scheduleWebKeepaliveStop();
  } else {
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

// 终态发布：取消待发布节流帧（避免终态被过期进度帧覆盖）后立即发终态帧（绕过节流），
// 并安排延迟停止任务（通知随任务消失）
function publishTerminal(overall: OverallSnapshot): void {
  cancelPendingPublish();
  terminalPublished = true;
  lastPublishMs = Date.now();
  lastPublishedPercent = overall.percent;
  // 成败判定只看本轮会话集合：overall.hasFailure 含注册表全部会话，
  // 历史失败残留会把全成功误报为部分失败
  let kind: TransferTerminalKind = resolveTerminalKind(cycleHasFailure(), allTerminalFailed());
  let titleRes: number = $r('app.string.bg_transfer_title_done').id;
  if (kind === TransferTerminalKind.failed) {
    titleRes = $r('app.string.bg_transfer_title_failed').id;
  } else if (kind === TransferTerminalKind.partial) {
    titleRes = $r('app.string.bg_transfer_title_partial').id;
  }
  publishFrame(getString(titleRes), buildProgressContent(overall), Math.floor(overall.percent));
  terminalTimer = setTimeout(() => {
    terminalTimer = -1;
    stopTaskInternal();
  }, TERMINAL_LINGER_MS);
}

function cancelTerminalTimer(): void {
  if (terminalTimer >= 0) {
    clearTimeout(terminalTimer);
    terminalTimer = -1;
  }
}

/**
 * 网页保活到期检查：无活跃会话时停止长时任务；仍有活跃会话则顺延。
 * 保活是“有界”的：初始进入后台 5 分钟，期间有传输/访问则随活动续期。
 */
function scheduleWebKeepaliveStop(): void {
  cancelWebKeepaliveTimer();
  if (!webServiceRunning()) {
    return;
  }
  let remaining: number = webKeepaliveUntil - Date.now();
  if (remaining <= 0) {
    if (!hasActiveSessions()) {
      stopTaskInternal();
    }
    return;
  }
  webKeepaliveTimer = setTimeout(() => {
    webKeepaliveTimer = -1;
    if (isAppForeground()) {
      return;
    }
    if (hasActiveSessions()) {
      extendWebKeepalive();
      scheduleWebKeepaliveStop();
      return;
    }
    if (hasWebKeepalive()) {
      scheduleWebKeepaliveStop();
      return;
    }
    stopTaskInternal();
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
    // 新传输出现（含上一轮终态停留期内）：取消终端停止计划并复位终态标记，
    // 使长时任务继续有效（不按上一轮终态计划停止）并恢复进度通知；
    // 后台由 changeBus 驱动（重新）申请，覆盖"非切后台瞬间"自发开始的新传输
    cancelTerminalTimer();
    extendWebKeepalive();
    terminalPublished = false;
    ensureTransferTaskForBackground();
    if (state === TransferTaskState.running) {
      scheduleProgressPublish(overall);
    }
    return;
  }
  if (state !== TransferTaskState.running) {
    if (hasWebKeepalive()) {
      ensureTransferTaskForBackground();
    }
    return;
  }
  if (hasWebKeepalive()) {
    // 传输已结束但网页后台保活仍在有效期：通知改为“网页分享保持中”，
    // 到期后再停止长时任务；期间任何新访问/传输都会续期。
    publishWebKeepaliveFrame();
    scheduleWebKeepaliveStop();
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
  cancelTerminalTimer();
  notificationId = -1;
  lastPublishMs = -1;
  lastPublishedPercent = 0;
  terminalPublished = false;
  cycleSessionIds = [];
}

function stopTaskInternal(): void {
  // 令未决的申请回调失效
  startGeneration++;
  let stopGeneration: number = startGeneration;
  clearWebKeepalive();
  let wasRunning: boolean = state === TransferTaskState.running;
  let ctx = taskContext;
  resetCycleState();
  state = TransferTaskState.idle;
  taskContext = undefined;
  if (wasRunning && ctx !== undefined) {
    let context: common.UIAbilityContext = ctx;
    let stopTask = (): void => {
      // 等待期间已有新周期启动：旧周期的停止不得误停新任务
      if (stopGeneration !== startGeneration) {
        return;
      }
      backgroundTaskManager.stopBackgroundRunning(context).then(() => {
        logger.debug('后台任务已停止');
      }).catch((e: BusinessError) => {
        logger.warn('停止后台任务失败：' + e.code + ' ' + e.message);
      });
    };
    // 先让队列中的过期帧失效并等待在途发布结束，再取消通知，消除 publish 与 cancel 的竞态
    let pending: Promise<void> = notificationPublishChain;
    pending.then(stopTask, stopTask);
  }
}

// 长时任务取消回调：用户删除通知 → 取消全部活跃传输；系统取消 → 仅复位状态
function onContinuousTaskCancel(info: backgroundTaskManager.ContinuousTaskCancelInfo): void {
  logger.debug('长时任务已取消 id=' + info.id + ' reason=' + info.reason);
  if (state === TransferTaskState.idle) {
    return;
  }
  let byUser: boolean = info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL;
  // 立即复位：抑制后续终态发布（通知已被用户移除，不应再出现终态帧）
  resetCycleState();
  clearWebKeepalive();
  startGeneration++;
  state = TransferTaskState.idle;
  taskContext = undefined;
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
    logger.error('注册长时任务取消监听失败：' + JSON.stringify(e));
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

// 长时任务申请内部实现（调用方须已确认为后台场景）
function startTaskIfActiveInternal(): void {
  if (state !== TransferTaskState.idle) {
    return;
  }
  // 优先使用入口记录的上下文，缺省回退 AppCore 缓存的 UIAbilityContext
  let context = cachedContext ?? getAppContext();
  if (context === undefined) {
    logger.debug('无 Ability 上下文，跳过后台任务');
    return;
  }
  cachedContext = context;
  let overall = currentOverall(0);
  let keepWebAlive: boolean = hasWebKeepalive();
  if (!overall.active && !keepWebAlive) {
    logger.debug('无活跃传输且无网页保活，跳过后台任务');
    return;
  }
  let gen: number = ++startGeneration;
  state = TransferTaskState.starting;
  taskContext = context;
  resetCycleState();
  // 新周期开始：把当前进行中的会话重新纳入本轮关注集合
  trackCycleSessions();
  logger.info('正在启动后台任务 sessions=' + overall.sessionCount);
  buildBackToFrontWantAgent(context, NAV_TARGET_TRANSFER_CENTER)
    .then((agent: WantAgent): Promise<backgroundTaskManager.ContinuousTaskNotification> => {
      let modes: Array<string> = ['dataTransfer'];
      return backgroundTaskManager.startBackgroundRunning(context, modes, agent);
    })
    .then((res: backgroundTaskManager.ContinuousTaskNotification) => {
      // 启停竞态：等待期间被 stop/新 start 取代 → 静默回收本次申请
      if (gen !== startGeneration) {
        logger.debug('本次启动已被取代，停止过期任务');
        backgroundTaskManager.stopBackgroundRunning(context).catch((_e: BusinessError) => {
        });
        return;
      }
      notificationId = res.notificationId;
      state = TransferTaskState.running;
      logger.debug('后台任务运行中 notificationId=' + res.notificationId);
      if (overall.active) {
        // 首帧立即发布（同时满足实况进度“首次更新”的系统时限要求）
        emitProgress(overall);
      } else {
        publishWebKeepaliveFrame();
        scheduleWebKeepaliveStop();
      }
    })
    .catch((e: BusinessError) => {
      if (gen === startGeneration) {
        state = TransferTaskState.idle;
        taskContext = undefined;
        // 申请失败（如通知校验未通过）不阻塞传输：退化为与今日相同的无保护后台
        logger.error('启动后台任务失败：' + e.code + ' ' + e.message);
      }
    });
}

/**
 * 进入后台时启动网页有界保活：即使没有活跃传输，也为网页访问保留 5 分钟。
 * 有传输时沿用现有传输长时任务；触发新传输/访问后由 changeBus 续期。
 * 无网页服务或已有任务运行时空操作/幂等。
 */
export function startWebKeepaliveIfEnabled(context: common.UIAbilityContext): void {
  setAppForeground(false);
  cachedContext = context;
  if (!webServiceRunning()) {
    return;
  }
  webKeepaliveUntil = Date.now() + WEB_KEEPALIVE_MS;
  startTaskIfActiveInternal();
  if (state === TransferTaskState.running && !hasActiveSessions()) {
    scheduleWebKeepaliveStop();
  }
}

/**
 * 回到前台（EntryAbility.onForeground）/Ability 销毁（onDestroy 兜底）：
 * 停止长时任务，通知随之消失，展示交还前台传输页。
 */
export function stopTransferTask(): void {
  setAppForeground(true);
  clearWebKeepalive();
  if (state === TransferTaskState.idle) {
    return;
  }
  logger.debug('回到前台/销毁时停止后台任务');
  stopTaskInternal();
}
