import { DesignTokens } from '../common/DesignTokens';
import { ReceiveHistoryViewModel } from '../viewmodel/ReceiveHistoryViewModel';
import { ReceiveHistoryItemViewModel } from '../viewmodel/ReceiveHistoryItemViewModel';

@Entry
@ComponentV2
struct ReceiveHistoryPage {
  @Local viewModel: ReceiveHistoryViewModel = new ReceiveHistoryViewModel();

  aboutToAppear(): void {
    this.withAnimation(() => {
      this.viewModel.loadHistory();
    });
  }

  private withAnimation(action: () => void): void {
    this.getUIContext()
      .animateTo({ duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn }, () => {
        action();
      });
  }

  // 文件类型图标：按 MIME 前缀分流（文本消息/图片/音频/视频/压缩包/其他文档）
  private getFileIcon(item: ReceiveHistoryItemViewModel): Resource {
    if (item.isMessage) {
      return $r('sys.symbol.text_aligncenter');
    }
    let type: string = item.fileType;
    if (type.startsWith('image/')) {
      return $r('sys.symbol.picture_fill');
    } else if (type.startsWith('audio/')) {
      return $r('sys.symbol.music_fill');
    } else if (type.startsWith('video/')) {
      return $r('sys.symbol.video_fill');
    } else if (type.startsWith('text/')) {
      return $r('sys.symbol.doc_text_fill');
    } else if (type === 'application/zip' || type.includes('rar') || type.includes('7z') ||
      type.includes('tar') || type.includes('gzip') || type.includes('bzip') || type.includes('x-xz')) {
      return $r('sys.symbol.doc_zipper_fill');
    }
    return $r('sys.symbol.doc_text_fill');
  }

  // 列表项更多操作菜单：删除记录
  @Builder
  historyMenuBuilder(item: ReceiveHistoryItemViewModel) {
    Menu() {
      MenuItem({
        content: $r('app.string.delete_record'),
        startIcon: $r('sys.symbol.trash')
      })
        .contentFontColor($r('app.color.danger_red'))
        .onClick(() => {
          this.withAnimation(() => {
            this.viewModel.deleteEntry(item.id);
          })
        })
    }
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_backward'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontColor([$r('app.color.text_primary')])
          .responseRegion({
            x: -12,
            y: -12,
            width: 48,
            height: 48
          })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.receive_history_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)

        if (this.viewModel.historyItems.length > 0) {
          Button($r('app.string.clear_history'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.danger_red'))
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.withAnimation(() => {
                this.viewModel.clearAllHistory();
              })
            })
        }
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      if (this.viewModel.historyItems.length === 0) {
        Column() {
          Text($r('app.string.receive_history_empty'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 80 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
      } else {
        List() {
          Repeat(this.viewModel.historyItems).each((ri: RepeatItem<ReceiveHistoryItemViewModel>) => {
            ListItem() {
              Row({ space: DesignTokens.space.sm }) {
                // 左侧文件类型图标（居中 48×48 圆角块）
                Row() {
                  SymbolGlyph(this.getFileIcon(ri.item))
                    .fontSize(32)
                    .fontColor([$r('app.color.accent_blue')])
                }
                .width(48)
                .height(48)
                .borderRadius(DesignTokens.radius.md)
                .backgroundColor($r('app.color.accent_blue_bg'))
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)

                // 三行文本：文件名 / 发送者·大小 / 时间
                Column() {
                  Text(ri.item.isMessage ? ri.item.fileName.substring(0, 40) : ri.item.fileName)
                    .fontSize(DesignTokens.font.subtitleM)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  Row({ space: DesignTokens.space.xs }) {
                    Text(ri.item.senderAlias)
                      .fontSize(DesignTokens.font.bodyS)
                      .fontColor($r('app.color.text_secondary'))

                    if (ri.item.fileSize > 0) {
                      Text(ri.item.formattedSize)
                        .fontSize(DesignTokens.font.bodyS)
                        .fontColor($r('app.color.text_secondary'))
                    }

                    if (ri.item.savedToGallery) {
                      Image($r('app.media.ic_more_photoalbums'))
                        .width(DesignTokens.font.subtitleM)
                        .height(DesignTokens.font.subtitleM)
                    }
                  }
                  .margin({ top: DesignTokens.space.mini })

                  Text(ri.item.formattedTime)
                    .fontSize(DesignTokens.font.captionM)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ top: DesignTokens.space.mini })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                // 更多操作菜单（下拉）：删除记录
                SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
                  .fontSize(16)
                  .fontColor([$r('app.color.text_secondary')])
                  .responseRegion({
                    x: -14,
                    y: -14,
                    width: 48,
                    height: 48
                  })
                  .bindMenu(this.historyMenuBuilder(ri.item))
              }
              .width('100%')
              .padding(DesignTokens.space.md)
              .backgroundColor($r('app.color.card_background'))
              .borderRadius(DesignTokens.radius.lg)
              .border({ width: 1, color: $r('app.color.border_light') })
              .margin({ bottom: DesignTokens.space.xs })
              .transition(
                TransitionEffect.OPACITY
                  .combine(TransitionEffect.translate({ y: 20 }))
                  .animation({ duration: 300, curve: Curve.FastOutSlowIn })
              )
            }
          }).key((item: ReceiveHistoryItemViewModel) => item.id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.xs })
        .divider({ strokeWidth: 0 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  pageTransition() {
    PageTransitionEnter(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
    PageTransitionEnter(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }
}
