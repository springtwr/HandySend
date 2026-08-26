import { ShareLinkViewModel } from '../viewmodel/ShareLinkViewModel';
import { WebDownloadRequestCard } from '../views/WebDownloadRequestCard';
import { DesignTokens } from '../common/DesignTokens';
import { PendingWebDownload } from '../model/Types';

/**
 * ShareLinkPage — 分享链接页（MVVM：View 只做组装与渲染）。
 * 通过路由参数 mode='receive' 区分网页接收模式（标题/图标/文案切换）。
 */
@ComponentV2
export struct ShareLinkPage {
  @Local viewModel: ShareLinkViewModel = new ShareLinkViewModel();
  @Local private isNavigatingBack: boolean = false;
  @Local private isReceiveMode: boolean = false;
  // 路由参数（经 ShareLinkPageBuilder 传入，结构与旧 pushUrl params 一致）
  @Param pageParam: Object = {}
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()

  onBackPress(): boolean {
    if (this.isNavigatingBack) {
      return true;
    }
    // 有活跃传输时弹出确认对话框
    if (this.viewModel.hasActiveDownloads) {
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
            // 确认退出：先拒绝所有待确认请求再返回
            this.viewModel.declineAllRequests();
            this.isNavigatingBack = true;
            this.pathStack.pop();
          }
        }
      });
      return true;
    }
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
    this.viewModel.loadShareInfo(shareUrlFromParams);
  }

  aboutToDisappear(): void {
    this.viewModel.unsubscribeFromRepository();
    this.viewModel.stopShare();
  }

  build() {
    NavDestination() {
      Column() {
        // 标题栏
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_backward'))
            .fontSize(DesignTokens.size.iconSm)
            .fontColor([$r('app.color.text_primary')])
            .responseRegion({
              x: -(DesignTokens.size.thumbSm - DesignTokens.size.iconSm) / 2,
              y: -(DesignTokens.size.thumbSm - DesignTokens.size.iconSm) / 2,
              width: DesignTokens.size.thumbSm,
              height: DesignTokens.size.thumbSm
            })
            .onClick(() => {
              if (this.isNavigatingBack) {
                return;
              }
              this.isNavigatingBack = true;
              this.pathStack.pop();
            })

        Text(this.isReceiveMode ? $r('app.string.receive_link_title') : $r('app.string.share_link_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)
      }
      .width('100%')
      .height(DesignTokens.size.headerHeight)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
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
            Text(this.isReceiveMode ? $r('app.string.web_upload_request_title') : $r('app.string.web_download_request_title'))
              .fontSize(DesignTokens.font.subtitleM)
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .margin({ bottom: DesignTokens.space.sm })

            if (this.viewModel.pendingDownloads.length > 0) {
              Column({ space: DesignTokens.space.md }) {
                Repeat<PendingWebDownload>(this.viewModel.pendingDownloads)
                  .each((item: RepeatItem<PendingWebDownload>) => {
                    WebDownloadRequestCard({
                      request: item.item,
                      isReceiveMode: this.isReceiveMode,
                      onAccept: (sessionId: string) => {
                        this.viewModel.acceptRequest(sessionId);
                      },
                      onDecline: (sessionId: string) => {
                        this.viewModel.declineRequest(sessionId);
                      }
                    })
                  })
                  .key((item: PendingWebDownload) => item.sessionId)
              }
              .width('100%')
            } else {
              Text(this.isReceiveMode ? $r('app.string.web_upload_no_requests') : $r('app.string.web_download_no_requests'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({
                  top: DesignTokens.space.md,
                  bottom: DesignTokens.space.md
                })
            }
          }
          .width('100%')
          .margin({ top: DesignTokens.space.lg })
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.md)
        }
        .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      }
      .layoutWeight(1)

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
          this.isNavigatingBack = true;
          // 先拒绝所有待确认请求，再停止
          this.viewModel.declineAllRequests();
          await this.viewModel.stopShare();
          this.pathStack.pop();
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(true)
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
