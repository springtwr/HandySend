/**
 * BackgroundTransferService.ets — 传输后台续传服务
 *
 * 编排 dataTransfer 长时任务与系统实况通知（downloadTemplate）：
 * - onBackground 时若有活跃传输 → 申请长时任务并发布进度通知（1s 节流 + 同帧合并）；
 * - onForeground → 停止任务（通知随任务取消自动消失）；
 * - 全部会话终态 → 终态通知停留数秒后停止任务；
 * - 用户删除通知（continuousTaskCancel USER_CANCEL）→ 取消全部活跃传输。
 *
 * 数据源：SendRepository/ReceiveRepository/MtaRepository 经
 * TransferProgressUtil 聚合（纯函数，见该文件单测）。
 * 模块级单例组织方式与 MtaRepository 一致。
 */

import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { getAppContext, subscribe, isAppForeground, setAppForeground } from './repository/AppCore';
import { getSendSessions, getActiveProgress } from './repository/SendRepository';
import { getLocalSendReceiveSessions } from './repository/ReceiveRepository';
import {
  getWebDownloadSessions,
  getWebDownloadProgress
} from './repository/WebShareRepository';
import {
  getMtaReceiveSnapshot,
  getMtaSendSnapshot,
  cancelMtaReceive
} from './repository/MtaRepository';
import { nativeCancelTransferLocal, nativeCancelLocalSession } from './NativeBridge';
import {
  TransferSessionSnapshot,
  TransferDirection,
  OverallTransferSnapshot,
  buildSendSessionSnapshots,
  buildReceiveSessionSnapshots,
  buildMtaSendSessionSnapshot,
  buildMtaReceiveSessionSnapshot,
  buildWebDownloadSessionSnapshots,
  computeOverallTransferSnapshot
} from '../utils/TransferProgressUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:BackgroundTransferService', '后台传输');

// 进度通知发布节流间隔（毫秒）
const PUBLISH_INTERVAL_MS = 1000;
// 终态通知停留时长（毫秒）：终态帧发布后延迟停止长时任务，
// 停止时通知随任务取消自动消失，此窗口即终态通知的可见期
const TERMINAL_LINGER_MS = 10000;
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

// ── 数据聚合 ──

// 汇聚 5 路会话快照（后台通知、取消链路与聚合共用）：
// LocalSend 发送 / LocalSend 接收 / MTA 发送 / MTA 接收 / Web 下载。
export function gatherSessionSnapshots(): Array<TransferSessionSnapshot> {
  let snapshots: Array<TransferSessionSnapshot> = [];
  // 1) LocalSend 发送会话
  snapshots = snapshots.concat(buildSendSessionSnapshots(
    getSendSessions(), getActiveProgress()));
  // 2) LocalSend 接收会话
  snapshots = snapshots.concat(buildReceiveSessionSnapshots(
    getLocalSendReceiveSessions(), getActiveProgress()));
  // 3) MTA 发送会话
  let mtaSendSnapshot = buildMtaSendSessionSnapshot(getMtaSendSnapshot());
  if (mtaSendSnapshot !== undefined) {
    snapshots.push(mtaSendSnapshot);
  }
  // 4) MTA 接收会话
  let mtaSnapshot = buildMtaReceiveSessionSnapshot(getMtaReceiveSnapshot());
  if (mtaSnapshot !== undefined) {
    snapshots.push(mtaSnapshot);
  }
  // 5) Web 下载会话
  snapshots = snapshots.concat(buildWebDownloadSessionSnapshots(
    getWebDownloadSessions(), getWebDownloadProgress()));
  return snapshots;
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
function buildProgressContent(overall: OverallTransferSnapshot): string {
  let percent: number = Math.floor(overall.percent);
  if (overall.deviceCount > 1) {
    return getString($r('app.string.bg_transfer_content_devices_percent').id,
      overall.deviceCount, percent);
  }
  return getString($r('app.string.bg_transfer_content_percent').id, percent);
}

// 以长时任务通知 Id 发布实况通知帧（downloadTemplate + SYSTEM_LIVE_VIEW）
function publishFrame(title: string, content: string, progressValue: number): void {
  if (notificationId < 0) {
    return;
  }
  let template: notificationManager.NotificationTemplate = {
    name: 'downloadTemplate',
    data: {
      title: title,
      fileName: content,
      progressValue: progressValue
    }
  };
  let request: notificationManager.NotificationRequest = {
    id: notificationId,
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
  notificationManager.publish(request).then(() => {
    logger.debug('notification published, id=' + notificationId + ' progress=' + progressValue);
  }).catch((e: BusinessError) => {
    logger.error('notification publish failed: ' + e.code + ' ' + e.message);
  });
}

function emitProgress(overall: OverallTransferSnapshot): void {
  // 终态已发布后不再发布任何进度帧（防过期节流帧回跳覆盖终态）
  if (terminalPublished) {
    return;
  }
  lastPublishMs = Date.now();
  lastPublishedPercent = overall.percent;
  publishFrame(getString($r('app.string.bg_transfer_title').id),
    buildProgressContent(overall), Math.floor(overall.percent));
}

// 发布最新聚合进度：在发布时刻重读快照并计算，避免使用调度时刻的过期快照；
// 期间传输已终态则直接转终态发布。
function publishLatestProgress(): void {
  if (terminalPublished) {
    return;
  }
  let snapshots = gatherSessionSnapshots();
  let overall = computeOverallTransferSnapshot(snapshots, lastPublishedPercent);
  if (overall.active) {
    emitProgress(overall);
  } else {
    publishTerminal(overall, snapshots);
  }
}

// 节流发布：间隔已到立即发；未到则合并到 pending 并在间隔边界发布最新值
function scheduleProgressPublish(_overall: OverallTransferSnapshot): void {
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
function publishTerminal(overall: OverallTransferSnapshot, snapshots: Array<TransferSessionSnapshot>): void {
  cancelPendingPublish();
  terminalPublished = true;
  lastPublishMs = Date.now();
  lastPublishedPercent = overall.percent;
  let allFailed: boolean = true;
  let hasTerminal: boolean = false;
  for (let i = 0; i < snapshots.length; i++) {
    if (!snapshots[i].active) {
      hasTerminal = true;
      if (snapshots[i].success) {
        allFailed = false;
      }
    }
  }
  let kind: TransferTerminalKind = resolveTerminalKind(overall.hasFailure, hasTerminal && allFailed);
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

// ── changeBus 驱动（进度事件 → 通知更新） ──

function onTransferChanged(): void {
  if (isAppForeground()) {
    maybePromptNotificationAuth();
    return;
  }
  let snapshots = gatherSessionSnapshots();
  let overall = computeOverallTransferSnapshot(snapshots, lastPublishedPercent);
  if (overall.active) {
    // 新传输出现（含上一轮终态停留期内）：取消终端停止计划并复位终态标记，
    // 使长时任务继续有效（不按上一轮终态计划停止）并恢复进度通知；
    // 后台由 changeBus 驱动（重新）申请，覆盖"非切后台瞬间"自发开始的新传输
    cancelTerminalTimer();
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
    publishTerminal(overall, snapshots);
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
  let overall = computeOverallTransferSnapshot(gatherSessionSnapshots(), 0);
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
      logger.info('notification auth granted');
    }).catch((e: BusinessError) => {
      logger.info('notification auth declined: ' + e.code);
    });
  }).catch((e: BusinessError) => {
    logger.warn('isNotificationEnabled failed: ' + e.code + ' ' + e.message);
  });
}

// ── 长时任务生命周期 ──

function buildWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
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

function resetCycleState(): void {
  cancelPendingPublish();
  cancelTerminalTimer();
  notificationId = -1;
  lastPublishMs = -1;
  lastPublishedPercent = 0;
  terminalPublished = false;
}

function stopTaskInternal(): void {
  // 令未决的申请回调失效
  startGeneration++;
  let wasRunning: boolean = state === TransferTaskState.running;
  let ctx = taskContext;
  resetCycleState();
  state = TransferTaskState.idle;
  taskContext = undefined;
  if (wasRunning && ctx !== undefined) {
    backgroundTaskManager.stopBackgroundRunning(ctx).then(() => {
      logger.info('background task stopped');
    }).catch((e: BusinessError) => {
      logger.warn('stop background task failed: ' + e.code + ' ' + e.message);
    });
  }
}

// 长时任务取消回调：用户删除通知 → 取消全部活跃传输；系统取消 → 仅复位状态
function onContinuousTaskCancel(info: backgroundTaskManager.ContinuousTaskCancelInfo): void {
  logger.info('continuous task cancelled, id=' + info.id + ' reason=' + info.reason);
  if (state === TransferTaskState.idle) {
    return;
  }
  let byUser: boolean = info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL;
  // 立即复位：抑制后续终态发布（通知已被用户移除，不应再出现终态帧）
  resetCycleState();
  startGeneration++;
  state = TransferTaskState.idle;
  taskContext = undefined;
  if (byUser) {
    cancelAllActiveTransfers();
  }
}

// 删通知取消链路：取消全部活跃传输（发送/LocalSend 接收/MTA 接收）。
// 原生层取消后经既有事件回调驱动会话清理与 UI 刷新，无需额外状态处理。
function cancelAllActiveTransfers(): void {
  let snapshots = gatherSessionSnapshots();
  for (let i = 0; i < snapshots.length; i++) {
    let s = snapshots[i];
    if (!s.active) {
      continue;
    }
    if (s.direction === TransferDirection.send) {
      logger.info('cancel send session on notification dismiss: ' + s.sessionId);
      nativeCancelTransferLocalSafe(s.sessionId);
    } else if (s.direction === TransferDirection.receive) {
      logger.info('cancel receive session on notification dismiss: ' + s.sessionId);
      nativeCancelLocalSessionSafe(s.sessionId);
    } else if (s.direction === TransferDirection.mtaReceive) {
      logger.info('cancel mta receive on notification dismiss');
      cancelMtaReceive();
    }
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
    logger.info('continuous task cancel listener registered');
  } catch (e) {
    logger.error('register continuous task cancel listener failed: ' + JSON.stringify(e));
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
    logger.debug('no ability context, skip background task');
    return;
  }
  cachedContext = context;
  let snapshots = gatherSessionSnapshots();
  let overall = computeOverallTransferSnapshot(snapshots, 0);
  if (!overall.active) {
    logger.debug('no active transfer, skip background task');
    return;
  }
  let gen: number = ++startGeneration;
  state = TransferTaskState.starting;
  taskContext = context;
  resetCycleState();
  logger.info('starting background task, sessions=' + overall.sessionCount);
  buildWantAgent(context).then((agent: WantAgent): Promise<backgroundTaskManager.ContinuousTaskNotification> => {
    let modes: Array<string> = ['dataTransfer'];
    return backgroundTaskManager.startBackgroundRunning(context, modes, agent);
  }).then((res: backgroundTaskManager.ContinuousTaskNotification) => {
    // 启停竞态：等待期间被 stop/新 start 取代 → 静默回收本次申请
    if (gen !== startGeneration) {
      logger.info('start superseded, stopping stale task');
      backgroundTaskManager.stopBackgroundRunning(context).catch((_e: BusinessError) => {
      });
      return;
    }
    notificationId = res.notificationId;
    state = TransferTaskState.running;
    logger.info('background task running, notificationId=' + res.notificationId);
    // 首帧立即发布（同时满足实况进度“首次更新”的系统时限要求）
    emitProgress(overall);
  }).catch((e: BusinessError) => {
    if (gen === startGeneration) {
      state = TransferTaskState.idle;
      taskContext = undefined;
      // 申请失败（如通知校验未通过）不阻塞传输：退化为与今日相同的无保护后台
      logger.error('start background task failed: ' + e.code + ' ' + e.message);
    }
  });
}

/**
 * 回到前台（EntryAbility.onForeground）/Ability 销毁（onDestroy 兜底）：
 * 停止长时任务，通知随之消失，展示交还前台传输页。
 */
export function stopTransferTask(): void {
  setAppForeground(true);
  if (state === TransferTaskState.idle) {
    return;
  }
  logger.info('stopping background task on foreground/destroy');
  stopTaskInternal();
}

// ── 取消链路的原生调用封装（失败仅记录，不中断其余会话取消） ──

function nativeCancelTransferLocalSafe(sessionId: string): void {
  try {
    nativeCancelTransferLocal(sessionId);
  } catch (e) {
    logger.warn('native cancel send failed: ' + JSON.stringify(e));
  }
}

function nativeCancelLocalSessionSafe(sessionId: string): void {
  nativeCancelLocalSession(sessionId).catch((e: Object): void => {
    logger.warn('native cancel receive failed: ' + String(e));
  });
}
