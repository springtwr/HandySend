import { HttpLogsViewModel } from '../viewmodel/HttpLogsViewModel';
import { LogEntry } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';

/**
 * HttpLogsPage
 * HTTP 日志页。整改为 MVVM 纯组装：
 * - 创建 ViewModel 实例（@Local + @ObservedV2 精准观测）
 * - aboutToAppear 调 vm.loadLogs
 * - onClick 调 vm.copyLogs / vm.clearLogs（Toast 留 Page 因需 UIContext）
 * - build 只渲染，无业务逻辑、无 AppService 调用、无剪贴板逻辑
 *
 * 列表项类型：方案 A（简洁折中）— Page 仍 import LogEntry 用于 Repeat 类型注解。
 * LogEntry 是只读 DTO，Page 不修改单条 entry。详见 VM 文件决策注释。
 */
@Entry
@ComponentV2
struct HttpLogsPage {
  @Local viewModel: HttpLogsViewModel = new HttpLogsViewModel();

  aboutToAppear(): void {
    this.viewModel.loadLogs();
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_backward'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontColor([$r('app.color.text_primary')])
          .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.http_logs_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)

        // 复制按钮
        Text($r('app.string.copy_logs_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.accent_blue'))
          .margin({ right: DesignTokens.space.md })
          .responseRegion({ x: -8, y: -8, width: 40, height: 40 })
          .onClick(() => {
            let ok = this.viewModel.copyLogs();
            if (ok) {
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copy_success'), duration: 2000 });
            }
          })

        // 清空按钮
        Text($r('app.string.clear_logs_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.danger_red'))
          .responseRegion({ x: -8, y: -8, width: 40, height: 40 })
          .onClick(() => {
            this.viewModel.clearLogs();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      if (this.viewModel.logEntries.length === 0) {
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
          Repeat(this.viewModel.logEntries).each((ri: RepeatItem<LogEntry>) => {
            ListItem() {
              Row() {
                Text(new Date(ri.item.timestamp).toLocaleTimeString())
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('25%')

                Text('[' + ri.item.level + ']')
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor(ri.item.level === 'error' ? $r('app.color.danger_red') : ri.item.level === 'warn' ? $r('app.color.warning_orange') : $r('app.color.text_secondary'))
                  .width('10%')

                Text(ri.item.message)
                  .fontSize(DesignTokens.font.bodyS)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: 6, bottom: 6 })
            }
          }).key((item: LogEntry, index: number) => index.toString())
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
