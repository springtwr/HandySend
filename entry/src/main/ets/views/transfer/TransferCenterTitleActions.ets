/**
 * TransferCenterTitleActions.ets — 任务标题栏入口装配
 *
 * 任务标题栏的结束端入口与「本机信息」半模态参数集中于此：
 * 主入口页签与路由外壳共用同一份装配，避免两个壳层各自内联造成行为与参数漂移。
 */

import { getSheetWidth, isWideWidth } from '../../common/Breakpoints';
import {
  HdsNavigationIconOptions,
  HdsNavigationMenuContentOptions,
  HdsNavigationMenuItemOptions
} from '@kit.UIDesignKit';

/** 标题栏菜单动作注入（由壳层提供，模块本身不持有任何状态）。 */
export interface TransferCenterTitleActions {
  onOpenLocalDevice: () => void
  onOpenFileHistory: () => void
  onClearSessionHistory: () => void
}

// 菜单栏最多直接显示的图标个数：自动生成的「更多」入口自身也占用一个槽位，
// 故取值为「期望直接显示项数 + 1」。本场景期望直接显示「本机信息」1 项，上限取 2，
// 其余两项由「更多」入口收纳；若上限取 1，「更多」会占满槽位并把全部入口（含本机信息）吞入溢出菜单。
const DIRECT_MENU_ITEM_COUNT: number = 2;

/**
 * 构造任务标题栏菜单内容：「本机信息」（直接图标）、「文件历史」与「清除任务历史」
 * （收进自动溢出的「更多」菜单）；「清除任务历史」常显，无可清除内容时置灰不可用。
 * 图标以资源引用传入、档位留空（组件默认档位），尺寸与返回箭头相当；
 * 返回箭头不在本模块内，保持系统默认尺寸。
 * @param clearableCount 可清除计数（历史条数 + 已终态可见会话数），为零即置灰。
 */
export function buildTransferCenterMenuContent(clearableCount: number,
  actions: TransferCenterTitleActions): HdsNavigationMenuContentOptions {
  let localDevice: HdsNavigationMenuItemOptions = {
    content: {
      icon: $r('sys.symbol.info_circle'),
      label: $r('app.string.settings_group_local_device'),
      action: () => {
        actions.onOpenLocalDevice();
      }
    }
  };
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
  let items: Array<HdsNavigationMenuItemOptions> = [localDevice, fileHistory, clearHistory];
  return { value: items, maxCount: DIRECT_MENU_ITEM_COUNT };
}

/**
 * 「本机信息」半模态参数：保持既有形态——宽屏（lg/xl）居中弹窗、窄屏底部弹窗，
 * 尺寸、模糊与标题栏关闭按钮沿用既有取值。
 */
export function buildLocalDeviceSheetOptions(widthBp: WidthBreakpoint): SheetOptions {
  return {
    height: SheetSize.MEDIUM,
    width: getSheetWidth(widthBp),
    preferType: isWideWidth(widthBp) ? SheetType.CENTER : SheetType.BOTTOM,
    blurStyle: BlurStyle.Regular,
    title: {
      title: $r('app.string.settings_group_local_device'),
      subtitle: ''
    },
    showClose: true
  };
}
