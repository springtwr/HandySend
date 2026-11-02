/**
 * TransferCenterTitleActions.ets — 标题栏入口装配
 *
 * 任务标题栏菜单与「本机信息」半模态参数集中于此，主入口页签与路由外壳共用同一份装配，
 * 避免两个壳层各自内联造成行为与参数漂移。
 */

import { getSheetWidth, isWideWidth } from '../../common/Breakpoints';
import {
  HdsNavigationIconOptions,
  HdsNavigationMenuContentOptions,
  HdsNavigationMenuItemOptions
} from '@kit.UIDesignKit';

/** 标题栏菜单动作注入（由壳层提供，模块本身不持有任何状态）。 */
export interface TransferCenterTitleActions {
  onOpenFileHistory: () => void
  onClearSessionHistory: () => void
}

// 菜单栏最多直接显示的图标个数：自动生成的「更多」入口自身也占用一个槽位，
// 故取值为「期望直接显示项数 + 1」。本场景无直接显示项，取 1 时「更多」占满槽位，
// 「文件接收历史」与「清空任务历史」全部进其原生溢出菜单。
const DIRECT_MENU_ITEM_COUNT: number = 1;

/**
 * 构造任务标题栏菜单内容：「文件接收历史」与「清空任务历史」收进自动溢出的「更多」菜单；
 * 「清空任务历史」常显，无可清除内容时置灰不可用。
 * 图标以资源引用传入、档位留空（组件默认档位），尺寸与返回箭头相当；
 * 返回箭头不在本模块内，保持系统默认尺寸。
 * @param clearableCount 可清除计数（历史条数 + 已终态可见会话数），为零即置灰。
 */
export function buildTransferCenterMenuContent(clearableCount: number,
  actions: TransferCenterTitleActions): HdsNavigationMenuContentOptions {
  let fileHistory: HdsNavigationMenuItemOptions = {
    content: {
      icon: $r('sys.symbol.arrow_counterclockwise_clock'),
      label: $r('app.string.transfer_center_file_history_entry'),
      action: () => {
        actions.onOpenFileHistory();
      }
    }
  };
  let clearHistoryContent: HdsNavigationIconOptions = {
    icon: $r('sys.symbol.trash'),
    label: $r('app.string.transfer_center_clear_history'),
    isEnabled: clearableCount > 0,
    action: () => {
      actions.onClearSessionHistory();
    }
  };
  let clearHistory: HdsNavigationMenuItemOptions = { content: clearHistoryContent };
  let items: Array<HdsNavigationMenuItemOptions> = [fileHistory, clearHistory];
  return { value: items, maxCount: DIRECT_MENU_ITEM_COUNT };
}

/**
 * 「本机信息」半模态参数：窄屏底部弹窗两档可拖拽（设置 detents 后 height 失效，
 * 元组首个元素为初始高度，档位顺序不要求递增），首档取近满高以铺开三段信息；
 * 宽屏（lg/xl）居中弹窗无档位语义，取高度上限（窗口短边 90%）。
 *
 * 半模态内可切换到网络接口页：用户按系统返回键/侧滑时先由 handleBack 退回上一级，
 * 不再直接关闭弹窗；其余关闭方式（下拉、遮罩、关闭按钮）保持原有行为。
 *
 * @param handleBack 返回键/侧滑处理：返回 true 表示已退回上一级、本次不关闭半模态
 */
export function buildLocalDeviceSheetOptions(widthBp: WidthBreakpoint,
  handleBack: () => boolean): SheetOptions {
  let options: SheetOptions;
  if (isWideWidth(widthBp)) {
    options = {
      width: getSheetWidth(widthBp),
      preferType: SheetType.CENTER,
      height: '90%',
      blurStyle: BlurStyle.Regular,
      title: {
        title: $r('app.string.settings_group_local_device'),
        subtitle: ''
      },
      showClose: true
    };
  } else {
    // 设置 detents 后 height 被忽略，首元素为初始高度，可拖拽切换档位
    options = {
      width: getSheetWidth(widthBp),
      preferType: SheetType.BOTTOM,
      detents: ['90%', '50%'],
      blurStyle: BlurStyle.Regular,
      title: {
        title: $r('app.string.settings_group_local_device'),
        subtitle: ''
      },
      showClose: true
    };
  }
  options.onWillDismiss = (dismissSheetAction: DismissSheetAction) => {
    // 仅拦截系统返回（三键 back / 侧滑 / ESC）：下拉、遮罩与关闭按钮仍直接关闭
    if (dismissSheetAction.reason === DismissReason.PRESS_BACK && handleBack()) {
      return;
    }
    dismissSheetAction.dismiss();
  };
  options.onWillSpringBackWhenDismiss = (_springBackAction: SpringBackAction) => {
    // 不调用 springBack：注册 onWillDismiss 后默认会先回弹再关闭，下拉到底时表现为
    // 「快速重新弹出一次后关闭」；取消回弹使下拉直接进入关闭流程。
  };
  return options;
}
