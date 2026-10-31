import {
  getShareLink,
  getWebHttpsEnabled,
  stopShareLink,
  ensureWebUpload,
  disableWebUpload,
  setWebUploadAutoAccept,
  isWebUploadAutoAccept,
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
  isWebPortFallback,
  getWebAccessCode
} from '../service/AppService';
import { WebAddress } from '../model/WebAddress';
import { copyText } from '../utils/ClipboardUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ShareLinkViewModel', '网页传输');

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
  // 网页传输总开关镜像：关闭时服务停止，页面据此显示开启入口
  @Trace public sendDisabled: boolean = false
  // 允许对方上传（子开关）与服务上传入口状态
  @Trace public uploadAllowed: boolean = false;
  // 本次挂载是否允许浏览器上传免确认
  @Trace public autoAcceptUpload: boolean = false;
  // 当前挂载的分享文件数：为 0 时顶部给出无文件警告（地址与二维码仍展示）
  @Trace public sharedFileCount: number = 0;
  // 刚开启网页传输时的短暂抑制：等发送页把暂存列表同步到服务后，再决定是否提示无文件
  @Trace public suppressNoFileWarning: boolean = false;
  // 浏览器上传入口是否已开放：决定面板是否出示上传入口
  @Trace public uploadEnabled: boolean = false;
  // 可展示的网页地址（多地址时页面出现选择器）
  @Trace public webAddresses: Array<WebAddress> = [];
  // 当前展示的地址 IP（空串时取排序后的第一个）
  @Trace public selectedAddressIp: string = '';
  // 本次分享的访问码：服务启动后生成，停止/重启即失效
  @Trace public accessCode: string = '';
  // 端口回退状态：实际端口与设置端口不一致时顶部提示
  @Trace public webPortFallback: boolean = false;
  @Trace public webPreferredPort: number = 0;
  @Trace public webActualPort: number = 0;
  private refreshCallback: (() => void) | undefined = undefined;
  // 上传服务启动进行中标志：启动中重复进入不重复重启
  private startingReceive: boolean = false;
  private noFileWarningTimer: number = -1;

  /** 是否挂了可下载的文件（决定顶部是否给出无文件警告）。 */
  get hasDownload(): boolean {
    return this.sharedFileCount > 0;
  }

  /** 是否展示「没有选择要发送的文件」警告：开启瞬间等待暂存列表同步完成，避免横幅闪一下。 */
  shouldShowNoFileWarning(): boolean {
    return !this.hasDownload && !this.suppressNoFileWarning;
  }

  /** 清除「刚开启」抑制；暂存文件挂载成功后立即结束抑制。 */
  private clearNoFileWarningSuppression(): void {
    this.suppressNoFileWarning = false;
    if (this.noFileWarningTimer >= 0) {
      clearTimeout(this.noFileWarningTimer);
      this.noFileWarningTimer = -1;
    }
  }

  /** 允许对方上传：仅当网页传输总开关开启时生效。 */
  async setUploadAllowed(enabled: boolean): Promise<void> {
    if (enabled && this.sendDisabled) {
      return;
    }
    setWebReceiveAllowed(enabled);
    if (!enabled) {
      await disableWebUpload();
      this.loadShareInfo();
      return;
    }
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
   * 页面进入时确保网页服务已启动（不修改总开关，仅消费开关状态）。
   */
  ensureWebService(): void {
    if (this.sendDisabled) {
      return;
    }
    applyWebSendAllowed(true);
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
    this.clearNoFileWarningSuppression();
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
      logger.debug('网页传输总开关变化，面板禁用态=' + sendDisabled);
    }
    this.sendDisabled = sendDisabled;
    this.uploadAllowed = getWebReceiveAllowed();
    this.autoAcceptUpload = isWebUploadAutoAccept();
    this.sharedFileCount = getSharedFileCount();
    if (this.sharedFileCount > 0) {
      this.clearNoFileWarningSuppression();
    }
    this.uploadEnabled = isWebUploadEnabled();
    // 地址与网卡选择同步：服务停止后地址清空，网卡列表仍可用于下次进入
    this.webAddresses = getWebAddresses();
    let selected: WebAddress | undefined = getSelectedWebAddress();
    this.selectedAddressIp = selected !== undefined ? selected.ip : '';
    this.webPreferredPort = getWebPort();
    this.webActualPort = getWebActualPort();
    this.webPortFallback = isWebPortFallback();
    this.shareUrl = getShareLink();
    this.accessCode = getWebAccessCode();
  }

  /** 切换面板展示的地址；服务不重启，仅更新二维码/地址。 */
  selectWebAddress(ip: string): void {
    selectWebDisplayAddress(ip);
  }

  /**
   * 切换本次挂载的上传免确认。仅影响当前分享，停止分享后失效。
   */
  setAutoAcceptUpload(enabled: boolean): void {
    setWebUploadAutoAccept(enabled);
    this.autoAcceptUpload = enabled;
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
   * 开启网页传输总开关并启动服务（与设置页双向同步）。
   */
  enableWebTransfer(): void {
    // 服务先起来、发送页再异步挂载暂存文件；期间先不显示无文件警告，避免横幅闪现
    this.suppressNoFileWarning = true;
    if (this.noFileWarningTimer >= 0) {
      clearTimeout(this.noFileWarningTimer);
    }
    this.noFileWarningTimer = setTimeout(() => {
      this.noFileWarningTimer = -1;
      this.suppressNoFileWarning = false;
    }, 2000);
    setWebSendAllowed(true);
    applyWebSendAllowed(true);
  }

  /**
   * 停止网页传输：关闭总开关并停止服务。
   * 有活跃网页会话时由 Page 先确认，再取消会话并调用本方法。
   */
  async stopWebTransfer(): Promise<void> {
    this.clearNoFileWarningSuppression();
    setWebSendAllowed(false);
    await stopShareLink();
  }
}
