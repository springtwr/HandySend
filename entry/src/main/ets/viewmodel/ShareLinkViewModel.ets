import {
  getShareLink,
  getHttpsEnabled,
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
  getLocalSendEnabled
} from '../service/AppService';
import { copyText } from '../utils/ClipboardUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ShareLinkViewModel', '网页接入');

/**
 * ShareLinkViewModel
 * 网页接入面板的视图模型：持有服务地址与本次挂载的授权状态，
 * 暴露加载 / 复制 / 授权 / 停止命令。
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
  // LocalSend 总开关禁用态镜像：关闭时网页接入不可用，页面据此改渲染中性禁用提示
  @Trace public localSendDisabled: boolean = false;
  // 本次挂载是否允许浏览器直接下载（一次外发授权，不跨分享保留）
  @Trace public autoAcceptDownload: boolean = false;
  // 当前挂载的分享文件数：为 0 时面板不出示下载入口
  @Trace public sharedFileCount: number = 0;
  // 浏览器上传入口是否已开放：决定面板是否出示上传入口
  @Trace public uploadEnabled: boolean = false;
  private refreshCallback: (() => void) | undefined = undefined;
  // 上传服务启动进行中标志：启动中重复进入不重复重启
  private startingReceive: boolean = false;

  /** 浏览器上传页地址：与下载页同端口，独立路径。 */
  get uploadUrl(): string {
    return this.shareUrl.length > 0 ? this.shareUrl + '/upload' : '';
  }

  /** 是否挂了可下载的文件（决定面板是否出示下载入口）。 */
  get hasDownload(): boolean {
    return this.sharedFileCount > 0;
  }

  /**
   * 进入网页接收：确保浏览器上传入口开放并加载服务地址。
   * 服务已在运行时不会重建服务器，避免打断进行中的传输。
   */
  async startWebReceive(shareUrlFromParams?: string): Promise<void> {
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
    this.loadShareInfo(shareUrlFromParams);
  }

  /**
   * 加载网页接入信息。优先用路由传入的 URL，否则从 AppService 取。
   * 必须在 Page 的 aboutToAppear 中调用。
   */
  loadShareInfo(shareUrlFromParams?: string): void {
    // 提示显隐与网页分享是否使用 HTTPS 同源：由全局加密开关派生
    this.showHttpsHint = getHttpsEnabled();
    if (shareUrlFromParams !== undefined && shareUrlFromParams.length > 0) {
      this.shareUrl = shareUrlFromParams;
    } else {
      this.shareUrl = getShareLink();
    }
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
    // LocalSend 总开关状态经既有 changeBus 同步（开关 setter 已 notifyChange）
    let disabled: boolean = !getLocalSendEnabled();
    if (disabled !== this.localSendDisabled) {
      logger.info('LocalSend 总开关状态变化，网页接入禁用态=' + disabled);
    }
    this.localSendDisabled = disabled;
    this.autoAcceptDownload = isWebDownloadAutoAccept();
    this.sharedFileCount = getSharedFileCount();
    this.uploadEnabled = isWebUploadEnabled();
    let current: string = getShareLink();
    if (current.length > 0) {
      this.shareUrl = current;
    }
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
   * 停止本机的网页分享：撤下已挂载的文件。
   * 浏览器上传入口若仍开放则服务继续运行，否则随之完全停止。
   */
  async stopSharingFiles(): Promise<void> {
    if (this.uploadEnabled) {
      await unmountShare();
    } else {
      await stopShareLink();
    }
  }

  /**
   * 停止接收：关闭浏览器上传入口。
   * 已挂载的分享文件若仍存在则服务继续运行，否则随之完全停止。
   */
  async stopReceivingFiles(): Promise<void> {
    if (this.hasDownload) {
      await disableWebUpload();
    } else {
      await stopShareLink();
    }
  }
}
