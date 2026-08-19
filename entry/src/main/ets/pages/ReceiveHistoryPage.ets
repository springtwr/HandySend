import { DesignTokens } from '../common/DesignTokens';
import { ReceiveHistoryViewModel } from '../viewmodel/ReceiveHistoryViewModel';
import { ReceiveHistoryItemViewModel } from '../viewmodel/ReceiveHistoryItemViewModel';

@Entry
@ComponentV2
struct ReceiveHistoryPage {
  @Local viewModel: ReceiveHistoryViewModel = new ReceiveHistoryViewModel();
  @Local expandedId: string = ''

  aboutToAppear(): void {
    this.withAnimation(() => {
      this.viewModel.loadHistory();
    });
  }

  private withAnimation(action: () => void): void {
    this.getUIContext().animateTo({ duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn }, () => {
      action();
    });
  }

  build() {
    Column() {
      // Header
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
          .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
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
              Column() {
                Row({ space: DesignTokens.space.sm }) {
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
                        Text('\uD83D\uDCF7')
                          .fontSize(DesignTokens.font.captionM)
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

                  Text('\u203A')
                    .fontSize(DesignTokens.font.subtitleL)
                    .fontColor($r('app.color.text_secondary'))
                }
                .width('100%')
                .padding(DesignTokens.space.md)
                .alignItems(VerticalAlign.Center)

                if (this.expandedId === ri.item.id) {
                  Row({ space: DesignTokens.space.sm }) {
                    Button($r('app.string.delete_record'))
                      .fontSize(DesignTokens.font.bodyS)
                      .fontColor($r('app.color.danger_red'))
                      .backgroundColor($r('app.color.page_background'))
                      .borderRadius(DesignTokens.radius.md)
                      .onClick(() => {
                        this.withAnimation(() => {
                          this.viewModel.deleteEntry(ri.item.id);
                        })
                      })
                  }
                  .width('100%')
                  .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.sm })
                  .justifyContent(FlexAlign.End)
                }
              }
              .width('100%')
              .backgroundColor($r('app.color.card_background'))
              .borderRadius(DesignTokens.radius.lg)
              .border({ width: 1, color: $r('app.color.border_light') })
              .margin({ bottom: DesignTokens.space.xs })
              .onClick(() => {
                this.expandedId = this.expandedId === ri.item.id ? '' : ri.item.id;
              })
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
