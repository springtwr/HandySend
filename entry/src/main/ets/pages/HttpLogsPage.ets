import { uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsNavigationMenuContentOptions,
  HdsNavigationMenuItemOptions
} from '@kit.UIDesignKit';
import { buildImmersiveTitleBar } from '../common/ImmersiveTitleBar';
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
  // 列表滚动控制器：绑定到子页面容器以驱动标题栏滚动模糊
  private scroller: Scroller = new Scroller()

  aboutToAppear(): void {
    this.viewModel.loadLogs();
  }

  /**
   * 标题栏结束端菜单：保存日志与清空日志。
   * 图标以资源引用传入、档位留空（组件默认档位），尺寸与返回箭头相当；
   * 返回箭头由组件承载，保持系统默认尺寸。
   */
  private buildTitleMenu(): HdsNavigationMenuContentOptions {
    let saveItem: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.arrow_down'),
        label: $r('app.string.save_logs_button'),
        action: () => {
          this.saveLogs();
        }
      }
    };
    let clearItem: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.trash'),
        label: $r('app.string.clear_logs_button'),
        action: () => {
          this.viewModel.clearLogs();
        }
      }
    };
    let items: Array<HdsNavigationMenuItemOptions> = [saveItem, clearItem];
    return { value: items };
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
    HdsNavDestination() {
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
              List({ scroller: this.scroller }) {
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
                })
                  // 稳定唯一键：日志为进入页面时一次性加载的快照，条目在页面生命周期内不增删，
                  // 故以「时间戳 + 位置」构成稳定唯一键（时序变化时键随之变化）
                  .key((item: LogEntry, index: number) => item.timestamp.toString() + '_' + index.toString())
                  // 开启虚拟滚动：仅加载可见区与预加载区内的条目，控制长日志列表的渲染与内存开销
                  .virtualScroll()
              }
              .width('100%')
              .height('100%')
              // 滚动容器不裁剪：滚动中的条目可绘制到标题栏区域内，使毛玻璃背板有内容可透出
              .clip(false)
              // 与不裁剪配套：预加载条目一并参与绘制，避免条目离开视口即被回收，
              // 表现为内容尚未到达标题栏区域便消失
              .cachedCount(3, true)
              .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
            }
            .width('100%')
            .layoutWeight(1)
            .width('100%')
            .height('100%')
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          }
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: this.getContentMaxWidth() })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      // 内容从顶部排列，避免内容不满一屏时被交叉轴默认居中
      .alignItems(VerticalAlign.Top)
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    // 子页面容器背景覆盖至标题栏区域：无内容经过时标题栏底色与页面背景一致，不露出系统默认底色
    .backgroundColor($r('app.color.page_background'))
    .titleBar(buildImmersiveTitleBar({
      title: $r('app.string.http_logs_title'),
      menu: this.buildTitleMenu()
    }))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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
