import { ShareLinkViewModel } from '../viewmodel/ShareLinkViewModel';
import { DesignTokens } from '../common/DesignTokens';

/**
 * ShareLinkPage
 * 分享链接页。整改为 MVVM 纯组装：
 * - 创建 ViewModel 实例（@State + @Observed 第一层观测）
 * - aboutToAppear 调 vm.loadShareInfo 加载分享 URL
 * - aboutToDisappear 调 vm.stopShare 被动停止
 * - URL onClick 调 vm.copyShareUrl（Toast 留 Page 因需 UIContext）
 * - "停止分享"按钮 onClick 调 await vm.stopShare + router.back
 * - build 只渲染，无 AppService 调用、无剪贴板逻辑、无端口解析
 *
 * isNavigatingBack：UI 私有状态（防重复返回），按状态变量原则留 Page @State。
 */
@Entry
@Component
struct ShareLinkPage {
  @State viewModel: ShareLinkViewModel = new ShareLinkViewModel();
  @State private isNavigatingBack: boolean = false;

  onBackPress(): boolean {
    if (this.isNavigatingBack) {
      return true;
    }
    this.isNavigatingBack = true;
    this.getUIContext().getRouter().back();
    return true;
  }

  aboutToAppear(): void {
    let params = this.getUIContext().getRouter().getParams() as Record<string, string>;
    let shareUrlFromParams: string | undefined = undefined;
    if (params !== undefined && params['shareUrl'] !== undefined) {
      shareUrlFromParams = params['shareUrl'];
    }
    this.viewModel.loadShareInfo(shareUrlFromParams);
  }

  aboutToDisappear(): void {
    this.viewModel.stopShare();
  }

  build() {
    Column() {
      // Header
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(DesignTokens.layout.iconSize)
          .height(DesignTokens.layout.iconSize)
          .fillColor($r('app.color.text_primary'))
          .responseRegion({ x: -(DesignTokens.hotspot.minSize - DesignTokens.layout.iconSize) / 2, y: -(DesignTokens.hotspot.minSize - DesignTokens.layout.iconSize) / 2, width: DesignTokens.hotspot.minSize, height: DesignTokens.hotspot.minSize })
          .onClick(() => {
            if (this.isNavigatingBack) {
              return;
            }
            this.isNavigatingBack = true;
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.share_link_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)
      }
      .width('100%')
      .height(DesignTokens.layout.headerHeight)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          // URL display
          Column() {
            Text($r('app.string.share_link_address_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ bottom: DesignTokens.space.xs })

            Text(this.viewModel.shareUrl)
              .fontSize(DesignTokens.font.subtitleM)
              .fontColor($r('app.color.purple_text'))
              .fontWeight(FontWeight.Medium)
              .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
              .backgroundColor($r('app.color.purple_bg'))
              .borderRadius(DesignTokens.radius.md)
              .onClick(() => {
                let ok = this.viewModel.copyShareUrl();
                if (ok) {
                  this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copy_success'), duration: 1500 });
                }
              })
          }
          .alignItems(HorizontalAlign.Center)

          // QR Code
          Column() {
            Column() {
              QRCode(this.viewModel.shareUrl)
                .width(DesignTokens.layout.qrCodeSize)
                .height(DesignTokens.layout.qrCodeSize)
                .backgroundColor($r('app.color.qr_code_background'))
            }
            .width(DesignTokens.layout.qrCodeSize + DesignTokens.space.md * 2)
            .height(DesignTokens.layout.qrCodeSize + DesignTokens.space.md * 2)
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
        }
        .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      }
      .layoutWeight(1)

      // Stop sharing button
      Button($r('app.string.stop_share'))
        .width('80%')
        .height(DesignTokens.hotspot.minSize)
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
          await this.viewModel.stopShare();
          this.getUIContext().getRouter().back();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
    PageTransitionEnter({ type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }
}
