// ProgressLogThrottle：传输进度日志节流（纯逻辑，无 UI / 系统 IO 依赖，可单元测试）。
// 发送与接收两侧共用同一口径：进行中的进度日志按共享实例配置的间隔输出，终态日志由调用方
// 无条件输出（不受节流限制）。节流状态按调用方给定的维度键记录，会话终结时清理。

/** 默认节流间隔（毫秒）：纯逻辑默认值，测试与独立使用可覆盖 */
const PROGRESS_LOG_INTERVAL_MS: number = 1000;

/**
 * 进度日志节流器：按维度键限制进行中进度日志的输出频率。
 * 终态日志不走本判定（调用方直接输出后调用 clear 释放该维度状态）。
 */
export class ProgressLogThrottle {
  /** 最小输出间隔（毫秒） */
  private readonly minIntervalMs: number;
  /** 维度键 → 上次输出时间（毫秒，缺失表示尚未输出） */
  private lastEmitAt: Map<string, number> = new Map<string, number>();

  constructor(minIntervalMs: number = PROGRESS_LOG_INTERVAL_MS) {
    this.minIntervalMs = minIntervalMs;
  }

  /**
   * 判断该维度当前是否应输出进行中进度日志：
   * 首次输出无条件允许，其后同一维度在最小间隔内一律抑制。
   * @param key 维度键（发送/接收进度使用会话标识）
   * @param now 当前时间（毫秒）
   */
  shouldLog(key: string, now: number): boolean {
    let last = this.lastEmitAt.get(key);
    if (last === undefined || now - last >= this.minIntervalMs) {
      this.lastEmitAt.set(key, now);
      return true;
    }
    return false;
  }

  /** 清除单个维度的节流状态（该文件进入终态时调用） */
  clear(key: string): void {
    this.lastEmitAt.delete(key);
  }

  /** 清除某会话下全部维度的节流状态（会话终结时调用，避免 Map 无限增长） */
  clearSession(sessionId: string): void {
    let prefix: string = sessionId + ':';
    let doomed: Array<string> = [];
    this.lastEmitAt.forEach((_at: number, k: string) => {
      if (k.indexOf(prefix) === 0) {
        doomed.push(k);
      }
    });
    for (let i = 0; i < doomed.length; i++) {
      this.lastEmitAt.delete(doomed[i]);
    }
  }
}

/**
 * 传输进度日志共享节流器：发送与接收两侧按「会话」维度限制为每 5 秒最多一条，
 * 逐文件进度不再单独刷日志，避免多文件传输时按文件数放大日志量。
 */
export const progressLogThrottle: ProgressLogThrottle = new ProgressLogThrottle(5000);
