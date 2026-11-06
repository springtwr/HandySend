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
import { LogViewEntry } from '../model/Types';
import { formatLocalClockTime } from '../utils/LogFileFormat';
import { DesignTokens } from '../common/DesignTokens';
import { EmptyState } from '../components/EmptyState';
import {
  getPageContentMaxWidth,
  getPageMargin,
  getSheetWidth,
  isWideWidth
} from '../common/Breakpoints';
import { common } from '@kit.AbilityKit';
import { getStringSyncFromContext } from '../utils/ResourceUtil';
import { subscribeOverlayClose, unsubscribeOverlayClose } from '../utils/OverlayCloseBus';

/**
 * HttpLogsPage
 * 诊断日志页。固定只读 detail 当前文件尾部，之后按偏移增量刷新。
 * 详细日志开关只决定后续是否追加 debug，页面不切换数据源。
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
  // 日志设置弹层
  @Local showLogSettings: boolean = false
  // 新传输直达详情前的弹层收起：本页只处理日志设置半模态
  private overlayCloseCallback: () => void = (): void => {
    this.showLogSettings = false;
  }

  aboutToAppear(): void {
    subscribeOverlayClose(this.overlayCloseCallback);
    this.viewModel.loadLogs();
    this.viewModel.subscribeLogs();
  }

  aboutToDisappear(): void {
    // 成对退订，防止页面销毁后仍被日志通道回调持有
    unsubscribeOverlayClose(this.overlayCloseCallback);
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
   * 标题栏结束端菜单：导出全部日志、清空日志、日志设置。
   * 日志开关不再作为菜单项，改由「日志设置」弹层承载真实 Toggle 与说明。
   */
  private buildTitleMenu(): HdsNavigationMenuContentOptions {
    let saveItem: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.save'),
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
    let settingsItem: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.gearshape_fill'),
        label: $r('app.string.log_settings_title'),
        action: () => {
          this.showLogSettings = true;
        }
      }
    };
    let items: Array<HdsNavigationMenuItemOptions> = [saveItem, clearItem, settingsItem];
    return { value: items, maxCount: 2 };
  }

  /** 日志设置弹层：唯一的「记录详细日志」开关及用途说明。 */
  @Builder
  logSettingsSheet() {
    Column({ space: DesignTokens.space.md }) {
      Row() {
        Column({ space: DesignTokens.space.tiny }) {
          Text($r('app.string.debug_log_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text($r('app.string.debug_log_desc'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.debugLogEnabled })
          .onChange((isOn: boolean) => {
            this.viewModel.setDebugLogEnabled(isOn);
          })
          .margin({ left: DesignTokens.space.md })
          .id('logs_debug_log_toggle')
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Column({ space: DesignTokens.space.tiny }) {
        Text($r('app.string.log_settings_info_title'))
          .fontSize(DesignTokens.font.bodyS)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Text($r('app.string.log_settings_info_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .width('100%')
      .padding(DesignTokens.space.md)
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({
      left: getPageMargin(this.breakpointInfo.widthBreakpoint),
      right: getPageMargin(this.breakpointInfo.widthBreakpoint),
      top: DesignTokens.space.sm,
      bottom: DesignTokens.space.lg
    })
  }

  /**
   * 导出全部诊断日志
   */
  private async saveLogs(): Promise<void> {
    let result: SaveLogsResult = await this.viewModel.saveLogs(this.context);
    switch (result.status) {
      case 'empty':
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.no_logs'), duration: 2000 });
        break;
      case 'success':
        this.getUIContext()
          .getPromptAction()
          .showToast({
            message: $r('app.string.save_success',
              getStringSyncFromContext(this.context, $r('app.string.EntryAbility_label')),
              result.fileName),
            duration: 3500
          });
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
          if (this.viewModel.fileError.length > 0) {
            Text($r('app.string.log_file_unavailable'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.danger_red'))
              .width('100%')
              .padding({
                left: getPageMargin(this.breakpointInfo.widthBreakpoint),
                right: getPageMargin(this.breakpointInfo.widthBreakpoint),
                top: DesignTokens.space.md,
                bottom: DesignTokens.space.xxs
              })
          }

          if (this.viewModel.loading && this.viewModel.logEntries.length === 0) {
            Column() {
              LoadingProgress()
                .width(48)
                .height(48)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (this.viewModel.logEntries.length === 0) {
            // 整页空态：占满标题栏下方剩余区域并居中
            EmptyState({
              mainText: $r('app.string.no_logs'),
              fillHeight: true
            })
          } else {
            Stack({ alignContent: Alignment.BottomEnd }) {
              List({ scroller: this.scroller }) {
                Repeat(this.viewModel.logEntries).each((ri: RepeatItem<LogViewEntry>) => {
                  ListItem() {
                    Row() {
                      Text(formatLocalClockTime(ri.item.timestamp))
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

                      Text((ri.item.tag.length > 0 ? '[' + ri.item.tag + '] ' : '') + ri.item.message)
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
                // 文件模式使用字节偏移、内存回退使用加载序号作为稳定键，
                // 尾部追加不会改变既有条目的键
                  .key((item: LogViewEntry, index: number) => this.viewModel.keyFor(item, index))
                  // 开启虚拟滚动：仅加载可见区与预加载区内的条目，控制长日志列表的渲染与内存开销
                  .virtualScroll()
              }
              .width('100%')
              .height('100%')
              // 顶部与同类列表页保持同一首元素间距（space.md）
              .padding({ top: DesignTokens.space.md })
              // 滚动容器不裁剪：滚动中的条目可绘制到标题栏区域内，使毛玻璃背板有内容可透出
              .clip(false)
              // 与不裁剪配套：预加载条目一并参与绘制，避免条目离开视口即被回收，
              // 表现为内容尚未到达标题栏区域便消失
              .cachedCount(3, true)
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
      // 与其他设置弹窗一致：绑定在页面内容子组件上，而不是 HdsNavDestination 根节点；
      // 高度使用 MEDIUM，避免单个开关配 FIT_CONTENT 时弹层过矮
      .bindSheet($$this.showLogSettings, this.logSettingsSheet(), {
        // 内容已包含开关与日志文件说明，使用 FIT_CONTENT 避免宽屏中心弹窗留下大片空白
        height: SheetSize.FIT_CONTENT,
        width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
        // 宽屏（lg/xl）以居中弹窗呈现，窄屏保持底部弹窗（与手机行为一致）
        preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
        showClose: true,
        blurStyle: BlurStyle.Regular,
        title: {
          title: $r('app.string.log_settings_title')
        }
      })
    }
    // 子页面容器背景覆盖至标题栏区域：无内容经过时标题栏底色与页面背景一致，不露出系统默认底色
    .backgroundColor($r('app.color.page_background'))
    .titleBar(buildImmersiveTitleBar({
      title: $r('app.string.diagnostic_logs_title'),
      menu: this.buildTitleMenu()
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
