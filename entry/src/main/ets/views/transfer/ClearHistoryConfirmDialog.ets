/**
 * ClearHistoryConfirmDialog.ets — 「清除任务历史」二次确认弹窗的共享文案
 *
 * 弹窗本体由各调用点组件内的 @Builder 方法实现，本文件仅提供共享的说明文案构造，
 * 供两个入口（任务路由外壳与主页面 Tab 外壳）复用，避免文案口径漂移。
 * 覆盖两类破坏性操作：「清除任务历史」（全量）与「多选批量删除」（按勾选条数）。
 *
 * 说明：全局 @Builder 函数经 openCustomDialog({ builder }) 打开时不绑定任何组件实例，
 * DialogV2 依赖的 observeComponentCreation2 上下文缺失，会在弹窗构建期抛错并闪退；
 * 故弹窗本体一律采用组件内 @Builder 方法（与项目既有可用模式一致）。
 */

import { getStringSync } from '../../utils/ResourceUtil';
import { getClearableCount } from '../../service/transfer/TransferSessionRegistry';

/** 构造「清除任务历史」确认弹窗的说明文案（替换可清除条数占位；文案为空时返回空串）。 */
export function buildClearHistoryMessage(uiContext: UIContext): string {
  let raw: string = getStringSync(uiContext, $r('app.string.transfer_center_clear_history_message_count'));
  if (raw.length === 0) {
    return '';
  }
  return raw.replace('%d', String(getClearableCount()));
}

/**
 * 构造「多选批量删除」确认弹窗的说明文案（替换勾选条数占位；文案为空时返回空串）。
 * 条数由调用方传入：视图模型持有勾选集合，弹窗文案工厂不直接依赖视图模型。
 */
export function buildDeleteSelectedMessage(uiContext: UIContext, count: number): string {
  let raw: string = getStringSync(uiContext, $r('app.string.transfer_center_delete_selected_message_count'));
  if (raw.length === 0) {
    return '';
  }
  return raw.replace('%d', String(count));
}
