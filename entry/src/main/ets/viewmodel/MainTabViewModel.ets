import {
  getPendingCount,
  getUnfinishedCount,
  querySessions,
  subscribeSessions,
  unsubscribeSessions
} from '../service/transfer/TransferSessionRegistry';
import { SessionFilter, SessionStage, TransferSession } from '../model/transfer/TransferSession';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.DISCOVERY, 'HandySend:MainTab', '主页');

/**
 * 主页视图模型：维护一级入口（发送 / 任务 / 设置）的活跃角标，
 * 并感知新到达的待确认会话。
 *
 * 角标与任务列表同源同时机：两者都订阅同一变更总线（注册表会话变化即通知），
 * 每次会话变化都从注册表重算，不存在「角标有数字而列表无/0%」的不同步来源。
 *
 * 待确认请求由协议适配器登记为注册表中的待确认会话；收到新的接收请求（新的待确认会话）时，
 * 经 `autoOpenSessionIds` 通知主页面逐条进入这些会话的详情页，由用户在详情页确认/拒绝或关闭/复制。
 *
 * 接收完成不触发任何自动跳转（尤其不得以会话标识进入详情页）：
 * 接收结果由任务与会话详情页按需展示，避免以未就绪/已回收的会话进入空白详情页。
 */
@ObservedV2
export class MainTabViewModel {
  /** 非终态（进行中 + 待确认）会话数（任务入口角标） */
  @Trace public activeTransferCount: number = 0
  /** 待确认会话数 */
  @Trace public pendingCount: number = 0
  /** 待打开的新待确认会话标识队列（空数组表示无）；页面消费后清空 */
  @Trace public autoOpenSessionIds: Array<string> = []
  /** 队列变更版本：数组属性监听在部分运行时不稳定，用标量版本保证页面一定收到通知 */
  @Trace public autoOpenSessionVersion: number = 0
  /** 已感知的待确认会话标识（同一会话不重复入队） */
  private knownPendingIds: Array<string> = []
  // 上次输出的待确认计数：变更总线为全局通知，无关变更（发现/设置等）也会触发本 VM，
  // 计数未变时不再重复输出同一行
  private lastLoggedPendingCount: number = 0
  private subscribed: boolean = false
  // 变更总线回调需保持同一引用以便退订
  private changeCallback: () => void = (): void => {
  }

  /** 订阅变更总线并首次刷新角标（与任务列表同源同时机）。 */
  start(): void {
    if (!this.subscribed) {
      this.changeCallback = (): void => {
        this.refreshBadges();
      };
      subscribeSessions(this.changeCallback);
      this.subscribed = true;
    }
    this.refreshBadges();
  }

  stop(): void {
    if (this.subscribed) {
      unsubscribeSessions(this.changeCallback);
      this.subscribed = false;
    }
  }

  /** 从统一注册表刷新入口角标（会话变化时调用），并感知新到达的待确认会话。 */
  refreshBadges(): void {
    // 任务入口数量统一为「非终态（进行中 + 待确认）」口径
    this.activeTransferCount = getUnfinishedCount();
    this.pendingCount = getPendingCount();
    this.detectNewPendingSession();
    // 仅在待确认计数实际变化时输出，与行序列转储同策（见注释 lastLoggedPendingCount）
    if (this.pendingCount > 0 && this.pendingCount !== this.lastLoggedPendingCount) {
      logger.debug('待确认任务数：' + this.pendingCount);
    }
    this.lastLoggedPendingCount = this.pendingCount;
  }

  /**
   * 感知新到达的待确认会话：与已感知集合比较，出现新标识时追加到待打开队列。
   * 页面（MainTabFloating）消费队列，逐条进入这些会话的详情页；同一会话只入队一次。
   */
  private detectNewPendingSession(): void {
    let filter: SessionFilter = { stage: SessionStage.awaitingConfirmation };
    let pending: Array<TransferSession> = querySessions(filter);
    let currentIds: Array<string> = [];
    let newIds: Array<string> = [];
    for (let i = 0; i < pending.length; i++) {
      let id: string = pending[i].id;
      currentIds.push(id);
      if (this.knownPendingIds.indexOf(id) < 0) {
        newIds.push(id);
      }
    }
    this.knownPendingIds = currentIds;
    if (newIds.length === 0) {
      return;
    }
    // 追加而不是覆盖：页面尚未消费完上一批时，新请求继续排在队尾
    let queue: Array<string> = this.autoOpenSessionIds.slice();
    for (let i = 0; i < newIds.length; i++) {
      if (queue.indexOf(newIds[i]) < 0) {
        queue.push(newIds[i]);
      }
    }
    logger.debug('新的待确认任务数：' + newIds.length);
    this.autoOpenSessionIds = queue;
    this.autoOpenSessionVersion = this.autoOpenSessionVersion + 1;
  }
}
