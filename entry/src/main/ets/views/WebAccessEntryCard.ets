import { DesignTokens } from '../common/DesignTokens';

/**
 * WebAccessEntryCard — 网页服务地址区。
 *
 * 沿用分享页最初的排版：地址标签与地址胶囊整体居中，二维码单独成块、
 * 与地址保持一段间距，提示文案居中收尾。两侧不套卡片容器，
 * 页面只用左右页边距约束，避免二维码贴住标题栏。
 * 地址经 @Param 绑定，随页面模式切换刷新。
 */
@ComponentV2
export struct WebAccessEntryCard {
  @Param url: string = ''
  // 二维码边长：随窗口断点放大，避免大屏上过小
  @Param qrSize: number = DesignTokens.size.qrCodeSize
  @Event onCopy: (url: string) => void = (_url: string) => {
  }

  build() {
    Column() {
      // 地址区：标签 + 可点击地址，整体居中
      Column() {
        Text($r('app.string.share_link_address_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ bottom: DesignTokens.space.tiny })

        Text(this.url)
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
            this.onCopy(this.url);
          })
          .id('web_access_address')
      }
      .alignItems(HorizontalAlign.Center)

      // 二维码区：与地址拉开一段间距，整体居中
      Column() {
        Column() {
          QRCode(this.url)
            .width(this.qrSize)
            .height(this.qrSize)
            .backgroundColor($r('app.color.qr_code_background'))
        }
        .width(this.qrSize + DesignTokens.space.md * 2)
        .height(this.qrSize + DesignTokens.space.md * 2)
        .backgroundColor($r('app.color.qr_code_background'))
        .borderRadius(DesignTokens.radius.md)
        .justifyContent(FlexAlign.Center)

        Text($r('app.string.share_link_qr_hint'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: DesignTokens.space.sm })
      }
      .alignItems(HorizontalAlign.Center)
      .width('100%')
      .margin({ top: DesignTokens.space.lg })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
