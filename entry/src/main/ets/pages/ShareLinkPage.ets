import { uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildImmersiveTitleBar } from '../common/ImmersiveTitleBar';
import { ShareLinkViewModel } from '../viewmodel/ShareLinkViewModel';
import { WebDownloadRequestCard } from '../views/WebDownloadRequestCard';
import { DesignTokens } from '../common/DesignTokens';
import { EmptyState } from '../components/EmptyState';
import { getPageContentMaxWidth, getPageMargin } from '../common/Breakpoints';
import { PendingWebDownload } from '../model/Types';

/**
 * ShareLinkPage — 分享链接页（MVVM：View 只做组装与渲染）。
 * 通过路由参数 mode='receive' 区分网页接收模式（标题/图标/文案切换）。
 */
@ComponentV2
export struct ShareLinkPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: ShareLinkViewModel = new ShareLinkViewModel();
  @Local private isNavigatingBack: boolean = false;
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
    // 存在未终结入站会话（接收模式）或活跃下载（发送模式）时先弹确认
    if (this.shouldConfirmExit()) {
      this.showExitConfirmDialog();
      return true;
    }
    this.isNavigatingBack = true;
    this.pathStack.pop();
    return true;
  }

  /** 退出前是否需要确认：接收模式按未终结入站会话、发送模式按活跃下载。 */
  private shouldConfirmExit(): boolean {
    return this.isReceiveMode ? this.viewModel.hasActiveOrPendingInboundSessions() :
      this.viewModel.hasActiveDownloads;
  }

  /** 弹出退出确认：取消则停留页面（上传服务继续运行），确认则收尾后返回。 */
  private showExitConfirmDialog(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.web_download_exit_confirm_title'),
      message: $r('app.string.web_download_exit_confirm_message'),
      primaryButton: {
        value: $r('app.string.dialog_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.dialog_confirm'),
        action: () => {
          this.finishExit();
        }
      }
    });
  }

  /** 确认退出：发送模式先拒绝全部待确认下载，随后返回（服务在页面销毁时停止）。 */
  private finishExit(): void {
    if (!this.isReceiveMode) {
      this.viewModel.declineAllRequests();
    }
    this.isNavigatingBack = true;
    this.pathStack.pop();
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
      // 网页接收：进入页面即启动浏览器上传服务并展示地址（启动中重复进入由 VM 幂等保护）
      this.viewModel.startWebReceive(shareUrlFromParams);
    } else {
      this.viewModel.loadShareInfo(shareUrlFromParams);
    }
  }

  aboutToDisappear(): void {
    this.viewModel.unsubscribeFromSessions();
    this.viewModel.unsubscribeFromRepository();
    this.viewModel.stopShare();
  }

  // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    return getPageContentMaxWidth(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType);
  }

  /**
   * 加密传输提示条（纯文字、无可点击元素）。
   * 网页分享在加密传输开启时使用自签名证书的 HTTPS 连接，部分浏览器扩展或安全策略
   * 可能拦截下载，故在页面顶部给出说明；关闭加密时不渲染。
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
      .margin({ bottom: DesignTokens.space.md })
  }

  build() {
    HdsNavDestination() {
      Row() {
        Column() {
          Scroll(this.scroller) {
            Column() {
              if (this.viewModel.localSendDisabled) {
                // 协议禁用：不展示失效地址/二维码/请求区，改渲染中性禁用提示
                EmptyState({
                  mainText: $r('app.string.share_link_disabled_hint'),
                  useCard: true
                })
              } else {
                // 加密传输提示条：置于滚动内容顶部（地址区之前），不遮挡地址/二维码/请求列表/停止按钮
                if (this.viewModel.showHttpsHint) {
                  this.buildHttpsHint()
                }

                // URL 展示
                Column() {
                  Text($r('app.string.share_link_address_label'))
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ bottom: DesignTokens.space.tiny })

                  Text(this.viewModel.shareUrl)
                    .fontSize(DesignTokens.font.subtitleM)
                    .fontColor($r('app.color.purple_text'))
                    .fontWeight(FontWeight.Medium)
                    .padding({
                      left: DesignTokens.space.md,
                      right: DesignTokens.space.md,
                      top: DesignTokens.space.sm,
                      bottom: DesignTokens.space.sm
                    })
                    .backgroundColor($r('app.color.purple_bg'))
                    .borderRadius(DesignTokens.radius.md)
                    .onClick(() => {
                      let ok = this.viewModel.copyShareUrl();
                      if (ok) {
                        this.getUIContext()
                          .getPromptAction()
                          .showToast({ message: $r('app.string.copy_success'), duration: 1500 });
                      }
                    })
                }
                .alignItems(HorizontalAlign.Center)

                // 二维码
                Column() {
                  Column() {
                    QRCode(this.viewModel.shareUrl)
                      .width(DesignTokens.size.qrCodeSize)
                      .height(DesignTokens.size.qrCodeSize)
                      .backgroundColor($r('app.color.qr_code_background'))
                  }
                  .width(DesignTokens.size.qrCodeSize + DesignTokens.space.md * 2)
                  .height(DesignTokens.size.qrCodeSize + DesignTokens.space.md * 2)
                  .backgroundColor($r('app.color.qr_code_background'))
                  .borderRadius(DesignTokens.radius.md)
                  .justifyContent(FlexAlign.Center)

                  Text($r('app.string.share_link_qr_hint'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_secondary'))
                    .margin({ top: DesignTokens.space.sm })
                }
                .margin({ top: DesignTokens.space.lg })
                .alignItems(HorizontalAlign.Center)

                // ── Web 传输请求列表 ──
                Column() {
                  Text(this.isReceiveMode ? $r('app.string.web_upload_request_title') :
                    $r('app.string.web_download_request_title'))
                    .fontSize(DesignTokens.font.subtitleM)
                    .fontColor($r('app.color.text_primary'))
                    .fontWeight(FontWeight.Medium)
                    .width('100%')
                    .margin({ bottom: DesignTokens.space.sm })

                  if ((this.isReceiveMode ? this.viewModel.pendingUploads :
                    this.viewModel.pendingDownloads).length > 0) {
                    Column({ space: DesignTokens.space.md }) {
                      Repeat<PendingWebDownload>(this.isReceiveMode ? this.viewModel.pendingUploads :
                        this.viewModel.pendingDownloads)
                        .each((item: RepeatItem<PendingWebDownload>) => {
                          WebDownloadRequestCard({
                            request: item.item,
                            isReceiveMode: this.isReceiveMode,
                            onAccept: (sessionId: string) => {
                              // 接收模式经统一会话注册表接受上传；发送模式经仓库接受下载
                              if (this.isReceiveMode) {
                                this.viewModel.acceptUpload(sessionId);
                              } else {
                                this.viewModel.acceptRequest(sessionId);
                              }
                            },
                            onDecline: (sessionId: string) => {
                              if (this.isReceiveMode) {
                                this.viewModel.declineUpload(sessionId);
                              } else {
                                this.viewModel.declineRequest(sessionId);
                              }
                            }
                          })
                        })
                        .key((item: PendingWebDownload) => item.sessionId)
                    }
                    .width('100%')
                  } else {
                    // 空态位于段落卡片内，不再套第二层卡片
                    EmptyState({
                      mainText: this.isReceiveMode ? $r('app.string.web_upload_no_requests') :
                        $r('app.string.web_download_no_requests')
                    })
                  }
                }
                .width('100%')
                .margin({ top: DesignTokens.space.lg })
                .padding(DesignTokens.space.md)
                .backgroundColor($r('app.color.card_background'))
                .borderRadius(DesignTokens.radius.md)
              }
            }
            .padding({
              left: getPageMargin(this.breakpointInfo.widthBreakpoint),
              right: getPageMargin(this.breakpointInfo.widthBreakpoint)
            })
          }
          .layoutWeight(1)
          // 滚动容器不裁剪：滚动中的内容可绘制到标题栏区域内，使毛玻璃背板有内容可透出
          .clip(false)
          // Scroll 设置高度限制后内容较少时默认居中，显式顶部对齐
          .align(Alignment.Top)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

          // 停止分享/接收按钮
          Button(this.isReceiveMode ? $r('app.string.stop_receive') : $r('app.string.stop_share'))
            .width('80%')
            .height(DesignTokens.size.thumbSm)
            .fontSize(DesignTokens.font.subtitleM)
            .fontColor($r('app.color.text_on_color'))
            .backgroundColor($r('app.color.stop_red'))
            .borderRadius(DesignTokens.radius.max)
            .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.lg })
            .onClick(async () => {
              if (this.isNavigatingBack) {
                return;
              }
              // 存在未终结入站会话（接收模式）或活跃下载（发送模式）时先弹确认；
              // 取消则停留页面且服务继续运行
              if (this.shouldConfirmExit()) {
                this.showExitConfirmDialog();
                return;
              }
              this.isNavigatingBack = true;
              if (!this.isReceiveMode) {
                // 发送模式：先拒绝所有待确认请求，再停止
                this.viewModel.declineAllRequests();
              }
              await this.viewModel.stopShare();
              this.pathStack.pop();
            })
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
