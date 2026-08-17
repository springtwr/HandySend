import { getReceiveHistory } from '../service/AppService';
import { removeEntry, clearAll } from '../service/ReceiveHistoryService';
import { ReceiveHistoryEntry } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';

@Entry
@Component
struct ReceiveHistoryPage {
  @State historyEntries: Array<ReceiveHistoryEntry> = []
  @State expandedId: string = ''

  aboutToAppear(): void {
    this.loadHistory();
  }

  private loadHistory(): void {
    this.getUIContext().animateTo({ duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn }, () => {
      this.historyEntries = getReceiveHistory();
    });
  }

  private formatTime(timestamp: number): string {
    let date = new Date(timestamp);
    let y = date.getFullYear();
    let m = (date.getMonth() + 1).toString().padStart(2, '0');
    let d = date.getDate().toString().padStart(2, '0');
    let h = date.getHours().toString().padStart(2, '0');
    let min = date.getMinutes().toString().padStart(2, '0');
    return y + '-' + m + '-' + d + ' ' + h + ':' + min;
  }

  private formatSize(size: number): string {
    let KB = 1000;
    let MB = KB * 1000;
    if (size >= MB) {
      return (size / MB).toFixed(1) + ' MB';
    }
    if (size >= KB) {
      return (size / KB).toFixed(1) + ' KB';
    }
    return size + ' B';
  }

  private deleteEntry(id: string): void {
    removeEntry(id);
    this.loadHistory();
  }

  private clearAllHistory(): void {
    clearAll();
    this.loadHistory();
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

        if (this.historyEntries.length > 0) {
          Button($r('app.string.clear_history'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.danger_red'))
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.clearAllHistory();
            })
        }
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      if (this.historyEntries.length === 0) {
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
          ForEach(this.historyEntries, (entry: ReceiveHistoryEntry) => {
            ListItem() {
              Column() {
                Row({ space: DesignTokens.space.sm }) {
                  Column() {
                    Text(entry.isMessage ? entry.fileName.substring(0, 40) : entry.fileName)
                      .fontSize(DesignTokens.font.subtitleM)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    Row({ space: DesignTokens.space.xs }) {
                      Text(entry.senderAlias)
                        .fontSize(DesignTokens.font.bodyS)
                        .fontColor($r('app.color.text_secondary'))

                      if (entry.fileSize > 0) {
                        Text(this.formatSize(entry.fileSize))
                          .fontSize(DesignTokens.font.bodyS)
                          .fontColor($r('app.color.text_secondary'))
                      }

                      if (entry.savedToGallery) {
                        Text('\uD83D\uDCF7')
                          .fontSize(DesignTokens.font.captionM)
                      }
                    }
                    .margin({ top: DesignTokens.space.mini })

                    Text(this.formatTime(entry.timestamp))
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

                if (this.expandedId === entry.id) {
                  Row({ space: DesignTokens.space.sm }) {
                    Button($r('app.string.delete_record'))
                      .fontSize(DesignTokens.font.bodyS)
                      .fontColor($r('app.color.danger_red'))
                      .backgroundColor($r('app.color.page_background'))
                      .borderRadius(DesignTokens.radius.md)
                      .onClick(() => {
                        this.deleteEntry(entry.id);
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
                this.expandedId = this.expandedId === entry.id ? '' : entry.id;
              })
              .transition(
                TransitionEffect.OPACITY
                  .combine(TransitionEffect.translate({ y: 20 }))
                  .animation({ duration: 300, curve: Curve.FastOutSlowIn })
              )
            }
          }, (entry: ReceiveHistoryEntry) => entry.id)
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
