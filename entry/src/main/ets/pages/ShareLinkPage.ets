import { uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildImmersiveTitleBar } from '../common/ImmersiveTitleBar';
import { ShareLinkViewModel } from '../viewmodel/ShareLinkViewModel';
import { WebAccessEntryCard } from '../views/WebAccessEntryCard';
import { DesignTokens } from '../common/DesignTokens';
import { EmptyState } from '../components/EmptyState';
import { getPageContentMaxWidth, getPageMargin, WidthBreakpointType } from '../common/Breakpoints';

// 二维码边长（vp）：sm/md 取设计令牌基准，lg/xl 逐档放大，避免大屏上相对过小
const QR_SIZE_BY_BREAKPOINT: WidthBreakpointType<number> =
  new WidthBreakpointType<number>(DesignTokens.size.qrCodeSize, 240, 280, 320)

/**
 * ShareLinkPage — 网页服务面板（MVVM：View 只做组装与渲染）。
 *
 * 发送与接收是两个入口、两个页面：发送要求先有内容（由发送页挂载后进入），
 * 接收即开即用，两者的前置条件不同，合并会让空态失去语义。
 * 二者共用同一个服务与同一个端口，分别占用 `/` 与 `/upload`；
 * 停止动作只作用于自己这一侧，另一侧的入口继续可用。
 *
 * 进行中的传输由统一会话引擎呈现在任务页与详情页。
 * 关闭面板不停服务：服务由面板上的停止按钮显式关闭。
 */
@ComponentV2
export struct ShareLinkPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: ShareLinkViewModel = new ShareLinkViewModel();
  @Local private isNavigatingBack: boolean = false;
  // 是否为接收模式：路由参数 mode='receive' 时成立
  @Local private isReceiveMode: boolean = false;
  // 路由参数（经 ShareLinkPageBuilder 传入，结构与旧 pushUrl params 一致）
  @Param pageParam: Object = new Object()
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()
  // 内容滚动控制器：绑定到子页面容器以驱动标题栏滚动模糊
  private scroller: Scroller = new Scroller()

  onBackPress(): boolean {
    if (this.isNavigatingBack) {
      return true;
    }
    // 收起面板不停服务：服务由停止按钮显式关闭
    this.isNavigatingBack = true;
    this.pathStack.pop();
    return true;
  }

  aboutToAppear(): void {
    let params: Record<string, string> = this.pageParam as Record<string, string>;
    let shareUrlFromParams: string | undefined = undefined;
    if (params !== undefined) {
      if (params['shareUrl'] !== undefined) {
        shareUrlFromParams = params['shareUrl'];
      }
      if (params['mode'] === 'receive') {
        this.isReceiveMode = true;
      }
    }
    if (this.isReceiveMode) {
      // 网页接收：进入即开放上传入口，服务已在运行时不会重建
      this.viewModel.startWebReceive(shareUrlFromParams);
    } else {
      this.viewModel.loadShareInfo(shareUrlFromParams);
    }
  }

  aboutToDisappear(): void {
    // 只退订：服务在面板关闭后继续运行
    this.viewModel.unsubscribeFromRepository();
  }

  // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    return getPageContentMaxWidth(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType);
  }

  /** 当前断点下的二维码边长。 */
  private qrSize(): number {
    return QR_SIZE_BY_BREAKPOINT.getValue(this.breakpointInfo.widthBreakpoint);
  }

  /** 本页展示的服务地址：接收为上传入口，发送为下载入口。 */
  private pageUrl(): string {
    return this.isReceiveMode ? this.viewModel.uploadUrl : this.viewModel.shareUrl;
  }

  /** 复制地址：成功后给出轻提示。 */
  private copyAddress(url: string): void {
    if (!this.viewModel.copyShareUrl(url)) {
      return;
    }
    try {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.copy_success'), duration: 1500 });
    } catch (_e) {
      // 提示展示失败不影响复制结果
    }
  }

  /** 停止本侧服务：发送侧撤下文件，接收侧关闭上传；另一侧不受影响。 */
  private async stopCurrentSide(): Promise<void> {
    if (this.isNavigatingBack) {
      return;
    }
    this.isNavigatingBack = true;
    if (this.isReceiveMode) {
      await this.viewModel.stopReceivingFiles();
    } else {
      await this.viewModel.stopSharingFiles();
    }
    this.pathStack.pop();
  }

  /**
   * 加密传输提示条（纯文字、无可点击元素）。
   * 说明的是浏览器下载被安全策略拦截的情形，故只在发送页展示。
   */
  @Builder
  buildHttpsHint() {
    Text($r('app.string.web_share_https_hint'))
      .fontSize(DesignTokens.font.bodyS)
      .fontColor($r('app.color.warning_orange'))
      .width('100%')
      .padding(DesignTokens.space.md)
      .backgroundColor($r('app.color.warning_bg'))
      .borderRadius(DesignTokens.radius.md)
  }

  /** 本次挂载的下载免确认开关：只作用于浏览器下载。 */
  @Builder
  autoAcceptRow() {
    Column({ space: DesignTokens.space.xxs }) {
      Row() {
        Text($r('app.string.web_access_auto_accept_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.autoAcceptDownload })
          .onChange((isOn: boolean) => {
            this.viewModel.setAutoAcceptDownload(isOn);
          })
          .id('web_access_auto_accept_toggle')
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.web_access_auto_accept_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .width('100%')
    // 与加密提示条的内边距一致，使两处文字左边缘对齐
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
  }

  build() {
    HdsNavDestination() {
      Row() {
        Column() {
          Scroll(this.scroller) {
            Column({ space: DesignTokens.space.md }) {
              if (this.viewModel.localSendDisabled) {
                // 协议禁用：不展示失效地址与二维码，改渲染中性禁用提示
                EmptyState({
                  mainText: $r('app.string.share_link_disabled_hint'),
                  useCard: true
                })
              } else if (this.pageUrl().length === 0) {
                // 服务未运行（启动失败或已停止）：不展示空地址
                EmptyState({
                  mainText: $r('app.string.web_access_unavailable'),
                  useCard: true
                })
              } else {
                // 证书提示置于地址区之前：先说明可能下载不了的原因，再看地址
                if (!this.isReceiveMode && this.viewModel.showHttpsHint) {
                  this.buildHttpsHint()
                }

                WebAccessEntryCard({
                  url: this.pageUrl(),
                  qrSize: this.qrSize(),
                  onCopy: (url: string) => {
                    this.copyAddress(url);
                  }
                })

                if (!this.isReceiveMode) {
                  this.autoAcceptRow()
                }
              }
            }
            .padding({
              left: getPageMargin(this.breakpointInfo.widthBreakpoint),
              right: getPageMargin(this.breakpointInfo.widthBreakpoint),
              top: DesignTokens.space.md,
              bottom: DesignTokens.space.md
            })
          }
          .layoutWeight(1)
          // 滚动容器不裁剪：滚动中的内容可绘制到标题栏区域内，使毛玻璃背板有内容可透出
          .clip(false)
          // 内容不足一屏时垂直居中，使二维码落在页面中部而非贴住标题栏
          .align(Alignment.Center)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

          // 停止本侧服务：发送侧停分享、接收侧停接收。
          // 容器承担与滚动内容相同的页边距，使按钮宽度与地址、开关、提示条严格对齐
          Column() {
            Button(this.isReceiveMode ? $r('app.string.stop_receive') : $r('app.string.stop_share'))
              .width('100%')
              .height(DesignTokens.size.thumbSm)
              .fontSize(DesignTokens.font.subtitleM)
              .fontColor($r('app.color.text_on_color'))
              .backgroundColor($r('app.color.stop_red'))
              .borderRadius(DesignTokens.radius.max)
              .onClick(async () => {
                await this.stopCurrentSide();
              })
              .id('web_access_stop_btn')
          }
          .width('100%')
          .padding({
            left: getPageMargin(this.breakpointInfo.widthBreakpoint),
            right: getPageMargin(this.breakpointInfo.widthBreakpoint)
          })
          .margin({ top: DesignTokens.space.lg, bottom: DesignTokens.space.lg })
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: this.getContentMaxWidth() })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      // 内容从顶部排列，避免内容不满一屏时被交叉轴默认居中
      .alignItems(VerticalAlign.Top)
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    // 子页面容器背景覆盖至标题栏区域：无内容经过时标题栏底色与页面背景一致，不露出系统默认底色
    .backgroundColor($r('app.color.page_background'))
    .titleBar(buildImmersiveTitleBar({
      title: this.isReceiveMode ? $r('app.string.receive_link_title') : $r('app.string.share_link_title')
    }))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onBackPressed(() => {
      return this.onBackPress();
    })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}

// 路由表引用：ShareLinkPageBuilder(name, param)
@Builder
export function ShareLinkPageBuilder(name: string, param: Object) {
  ShareLinkPage({ pageParam: param })
}
