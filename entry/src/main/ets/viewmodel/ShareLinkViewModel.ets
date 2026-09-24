import {
  getShareLink,
  getHttpsEnabled,
  stopShareLink,
  startWebUpload,
  getPendingWebDownloads,
  acceptWebDownloadRequest,
  declineWebDownloadRequest,
  declineAllPendingWebDownloads,
  hasActiveWebDownloads,
  querySessions,
  confirmSession,
  declineSession,
  subscribeSessions,
  unsubscribeSessions,
  subscribe,
  unsubscribe,
  getLocalSendEnabled
} from '../service/AppService';
import { copyText } from '../utils/ClipboardUtil';
import { PendingWebDownload } from '../model/Types';
import { SessionDataFlow, SessionStage, TransferSession, isTerminalStage } from '../model/transfer/TransferSession';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ShareLinkViewModel', '分享链接页');

// 待确认 Web 下载请求类型经 ViewModel 出口（View 层不直接 import model/Types）。
export type { PendingWebDownload } from '../model/Types';

/**
 * ShareLinkViewModel
 * 分享链接页的视图模型。持有 UI 状态 shareUrl，暴露加载/复制/停止命令。
 * 扩展：管理 Web 下载请求确认（pendingDownloads 列表 + 接受/拒绝操作）。
 *
 * 反模式合规：
 * - 不依赖 UI 组件（反模式 2 ✓）
 * - 不持有 UIContext / PromptAction（反模式 2 ✓）
 * - copyShareUrl 返回 boolean，Toast 显示由 Page 决定（VM 不触达 UI 反馈）
 */
@ObservedV2
export class ShareLinkViewModel {
  @Trace public shareUrl: string = '';
  // 加密传输开启时网页分享使用自签名证书的 HTTPS 连接，页面据此在顶部显示浏览器拦截提示
  @Trace public showHttpsHint: boolean = false;
  // LocalSend 总开关禁用态镜像：关闭时网页分享不可用，页面据此改渲染中性禁用提示（不展示失效地址）
  @Trace public localSendDisabled: boolean = false;
  // ── Web 下载请求确认 ──
  @Trace public pendingDownloads: Array<PendingWebDownload> = [];
  @Trace public hasActiveDownloads: boolean = false;
  // ── 网页接收：待确认上传请求与未终结入站会话判定 ──
  // 网页来源（浏览器上传）的待确认入站会话投影，作为接收页请求列表数据源
  @Trace public pendingUploads: Array<PendingWebDownload> = [];
  // 是否存在未终结的入站会话（退出确认判定，覆盖全部入站来源）
  @Trace public hasInboundSessions: boolean = false;
  private refreshCallback: (() => void) | undefined = undefined;
  // 会话注册表订阅回调（接收模式页面存活期间有效）
  private sessionsCallback: (() => void) | undefined = undefined;
  // 网页接收启动进行中标志：启动中重复进入不重复重启上传服务
  private startingReceive: boolean = false;

  /**
   * 启动网页接收：先开启浏览器上传服务，再加载分享信息（地址由服务启动后方可取得）。
   * 与网页发送（先建链接再展示）对称。含进行中幂等保护；启动失败按「地址不可用」
   * 降级（保持空地址），不向页面抛异常。
   */
  async startWebReceive(shareUrlFromParams?: string): Promise<void> {
    if (this.startingReceive) {
      return;
    }
    this.startingReceive = true;
    // 接收页的请求列表与退出判定均取自统一会话注册表，先订阅再启动服务
    this.subscribeToSessions();
    try {
      await startWebUpload();
    } catch (_e) {
      // 启动失败：地址保持不可用，交由页面降级展示
    } finally {
      this.startingReceive = false;
    }
    this.loadShareInfo(shareUrlFromParams);
  }

  /**
   * 订阅统一会话注册表：接收页随会话变化刷新待确认上传列表与退出判定。
   * 幂等：重复调用不重复订阅。
   */
  subscribeToSessions(): void {
    if (this.sessionsCallback !== undefined) {
      return;
    }
    this.sessionsCallback = () => {
      this.refreshInboundFromRegistry();
    };
    subscribeSessions(this.sessionsCallback);
    // 首次同步状态
    this.refreshInboundFromRegistry();
  }

  /**
   * 取消会话注册表订阅。必须在 Page 的 aboutToDisappear 中调用。
   */
  unsubscribeFromSessions(): void {
    if (this.sessionsCallback !== undefined) {
      unsubscribeSessions(this.sessionsCallback);
      this.sessionsCallback = undefined;
    }
  }

  /**
   * 从统一会话注册表同步：网页来源待确认上传请求列表与未终结入站会话判定。
   * 列表仅覆盖「方向为接收、待确认、对端设备类型为 web」的会话；
   * 退出判定覆盖全部未终结的入站会话（不限于网页来源）。
   */
  private refreshInboundFromRegistry(): void {
    let uploads: Array<PendingWebDownload> = [];
    let hasInbound: boolean = false;
    let all: Array<TransferSession> = querySessions();
    for (let i = 0; i < all.length; i++) {
      let session = all[i];
      if (session.dataFlow !== SessionDataFlow.inbound || isTerminalStage(session.stage)) {
        continue;
      }
      hasInbound = true;
      if (session.stage === SessionStage.awaitingConfirmation && session.peer.deviceType === 'web') {
        // 对端名称已在摄入层归一化为客户端 IP，此处直接采用（缺失时回退 ip 字段）
        let ip: string = session.peer.displayName.length > 0 ? session.peer.displayName :
          (session.peer.ip ?? '');
        uploads.push({ sessionId: session.id, ip: ip, timestamp: session.startedAt });
      }
    }
    this.pendingUploads = uploads;
    this.hasInboundSessions = hasInbound;
  }

  /**
   * 接受指定网页来源上传请求：经统一会话注册表执行，与任务中心同一事实源。
   */
  acceptUpload(sessionId: string): void {
    confirmSession(sessionId);
    this.refreshInboundFromRegistry();
  }

  /**
   * 拒绝指定网页来源上传请求：经统一会话注册表执行，与任务中心同一事实源。
   */
  declineUpload(sessionId: string): void {
    declineSession(sessionId);
    this.refreshInboundFromRegistry();
  }

  /**
   * 是否存在未终结的入站会话（待确认或进行中，覆盖全部入站来源）。
   * 用于接收页退出（返回/停止接收）前的确认判定。
   */
  hasActiveOrPendingInboundSessions(): boolean {
    return this.hasInboundSessions;
  }

  /**
   * 加载分享信息。优先用路由传入的 URL，否则从 AppService 取。
   * 必须在 Page 的 aboutToAppear 中调用。
   */
  loadShareInfo(shareUrlFromParams?: string): void {
    // 提示显隐与网页分享是否使用 HTTPS 同源：由全局加密开关派生，发送/接收两种模式一致
    this.showHttpsHint = getHttpsEnabled();
    if (shareUrlFromParams !== undefined && shareUrlFromParams.length > 0) {
      this.shareUrl = shareUrlFromParams;
    } else {
      this.shareUrl = getShareLink();
    }

    // 订阅仓库变化通知
    this.refreshCallback = () => {
      this.refreshFromRepository();
    };
    subscribe(this.refreshCallback);
    // 首次同步状态
    this.refreshFromRepository();
  }

  /**
   * 取消订阅仓库变化通知。必须在 Page 的 aboutToDisappear 中调用。
   */
  unsubscribeFromRepository(): void {
    if (this.refreshCallback !== undefined) {
      unsubscribe(this.refreshCallback);
      this.refreshCallback = undefined;
    }
  }

  /**
   * 从仓库同步最新状态到 @Trace 属性。
   */
  private refreshFromRepository(): void {
    // LocalSend 总开关状态经既有 changeBus 同步（开关 setter 已 notifyChange，无需新增订阅通道）
    let disabled: boolean = !getLocalSendEnabled();
    if (disabled !== this.localSendDisabled) {
      logger.info('LocalSend 总开关状态变化，网页分享禁用态=' + disabled);
    }
    this.localSendDisabled = disabled;
    this.pendingDownloads = getPendingWebDownloads();
    this.hasActiveDownloads = hasActiveWebDownloads();
  }

  /**
   * 接受指定会话的下载请求。
   */
  acceptRequest(sessionId: string): void {
    acceptWebDownloadRequest(sessionId);
    this.refreshFromRepository();
  }

  /**
   * 拒绝指定会话的下载请求。
   */
  declineRequest(sessionId: string): void {
    declineWebDownloadRequest(sessionId);
    this.refreshFromRepository();
  }

  /**
   * 拒绝所有待确认的下载请求。
   */
  declineAllRequests(): void {
    declineAllPendingWebDownloads();
    this.refreshFromRepository();
  }

  /**
   * 复制分享 URL 到剪贴板。返回是否成功（createData 未抛异常）。
   * Toast 反馈由 Page 根据返回值决定。
   */
  copyShareUrl(): boolean {
    return copyText(this.shareUrl);
  }

  /**
   * 停止分享链接。幂等：重复调用安全（原 Page 中 aboutToDisappear 和按钮 onClick 都会触发）。
   * 用于 Page 的 aboutToDisappear（被动停止）和"停止分享"按钮（主动停止）。
   */
  async stopShare(): Promise<void> {
    await stopShareLink();
  }
}
