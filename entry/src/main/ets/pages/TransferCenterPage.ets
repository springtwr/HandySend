/**
 * TransferCenterPage.ets — 传输中心（一级页签内容 + 路由页外壳）
 *
 * 聚合全部会话与会话历史；作为主页一级页签直接可达，同时保留路由页入口。
 * 「本机信息」与「文件历史」入口位于「会话历史」标题行（见 TransferCenterList），
 * 本页承载本机信息精简弹窗（bindSheet）与取消全部活跃；页面不重复展示标题
 * （标题由主页页签承载）。会话详情统一经 SessionDetailPage（按统一会话标识进入）。
 */

import { uiObserver } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';
import { getSheetWidth, isWideWidth } from '../common/Breakpoints';
import { TransferCenterList } from '../views/transfer/TransferCenterList';
import { LocalDeviceSection } from '../views/settings/LocalDeviceSection';
import { TransferCenterViewModel } from '../viewmodel/TransferCenterViewModel';

@ComponentV2
export struct TransferCenterContent {
  // 系统宽度断点（随窗口尺寸变化自动刷新，本机信息半屏弹窗宽度断点化用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Event onNavigateTo: (name: string, param: Object | undefined) => void =
    (_name: string, _param: Object | undefined) => {
    }
  @Event onScrollDelta: (deltaY: number, absY: number) => void = (_deltaY: number, _absY: number) => {
  }
  @Local viewModel: TransferCenterViewModel = new TransferCenterViewModel()
  @Local private isShowLocalDeviceSheet: boolean = false

  aboutToAppear(): void {
    this.viewModel.start();
  }

  aboutToDisappear(): void {
    this.viewModel.stop();
  }

  private openSession(sessionId: string): void {
    let params: Record<string, string> = { 'sessionId': sessionId };
    this.onNavigateTo('SessionDetailPage', params);
  }

  build() {
    Column() {
      // 顶部操作行：仅存在活跃会话时提供「取消全部活跃」。
      // 本机信息 / 文件历史入口已移至「会话历史」标题行；页面标题由主页一级页签承载。
      if (this.viewModel.activeCount > 0) {
        Row() {
          Blank()

          Text($r('app.string.transfer_center_cancel_all'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.danger_red'))
            .padding(DesignTokens.space.tiny)
            .accessibilityGroup(true)
            .onClick(() => {
              this.viewModel.cancelAllActive();
            })
        }
        .width('100%')
        .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.md })
        .alignItems(VerticalAlign.Center)
      }

      TransferCenterList({
        viewModel: this.viewModel,
        onOpenSession: (sessionId: string) => {
          this.openSession(sessionId);
        },
        onOpenFileHistory: () => {
          this.onNavigateTo('ReceiveHistoryPage', undefined);
        },
        onOpenLocalDevice: () => {
          this.isShowLocalDeviceSheet = true;
        },
        onScrollDelta: (deltaY: number, absY: number) => {
          this.onScrollDelta(deltaY, absY);
        }
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .bindSheet($$this.isShowLocalDeviceSheet, this.localDeviceSheet(), {
      height: SheetSize.MEDIUM,
      width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
      // 宽屏（lg/xl）以居中弹窗呈现，窄屏保持底部弹窗（与手机行为一致）
      preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
      blurStyle: BlurStyle.Regular,
      title: {
        title: $r('app.string.settings_group_local_device'),
        subtitle: ''
      },
      showClose: true
    })
  }

  /** 本机信息精简弹窗内容（别名 / 指纹 / 各网卡 IP）。 */
  @Builder
  localDeviceSheet() {
    LocalDeviceSection()
  }
}

@ComponentV2
export struct TransferCenterPage {
  @Param pageParam: Object = new Object()
  private pathStack: NavPathStack = new NavPathStack()

  build() {
    NavDestination() {
      TransferCenterContent({
        onNavigateTo: (name: string, param: Object | undefined) => {
          this.pathStack.pushPathByName(name, param);
        }
      })
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}

// 路由表引用：TransferCenterPageBuilder(name, param)
@Builder
export function TransferCenterPageBuilder(name: string, param: Object) {
  TransferCenterPage({ pageParam: param })
}
