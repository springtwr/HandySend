import { getShareLink, stopShareLink, getSharePort } from '../service/AppService';
import { preferencesUtil, KEY_PORT } from '../utils/PreferencesUtil';
import { copyText } from '../utils/ClipboardUtil';

/**
 * ShareLinkViewModel
 * 分享链接页的视图模型。持有 UI 状态 shareUrl，暴露加载/复制/停止命令。
 *
 * 反模式合规：
 * - 不依赖 UI 组件（反模式 2 ✓）
 * - 不持有 UIContext / PromptAction（反模式 2 ✓）
 * - V1 装饰器配套（@Observed，反模式 3 ✓）
 * - copyShareUrl 返回 boolean，Toast 显示由 Page 决定（VM 不触达 UI 反馈）
 *
 * 过渡期：VM 直接调 AppService.getShareLink/stopShareLink/getSharePort 和 preferencesUtil.getNumber
 * （getSharePort 端口解析 + 兜底逻辑）。待 AppService 整改 + PreferencesRepo 扩展时统一迁出。
 *
 * effectivePort 字段：原 Page 中的 dead state（build 未引用），按 AGENTS.md "不删改动前已存在的死代码"
 * 原则，VM 内部保留端口解析逻辑以维持行为不变。
 */
@Observed
export class ShareLinkViewModel {
  public shareUrl: string = '';
  // 解析后的端口（native > 0 用 native，否则回退到 preferences）。当前未在 View 中渲染，保留以兼容原行为。
  public effectivePort: number = 0;

  /**
   * 加载分享信息。优先用路由传入的 URL，否则从 AppService 取。
   * 端口解析：native > 0 用 native，否则回退到 preferencesUtil。
   * 必须在 Page 的 aboutToAppear 中调用。
   */
  loadShareInfo(shareUrlFromParams?: string): void {
    if (shareUrlFromParams !== undefined && shareUrlFromParams.length > 0) {
      this.shareUrl = shareUrlFromParams;
    } else {
      this.shareUrl = getShareLink();
    }

    let nativePort = getSharePort();
    if (nativePort > 0) {
      this.effectivePort = nativePort;
    } else {
      this.effectivePort = preferencesUtil.getNumber(KEY_PORT, 53317);
    }
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
