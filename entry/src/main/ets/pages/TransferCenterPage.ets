/**
 * TransferCenterPage.ets — 任务（一级页签内容 + 路由页外壳）
 *
 * 聚合全部会话与任务历史；作为主页一级页签直接可达，同时保留路由页入口。
 * 内容组件为纯内容：视图模型与滚动控制器均由壳层持有并下传，页内不再叠加标题，
 * 标题栏与「本机信息 / 文件历史 / 清除任务历史」入口统一由壳层承载。
 * 会话详情统一经 SessionDetailPage（按统一会话标识进入）。
 */

import { uiObserver } from '@kit.ArkUI';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildImmersiveTitleBar } from '../common/ImmersiveTitleBar';
import {
  buildLocalDeviceSheetOptions,
  buildTransferCenterMenuContent,
  TransferCenterTitleActions
} from '../views/transfer/TransferCenterTitleActions';
import { TransferCenterList } from '../views/transfer/TransferCenterList';
import { LocalDeviceSection } from '../views/settings/LocalDeviceSection';
import { TransferCenterViewModel } from '../viewmodel/TransferCenterViewModel';

@ComponentV2
export struct TransferCenterContent {
  // 视图模型与滚动控制器均由壳层持有并下传：标题栏入口与列表共享同一份历史状态与滚动位置
  @Require @Param viewModel: TransferCenterViewModel
  @Require @Param scroller: Scroller
  @Event onNavigateTo: (name: string, param: Object | undefined) => void =
    (_name: string, _param: Object | undefined) => {
    }
  @Event onScrollDelta: (deltaY: number, absY: number) => void = (_deltaY: number, _absY: number) => {
  }

  private openSession(sessionId: string): void {
    let params: Record<string, string> = { 'sessionId': sessionId };
    this.onNavigateTo('SessionDetailPage', params);
  }

  build() {
    Column() {
      // 列表为内容区首个子组件：标题栏入口（本机信息 / 文件历史 / 清除任务历史）与页面标题均由外层标题栏承载，
      // 页内不再提供任何顶部操作行
      TransferCenterList({
        viewModel: this.viewModel,
        scroller: this.scroller,
        onOpenSession: (sessionId: string) => {
          this.openSession(sessionId);
        },
        onScrollDelta: (deltaY: number, absY: number) => {
          this.onScrollDelta(deltaY, absY);
        }
      })
        .layoutWeight(1)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

@ComponentV2
export struct TransferCenterPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，本机信息半模态参数断点化用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  private pathStack: NavPathStack = new NavPathStack()
  // 壳层持有视图模型与滚动控制器：标题栏入口与列表共享同一份历史状态与滚动位置
  @Local viewModel: TransferCenterViewModel = new TransferCenterViewModel()
  private scroller: Scroller = new Scroller()
  @Local private isShowLocalDeviceSheet: boolean = false

  aboutToAppear(): void {
    this.viewModel.start();
  }

  aboutToDisappear(): void {
    this.viewModel.stop();
  }

  /** 标题栏入口动作：导航类入口直连路由栈，清除任务历史直连内容视图模型。 */
  private titleActions(): TransferCenterTitleActions {
    return {
      onOpenLocalDevice: () => {
        this.isShowLocalDeviceSheet = true;
      },
      onOpenFileHistory: () => {
        this.pathStack.pushPathByName('ReceiveHistoryPage', undefined);
      },
      onClearSessionHistory: () => {
        this.viewModel.clearHistory();
      }
    };
  }

  /** 本机信息精简弹窗内容（别名 / 指纹 / 各网卡 IP）。 */
  @Builder
  localDeviceSheet() {
    LocalDeviceSection()
  }

  build() {
    HdsNavDestination() {
      TransferCenterContent({
        viewModel: this.viewModel,
        scroller: this.scroller,
        onNavigateTo: (name: string, param: Object | undefined) => {
          this.pathStack.pushPathByName(name, param);
        }
      })
    }
    .titleBar(buildImmersiveTitleBar({
      title: $r('app.string.tab_transfer_center'),
      menu: buildTransferCenterMenuContent(this.viewModel.clearableCount, this.titleActions())
    }))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .bindSheet($$this.isShowLocalDeviceSheet, this.localDeviceSheet(),
      buildLocalDeviceSheetOptions(this.breakpointInfo.widthBreakpoint))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}

// 路由表引用：TransferCenterPageBuilder(name, param)
@Builder
export function TransferCenterPageBuilder(name: string, param: Object) {
  TransferCenterPage()
}
