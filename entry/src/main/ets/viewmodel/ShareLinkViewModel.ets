import {
  getShareLink,
  getWebHttpsEnabled,
  stopShareLink,
  ensureWebUpload,
  unmountShare,
  disableWebUpload,
  setWebDownloadAutoAccept,
  isWebDownloadAutoAccept,
  getSharedFileCount,
  isWebUploadEnabled,
  subscribe,
  unsubscribe,
  getWebSendAllowed,
  setWebSendAllowed,
  applyWebSendAllowed,
  setWebReceiveAllowed,
  getWebReceiveAllowed,
  getWebAddresses,
  getSelectedWebAddress,
  selectWebDisplayAddress,
  getWebPort,
  getWebActualPort,
  isWebPortFallback
} from '../service/AppService';
import { WebAddress } from '../model/WebAddress';
import { copyText } from '../utils/ClipboardUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ShareLinkViewModel', '网页接入');

/**
 * ShareLinkViewModel
 * 网页接入面板的视图模型：持有服务地址与本次挂载的授权状态，
 * 暴露加载 / 复制 / 启停 / 授权命令。
 *
 * 面板不承载任务进度——进行中的网页传输由统一会话引擎投影到任务页与详情页，
 * 这里只管理「服务是否开放、挂了哪些文件、是否允许直接下载」。
 *
 * 反模式合规：
 * - 不依赖 UI 组件、不持有 UIContext（Toast 由 Page 依返回值决定）
 */
@ObservedV2
export class ShareLinkViewModel {
  @Trace public shareUrl: string = '';
  // 加密传输开启时网页分享使用自签名证书的 HTTPS 连接，页面据此在顶部显示浏览器拦截提示
  @Trace public showHttpsHint: boolean = false;
  // 网页方向允许开关镜像：关闭时对应方向面板不可用，页面据此改渲染中性禁用提示
  @Trace public sendDisabled: boolean = false
  @Trace public receiveDisabled: boolean = false;
  // 本次挂载是否允许浏览器直接下载（一次外发授权，不跨分享保留）
  @Trace public autoAcceptDownload: boolean = false;
  // 当前挂载的分享文件数：为 0 时顶部给出无文件警告（地址与二维码仍展示）
  @Trace public sharedFileCount: number = 0;
  // 浏览器上传入口是否已开放：决定面板是否出示上传入口
  @Trace public uploadEnabled: boolean = false;
  // 可展示的网页地址（多地址时页面出现选择器）
  @Trace public webAddresses: Array<WebAddress> = [];
  // 当前展示的地址 IP（空串时取排序后的第一个）
  @Trace public selectedAddressIp: string = '';
  // 端口回退状态：实际端口与设置端口不一致时顶部提示
  @Trace public webPortFallback: boolean = false;
  @Trace public webPreferredPort: number = 0;
  @Trace public webActualPort: number = 0;
  private refreshCallback: (() => void) | undefined = undefined;
  // 上传服务启动进行中标志：启动中重复进入不重复重启
  private startingReceive: boolean = false;

  /** 浏览器上传页地址：与下载地址同一单页（按 caps 条件渲染两段）。 */
  get uploadUrl(): string {
    return this.shareUrl;
  }

  /** 是否挂了可下载的文件（决定顶部是否给出无文件警告）。 */
  get hasDownload(): boolean {
    return this.sharedFileCount > 0;
  }

  /**
   * 进入网页接收：确保浏览器上传入口开放。
   * 服务已在运行时不会重建服务器，避免打断进行中的传输。
   */
  async startWebReceive(): Promise<void> {
    // 开启接收即写允许开关：与设置页双向同步
    setWebReceiveAllowed(true);
    if (this.startingReceive) {
      return;
    }
    this.startingReceive = true;
    try {
      await ensureWebUpload();
    } catch (_e) {
      // 启动失败：地址保持不可用，交由页面降级展示
    } finally {
      this.startingReceive = false;
    }
    this.loadShareInfo();
  }

  /**
   * 页面进入时确保发送方向服务已启动（不修改允许开关，仅消费开关状态）。
   * 开关已开而服务未起（如启动恢复尚未完成）时补一次启动；开关关闭时不动作。
   */
  ensureSendService(): void {
    if (this.sendDisabled) {
      return;
    }
    applyWebSendAllowed(true);
  }

  /**
   * 页面进入时确保接收方向服务已启动（不修改允许开关，仅消费开关状态）。
   */
  async ensureReceiveService(): Promise<void> {
    if (this.receiveDisabled) {
      return;
    }
    try {
      await ensureWebUpload();
    } catch (_e) {
      // 启动失败：地址保持不可用，交由页面降级展示
    }
  }

  /**
   * 加载网页接入信息。地址以仓库为唯一事实源。
   * 必须在 Page 的 aboutToAppear 中调用。
   */
  loadShareInfo(): void {
    // 提示显隐与网页独立加密开关同源
    this.showHttpsHint = getWebHttpsEnabled();
    this.shareUrl = getShareLink();
    if (this.refreshCallback === undefined) {
      this.refreshCallback = () => {
        this.refreshFromRepository();
      };
      subscribe(this.refreshCallback);
    }
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
    // 网页方向允许开关经既有 changeBus 同步（开关 setter 已 notifyChange）
    let sendDisabled: boolean = !getWebSendAllowed();
    if (sendDisabled !== this.sendDisabled) {
      logger.info('网页发送允许开关变化，发送面板禁用态=' + sendDisabled);
    }
    this.sendDisabled = sendDisabled;
    let receiveDisabled: boolean = !getWebReceiveAllowed();
    if (receiveDisabled !== this.receiveDisabled) {
      logger.info('网页接收允许开关变化，接收面板禁用态=' + receiveDisabled);
    }
    this.receiveDisabled = receiveDisabled;
    this.autoAcceptDownload = isWebDownloadAutoAccept();
    this.sharedFileCount = getSharedFileCount();
    this.uploadEnabled = isWebUploadEnabled();
    // 地址与网卡选择同步：服务停止后地址清空，网卡列表仍可用于下次进入
    this.webAddresses = getWebAddresses();
    let selected: WebAddress | undefined = getSelectedWebAddress();
    this.selectedAddressIp = selected !== undefined ? selected.ip : '';
    this.webPreferredPort = getWebPort();
    this.webActualPort = getWebActualPort();
    this.webPortFallback = isWebPortFallback();
    this.shareUrl = getShareLink();
  }

  /** 切换面板展示的地址；服务不重启，仅更新二维码/地址。 */
  selectWebAddress(ip: string): void {
    selectWebDisplayAddress(ip);
  }

  /**
   * 切换本次挂载的直接下载授权。仅影响当前分享，停止分享后失效。
   */
  setAutoAcceptDownload(enabled: boolean): void {
    setWebDownloadAutoAccept(enabled);
    this.autoAcceptDownload = enabled;
  }

  /**
   * 复制地址到剪贴板。不传参时复制下载地址。
   * 返回是否成功，Toast 反馈由 Page 决定。
   */
  copyShareUrl(url?: string): boolean {
    let target: string = url !== undefined && url.length > 0 ? url : this.shareUrl;
    return target.length > 0 ? copyText(target) : false;
  }

  /**
   * 停止网页服务。幂等：重复调用安全。
   */
  async stopShare(): Promise<void> {
    await stopShareLink();
  }

  /**
   * 打开发送方向允许开关并确保最小服务已运行（与设置页双向同步）。
   * 挂载仍需经发送页选文件后进入。
   */
  enableSendDirection(): void {
    setWebSendAllowed(true);
    applyWebSendAllowed(true);
  }

  /**
   * 关闭网页发送：撤下已挂载的文件，并写发送允许开关（与设置页双向同步）。
   * 网页接收仍开启时服务继续运行（上传入口保留），否则随之完全停止。
   */
  async stopSharingFiles(): Promise<void> {
    setWebSendAllowed(false);
    if (getWebReceiveAllowed()) {
      await unmountShare();
    } else {
      await stopShareLink();
    }
  }

  /**
   * 关闭网页接收：关闭浏览器上传入口，并写接收允许开关（与设置页双向同步）。
   * 网页发送仍开启时服务继续运行（地址与二维码保留），否则随之完全停止。
   */
  async stopReceivingFiles(): Promise<void> {
    setWebReceiveAllowed(false);
    if (getWebSendAllowed()) {
      await disableWebUpload();
    } else {
      await stopShareLink();
    }
  }
}
