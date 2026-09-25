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
import { EmptyState } from '../components/EmptyState';
import { getPageContentMaxWidth, getPageMargin } from '../common/Breakpoints';
import { common } from '@kit.AbilityKit';
import { getStringSyncFromContext } from '../utils/ResourceUtil';

/**
 * HttpLogsPage
 * 诊断日志页。进入时加载当前日志快照，之后订阅日志通道实时增量刷新。
 * 保存时从 AppCore 拉最新日志，保证导出的是当前数据。
 */
@ComponentV2
export struct HttpLogsPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: HttpLogsViewModel = new HttpLogsViewModel();
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  // NavDestination 返回栈（onReady 注入）
  // 列表滚动控制器：绑定到子页面容器以驱动标题栏滚动模糊
  private scroller: Scroller = new Scroller()
  // 是否处于「跟随最新」模式：默认跟随；用户上滑脱离底部即暂停
  @Local isFollowing: boolean = true

  aboutToAppear(): void {
    this.viewModel.loadLogs();
    this.viewModel.subscribeLogs();
  }

  aboutToDisappear(): void {
    // 成对退订，防止页面销毁后仍被日志通道回调持有
    this.viewModel.unsubscribeLogs();
  }

  /**
   * 日志数据变化：处于跟随态时自动滚到最新条目；暂停态下不改变滚动位置。
   */
  @Monitor('viewModel.logEntries')
  onLogsChanged(): void {
    if (this.isFollowing && this.viewModel.logEntries.length > 0) {
      this.scroller.scrollEdge(Edge.Bottom);
    }
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
   * 标题栏底部自定义区域：详细日志（DEBUG）开关行。
   * 位于标题栏内、常驻可见，不随日志列表滚动离开视野；状态不持久化，重启复位。
   */
  @Builder
  debugLogToggleBuilder() {
    Column() {
      Row() {
        Text($r('app.string.debug_log_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.debugLogEnabled })
          .onChange((isOn: boolean) => {
            this.viewModel.setDebugLogEnabled(isOn);
          })
          .id('logs_debug_log_toggle')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 简短说明：开启后记录更详细的调试信息、重启后自动关闭
      Text($r('app.string.debug_log_desc'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 左右内边距与页面内容一致，使开关行与日志列表对齐
    .padding({
      left: getPageMargin(this.breakpointInfo.widthBreakpoint),
      right: getPageMargin(this.breakpointInfo.widthBreakpoint)
    })
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
            // 整页空态：占满标题栏下方剩余区域并居中
            EmptyState({
              mainText: $r('app.string.no_logs'),
              fillHeight: true
            })
          } else {
            Stack({ alignContent: Alignment.BottomEnd }) {
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
                // 稳定唯一键：时间戳 + 全局单调序号（不含数组下标），
                // 使实时增量追加与缓冲裁剪都不改变既有条目的键
                  .key((item: LogEntry, index: number) => this.viewModel.keyFor(item, index))
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
              // 末项可见即视为在底部：恢复跟随；否则暂停跟随（用户上滑浏览历史）
              .onScrollIndex((_start: number, end: number, _center: number) => {
                let lastIndex: number = this.viewModel.logEntries.length - 1;
                if (lastIndex < 0) {
                  return;
                }
                this.isFollowing = end >= lastIndex;
              })

              if (!this.isFollowing) {
                // 「回到底部」浮层控件：仅在暂停跟随时出现，点击恢复跟随并滚到最新
                Row() {
                  SymbolGlyph($r('sys.symbol.arrow_down_circle'))
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor([$r('app.color.text_on_color')])
                  Text($r('app.string.log_back_to_bottom'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.text_on_color'))
                    .margin({ left: DesignTokens.space.tiny })
                }
                .padding({
                  left: DesignTokens.space.md,
                  right: DesignTokens.space.md,
                  top: DesignTokens.space.sm,
                  bottom: DesignTokens.space.sm
                })
                .backgroundColor($r('app.color.accent_blue'))
                .borderRadius(DesignTokens.radius.max)
                .shadow(ShadowStyle.OUTER_DEFAULT_SM)
                .margin({ right: DesignTokens.space.lg, bottom: DesignTokens.space.lg })
                .onClick(() => {
                  this.isFollowing = true;
                  this.scroller.scrollEdge(Edge.Bottom);
                })
                .id('log_back_to_bottom_btn')
              }
            }
            .width('100%')
            .layoutWeight(1)
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
      title: $r('app.string.diagnostic_logs_title'),
      menu: this.buildTitleMenu(),
      // 底部自定义区域承载「详细日志（DEBUG）」开关，常驻标题栏、不随列表滚动离开视野
      bottomBuilder: (): void => {
        this.debugLogToggleBuilder();
      }
    }))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

// 路由表引用：HttpLogsPageBuilder(name, param)
@Builder
export function HttpLogsPageBuilder(_name: string, _param: Object) {
  HttpLogsPage()
}
