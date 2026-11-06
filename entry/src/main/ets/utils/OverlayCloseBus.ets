import { getLogger } from './Logger';
import { LogDomains } from '../common/LogDomains';

/**
 * OverlayCloseBus.ets — 前台新传输直达详情前的弹层收起广播
 *
 * 新请求到达需要把详情页推到最前时，先广播一次「收起当前弹层」：
 * 各弹层宿主在自己的关闭语义内处理（无未保存修改直接关闭；有未保存修改走既有退出确认）。
 * 广播不等待关闭完成，详情页先压入弹层之下，弹层关闭后自然露出。
 */

export type OverlayCloseCallback = () => void;

const logger = getLogger(LogDomains.GENERAL, 'HandySend:OverlayClose', '弹层收起');

const callbacks: Array<OverlayCloseCallback> = [];

/** 订阅收起请求；同一回调重复订阅只保留一份。 */
export function subscribeOverlayClose(callback: OverlayCloseCallback): void {
  if (callbacks.indexOf(callback) < 0) {
    callbacks.push(callback);
  }
}

/** 退订收起请求。 */
export function unsubscribeOverlayClose(callback: OverlayCloseCallback): void {
  let index: number = callbacks.indexOf(callback);
  if (index >= 0) {
    callbacks.splice(index, 1);
  }
}

/** 广播一次收起请求；回调快照遍历，允许回调内部退订。 */
export function requestCloseOverlays(): void {
  let snapshot: Array<OverlayCloseCallback> = callbacks.slice();
  for (let i = 0; i < snapshot.length; i++) {
    try {
      snapshot[i]();
    } catch (e) {
      // 单个弹层关闭失败不应阻断其余弹层，也不应阻断后续详情页入栈
      logger.warn('收起弹层回调异常：' + String(e));
    }
  }
}
