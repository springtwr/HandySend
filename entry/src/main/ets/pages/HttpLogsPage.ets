import { SymbolGlyphModifier, uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { HttpLogsViewModel, SaveLogsResult } from '../viewmodel/HttpLogsViewModel';
import { LogEntry } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';
import { getPageContentMaxWidth, getPageMargin } from '../common/Breakpoints';
import { common } from '@kit.AbilityKit';
import { getStringSyncFromContext } from '../utils/ResourceUtil';

/**
 * HttpLogsPage
 * HTTP 日志页。进入时加载一次日志快照，不做实时订阅。
 * 保存时从 AppCore 拉最新日志，保证导出的是当前数据。
 */
@ComponentV2
export struct HttpLogsPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
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

  // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    return getPageContentMaxWidth(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType);
  }

  build() {
    NavDestination() {
      Row() {
        Column() {
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
                        .width('17%')
                        .textAlign(TextAlign.Start)

                      Text('[' + ri.item.level + ']')
                        .fontSize(DesignTokens.font.captionM)
                        .fontColor(ri.item.level === 'error' ? $r('app.color.danger_red') :
                          ri.item.level === 'warn' ? $r('app.color.warning_orange') : $r('app.color.text_secondary'))
                        .width('17%')
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
                      left: getPageMargin(this.breakpointInfo.widthBreakpoint),
                      right: getPageMargin(this.breakpointInfo.widthBreakpoint),
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
          }
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: this.getContentMaxWidth() })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      // 内容从顶部排列，避免内容不满一屏时被交叉轴默认居中
      .alignItems(VerticalAlign.Top)
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .title($r('app.string.http_logs_title'), { backgroundColor: $r('app.color.page_background') })
    .menus([
      {
        value: $r('app.string.save_logs_button'),
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_down')),
        action: () => {
          this.saveLogs();
        }
      },
      {
        value: $r('app.string.clear_logs_button'),
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.trash')),
        action: () => {
          this.viewModel.clearLogs();
        }
      }
    ])
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}

// 路由表引用：HttpLogsPageBuilder(name, param)
@Builder
export function HttpLogsPageBuilder(_name: string, _param: Object) {
  HttpLogsPage()
}
