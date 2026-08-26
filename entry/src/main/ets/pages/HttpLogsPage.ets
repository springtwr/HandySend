import { HttpLogsViewModel, SaveLogsResult } from '../viewmodel/HttpLogsViewModel';
import { LogEntry } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';
import { common } from '@kit.AbilityKit';
import { getStringSyncFromContext } from '../utils/ResourceUtil';

/**
 * HttpLogsPage
 * HTTP 日志页。进入时加载一次日志快照，不做实时订阅。
 * 保存时从 AppCore 拉最新日志，保证导出的是当前数据。
 */
@ComponentV2
export struct HttpLogsPage {
  @Local viewModel: HttpLogsViewModel = new HttpLogsViewModel();
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()

  aboutToAppear(): void {
    this.viewModel.loadLogs();
  }

  /**
   * 保存日志
   */
  private async saveLogs(): Promise<void> {
    let result: SaveLogsResult = await this.viewModel.saveLogs(this.context);
    switch (result) {
      case 'empty':
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.no_logs'), duration: 2000 });
        break;
      case 'success':
        let appNameStr: string = getStringSyncFromContext(this.context, $r('app.string.EntryAbility_label'));
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.save_success', appNameStr), duration: 2000 });
        break;
      case 'failed':
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.save_failed'), duration: 2000 });
        break;
      case 'cancelled':
        // 用户取消选择器，不弹 Toast
        break;
    }
  }

  build() {
    NavDestination() {
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
              this.pathStack.pop();
            })

        Text($r('app.string.http_logs_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)

        // 保存按钮
        Text($r('app.string.save_logs_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.accent_blue'))
          .margin({ right: DesignTokens.space.md })
          .responseRegion({
            x: -8,
            y: -8,
            width: 40,
            height: 40
          })
          .onClick(() => {
            this.saveLogs();
          })

        // 清空按钮
        Text($r('app.string.clear_logs_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.danger_red'))
          .responseRegion({
            x: -8,
            y: -8,
            width: 40,
            height: 40
          })
          .onClick(() => {
            this.viewModel.clearLogs();
          })
      }
      .width('100%')
      .height(DesignTokens.size.headerHeight)
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
        Column() {
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
                    .fontColor(ri.item.level === 'error' ? $r('app.color.danger_red') :
                      ri.item.level === 'warn' ? $r('app.color.warning_orange') : $r('app.color.text_secondary'))
                    .width('12%')
                    .maxLines(1)
                    .textAlign(TextAlign.Start)

                  Text(ri.item.message)
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                    .maxLines(2)
                    .wordBreak(WordBreak.BREAK_ALL)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .padding({
                  left: DesignTokens.space.md,
                  right: DesignTokens.space.md,
                  top: 6,
                  bottom: 6
                })
              }
            }).key((item: LogEntry, index: number) => index.toString())
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_background'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .hideTitleBar(true)
      .onReady((ctx: NavDestinationContext) => {
        this.pathStack = ctx.pathStack;
      })
    }
  }
}

// 路由表引用：HttpLogsPageBuilder(name, param)
@Builder
export function HttpLogsPageBuilder(name: string, param: Object) {
  HttpLogsPage()
}
