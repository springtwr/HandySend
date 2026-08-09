import { router } from '@kit.ArkUI';
import { getLogs } from '../service/AppService';
import { LogEntry } from '../model/Types';
import { pasteboard } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';

@Entry
@Component
struct HttpLogsPage {
  @State logEntries: Array<LogEntry> = []

  aboutToAppear(): void {
    this.logEntries = getLogs();
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
            router.back();
          })

        Text($r('app.string.http_logs_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)

        // Copy button
        Text($r('app.string.copy_logs_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.accent_blue'))
          .margin({ right: DesignTokens.space.md })
          .responseRegion({ x: -8, y: -8, width: 40, height: 40 })
          .onClick(() => {
            let text = '';
            for (let i = 0; i < this.logEntries.length; i++) {
              let e = this.logEntries[i];
              text = text + new Date(e.timestamp).toISOString() + ' [' + e.level + '] ' + e.message + '\n';
            }
            let pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
            pasteboard.getSystemPasteboard().setData(pasteData);
            this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copy_success'), duration: 2000 });
          })

        // Clear button
        Text($r('app.string.clear_logs_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.danger_red'))
          .responseRegion({ x: -8, y: -8, width: 40, height: 40 })
          .onClick(() => {
            this.logEntries = [];
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      if (this.logEntries.length === 0) {
        Column() {
          Text($r('app.string.no_logs'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List() {
          ForEach(this.logEntries, (entry: LogEntry, index: number) => {
            ListItem() {
              Row() {
                Text(new Date(entry.timestamp).toLocaleTimeString())
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('25%')

                Text('[' + entry.level + ']')
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor(entry.level === 'error' ? $r('app.color.danger_red') : entry.level === 'warn' ? $r('app.color.warning_orange') : $r('app.color.text_secondary'))
                  .width('10%')

                Text(entry.message)
                  .fontSize(DesignTokens.font.bodyS)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: 6, bottom: 6 })
            }
          }, (entry: LogEntry, index: number) => index.toString())
        }
        .width('100%')
        .layoutWeight(1)
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
