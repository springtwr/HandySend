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
 * 单页双段：下载与上传是同一服务的两个方向，同页分别出示 `/` 下载地址
 * 与 `/upload` 上传地址；停止动作只作用于自己这一段，另一段继续可用。
 * 空服务可进：未启动时展示空态与两个启动入口，不强制先有内容。
 *
 * 进行中的传输由统一会话引擎呈现在任务页与详情页。
 * 关闭面板不停服务：服务由面板内的停止按钮显式关闭。
 */
@ComponentV2
export struct ShareLinkPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: ShareLinkViewModel = new ShareLinkViewModel();
  @Local private isNavigatingBack: boolean = false;
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
    if (params !== undefined && params['shareUrl'] !== undefined) {
      shareUrlFromParams = params['shareUrl'];
    }
    // 只加载状态，不自动启动服务：空态由页面内启动入口显式触发
    this.viewModel.loadShareInfo(shareUrlFromParams);
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

  // 服务是否在运行（任一段开着都算运行）。
  private isServiceRunning(): boolean {
    return this.viewModel.shareUrl.length > 0 &&
      (this.viewModel.hasDownload || this.viewModel.uploadEnabled);
  }

  /** 回到发送页（空态下引导用户先选文件）。 */
  private backToSend(): void {
    if (this.isNavigatingBack) {
      return;
    }
    this.isNavigatingBack = true;
    this.pathStack.pop();
  }

  /** 开启接收：上传入口未开时打开（幂等）。 */
  private async startReceiving(): Promise<void> {
    await this.viewModel.startWebReceive();
  }

  /**
   * 加密传输提示条（纯文字、无可点击元素）。
   * 说明的是浏览器下载被安全策略拦截的情形，故只在下载段展示。
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

  /** 分区标题（下载段 / 上传段）。 */
  @Builder
  sectionTitle(label: Resource) {
    Text(label)
      .fontSize(DesignTokens.font.subtitleM)
      .fontColor($r('app.color.text_primary'))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .margin({ bottom: DesignTokens.space.sm })
  }

  /** 段内停止按钮（红色胶囊，通栏）。 */
  @Builder
  stopButton(label: Resource, action: () => void, id: string) {
    Button(label)
      .width('100%')
      .height(DesignTokens.size.thumbSm)
      .fontSize(DesignTokens.font.subtitleM)
      .fontColor($r('app.color.text_on_color'))
      .backgroundColor($r('app.color.stop_red'))
      .borderRadius(DesignTokens.radius.max)
      .onClick(action)
      .id(id)
  }

  /** 段内主操作按钮（蓝色胶囊，通栏）。 */
  @Builder
  primaryButton(label: Resource, action: () => void, id: string) {
    Button(label)
      .width('100%')
      .height(DesignTokens.size.thumbSm)
      .fontSize(DesignTokens.font.subtitleM)
      .fontColor($r('app.color.text_on_color'))
      .backgroundColor($r('app.color.accent_blue'))
      .borderRadius(DesignTokens.radius.max)
      .onClick(action)
      .id(id)
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
              } else if (!this.isServiceRunning()) {
                // 服务未启动：空态 + 两个显式启动入口，不替用户做决定
                EmptyState({
                  mainText: $r('app.string.web_access_unavailable'),
                  useCard: true
                })
                Column({ space: DesignTokens.space.sm }) {
                  this.primaryButton($r('app.string.web_access_start_receive'),
                    () => {
                      this.startReceiving();
                    }, 'web_access_start_receive_btn')
                  this.stopButton($r('app.string.web_access_pick_first'),
                    () => {
                      this.backToSend();
                    }, 'web_access_pick_first_btn')
                }
                .width('100%')
              } else {
                // ── 下载段 ──
                this.sectionTitle($r('app.string.web_access_download_title'))
                if (this.viewModel.hasDownload) {
                  // 证书提示置于地址区之前：先说明可能下载不了的原因，再看地址
                  if (this.viewModel.showHttpsHint) {
                    this.buildHttpsHint()
                  }

                  WebAccessEntryCard({
                    url: this.viewModel.shareUrl,
                    qrSize: this.qrSize(),
                    onCopy: (url: string) => {
                      this.copyAddress(url);
                    }
                  })

                  this.autoAcceptRow()

                  this.stopButton($r('app.string.stop_share'),
                    () => {
                      this.viewModel.stopSharingFiles();
                    }, 'web_access_stop_share_btn')
                } else {
                  EmptyState({
                    mainText: $r('app.string.web_access_no_download'),
                    useCard: true
                  })
                }

                // ── 上传段 ──
                this.sectionTitle($r('app.string.web_access_upload_title'))
                if (this.viewModel.uploadEnabled) {
                  WebAccessEntryCard({
                    url: this.viewModel.uploadUrl,
                    qrSize: this.qrSize(),
                    onCopy: (url: string) => {
                      this.copyAddress(url);
                    }
                  })

                  this.stopButton($r('app.string.stop_receive'),
                    () => {
                      this.viewModel.stopReceivingFiles();
                    }, 'web_access_stop_receive_btn')
                } else {
                  Column({ space: DesignTokens.space.sm }) {
                    EmptyState({
                      mainText: $r('app.string.web_access_upload_off'),
                      useCard: false
                    })
                    this.primaryButton($r('app.string.web_access_start_receive'),
                      () => {
                        this.startReceiving();
                      }, 'web_access_start_receive_btn')
                  }
                  .width('100%')
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
      title: $r('app.string.web_access_title')
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
