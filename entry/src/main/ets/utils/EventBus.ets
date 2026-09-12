// 事件总线唯一实现：订阅/退订/通知。
// AppCore 与 FavoritesService 各自持有一个实例，对外导出名保持一致，调用方零改动。
import { getLogger } from './Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:EventBus', '事件总线');

export class EventBus {
  private callbacks: Array<() => void> = [];

  subscribe(callback: () => void): void {
    this.callbacks.push(callback);
  }

  unsubscribe(callback: () => void): void {
    let idx = -1;
    for (let i = 0; i < this.callbacks.length; i++) {
      if (this.callbacks[i] === callback) {
        idx = i;
        break;
      }
    }
    if (idx >= 0) {
      // 末尾交换删除，避免数组搬移
      let last = this.callbacks.length - 1;
      this.callbacks[idx] = this.callbacks[last];
      this.callbacks.pop();
    }
  }

  notifyChange(): void {
    for (let i = 0; i < this.callbacks.length; i++) {
      try {
        this.callbacks[i]();
      } catch (e) {
        // 单个回调异常不中断其余回调分发，也不向上传播到触发通知的业务操作
        logger.error('EventBus 回调异常: ' + String(e));
      }
    }
  }
}
