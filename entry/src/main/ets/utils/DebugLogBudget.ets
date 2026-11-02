/**
 * DebugLogBudget.ets — debug 日志令牌桶
 *
 * detail 始终记录 info+，debug 只允许占用有限预算：
 * - 按固定速率补充令牌，允许短时突发；
 * - 令牌不足时丢弃 debug，并累计压制条数；
 * - events 通道不经过本预算，关键日志不会被 debug 洪水挤掉。
 */

export class DebugLogBudget {
  private readonly refillPerSecond: number;
  private readonly capacity: number;
  private tokens: number;
  private updatedAt: number;
  private suppressed: number = 0;

  constructor(refillPerSecond: number = 100, capacity: number = 300, now: number = Date.now()) {
    this.refillPerSecond = refillPerSecond;
    this.capacity = capacity;
    this.tokens = capacity;
    this.updatedAt = now;
  }

  /** 判断当前是否允许输出一条 debug；不允许时自动累计压制条数。 */
  allow(now: number): boolean {
    let elapsed: number = Math.max(0, now - this.updatedAt);
    this.updatedAt = now;
    this.tokens = Math.min(this.capacity, this.tokens + elapsed * this.refillPerSecond / 1000);
    if (this.tokens >= 1) {
      this.tokens -= 1;
      return true;
    }
    this.suppressed++;
    return false;
  }

  /** 取出并清零自上次调用以来的压制条数。 */
  takeSuppressed(): number {
    let count: number = this.suppressed;
    this.suppressed = 0;
    return count;
  }

  /** 新会话/清空后重置令牌与压制计数。 */
  reset(now: number): void {
    this.tokens = this.capacity;
    this.updatedAt = now;
    this.suppressed = 0;
  }
}
