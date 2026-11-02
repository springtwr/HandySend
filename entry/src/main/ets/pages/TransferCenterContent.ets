/**
 * TransferCenterContent.ets — 任务页内容组件
 *
 * 聚合全部会话与任务历史，作为主页「任务」页签的内容使用。
 * 视图模型与滚动控制器均由壳层持有并下传；标题栏与「文件接收历史 / 清空任务历史」入口
 * 统一由壳层承载。会话详情统一经 SessionDetailPage（按统一会话标识进入）。
 */

import { TransferCenterList } from '../views/transfer/TransferCenterList';
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
  // 多选批量删除：上抛壳层弹二次确认弹窗（内容组件不持有弹窗本体）
  @Event onDeleteSelected: () => void = () => {
  }

  private openSession(sessionId: string): void {
    let params: Record<string, string> = { 'sessionId': sessionId };
    this.onNavigateTo('SessionDetailPage', params);
  }

  build() {
    Column() {
      // 列表为内容区首个子组件：标题栏入口（文件接收历史 / 清空任务历史）与页面标题均由外层标题栏承载，
      // 页内不再提供任何顶部操作行
      TransferCenterList({
        viewModel: this.viewModel,
        scroller: this.scroller,
        onOpenSession: (sessionId: string) => {
          this.openSession(sessionId);
        },
        onScrollDelta: (deltaY: number, absY: number) => {
          this.onScrollDelta(deltaY, absY);
        },
        onDeleteSelected: () => {
          this.onDeleteSelected();
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
