import {
  getActiveCount,
  getPendingCount,
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
 * 待确认请求由协议适配器登记为注册表中的待确认会话，主页不再经 TransferPage
 * 做接收路由，也不再消费一次性事件队列；收到新的接收请求（新的待确认会话）时，
 * 经 `autoOpenSessionId` 通知主页面自动进入该会话详情页，供用户确认或拒绝。
 *
 * 接收完成不触发任何自动跳转（尤其不得以会话标识进入详情页）：
 * 接收结果由任务与会话详情页按需展示，避免以未就绪/已回收的会话进入空白详情页。
 */
@ObservedV2
export class MainTabViewModel {
  /** 活跃会话数（任务入口角标） */
  @Trace public activeTransferCount: number = 0
  /** 待确认会话数 */
  @Trace public pendingCount: number = 0
  /** 需要自动进入详情页的待确认会话标识（空串表示无）；页面消费后置空 */
  @Trace public autoOpenSessionId: string = ''
  /** 已感知的待确认会话标识（同一会话不重复自动进入） */
  private knownPendingIds: Array<string> = []
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
    this.activeTransferCount = getActiveCount();
    this.pendingCount = getPendingCount();
    this.detectNewPendingSession();
    if (this.pendingCount > 0) {
      logger.debug('pending sessions: ' + this.pendingCount);
    }
  }

  /**
   * 感知新到达的待确认会话：与已感知集合比较，出现新标识时置位自动进入信号。
   * 同一会话在自动进入后被确认/拒绝而消失时不会再误触发。
   */
  private detectNewPendingSession(): void {
    let filter: SessionFilter = { stage: SessionStage.awaitingConfirmation };
    let pending: Array<TransferSession> = querySessions(filter);
    let currentIds: Array<string> = [];
    let newSessionId: string = '';
    for (let i = 0; i < pending.length; i++) {
      let id: string = pending[i].id;
      currentIds.push(id);
      if (this.knownPendingIds.indexOf(id) < 0) {
        newSessionId = id;
      }
    }
    this.knownPendingIds = currentIds;
    // 取舍声明：多个新待确认会话同帧并发到达时只自动进入最后一个
    // （自动进入详情仅为便捷引导，任务列表可见全部待确认会话）
    if (newSessionId.length > 0 && newSessionId !== this.autoOpenSessionId) {
      logger.debug('new pending session: ' + newSessionId.substring(0, 8));
      this.autoOpenSessionId = newSessionId;
    }
  }
}
