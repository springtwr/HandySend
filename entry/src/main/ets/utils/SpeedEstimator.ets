// SpeedEstimator：传输速度采样与剩余时间估算的纯逻辑类（无 UI/native 依赖，可单元测试）。
// 基于进度快照的累计字节与时间差做 EMA 平滑；字节数未增长或回退时不更新速度；
// 采样间隔不均（如事件被通道丢弃）时按实际时间差归一，仅拉长采样窗口。

/** 速度采样与 EMA 平滑估算器 */
export class SpeedEstimator {
  // EMA 平滑系数：新值权重 0.3，旧值权重 0.7（与 LocalSend 传输链路一致）。
  private static readonly EMA_ALPHA: number = 0.3
  // 上次采样的时间戳与累计已传输字节数。
  private lastTimestamp: number = 0
  private lastSentBytes: number = 0
  // EMA 平滑速度（字节/秒）。
  private smoothedSpeed: number = 0
  // 最近一次字节数增长的时间戳（用于判定速度是否过期）。
  private lastGrowthTimestamp: number = 0

  /** 输入一次进度采样（累计已传输字节 + 当前毫秒时间戳），更新平滑速度。 */
  update(sentBytes: number, now: number): void {
    let deltaMs: number = now - this.lastTimestamp
    if (this.lastTimestamp > 0 && deltaMs > 0) {
      let deltaBytes: number = sentBytes - this.lastSentBytes
      // 仅当字节数增长时更新速度（避免暂停/回退导致负值）
      if (deltaBytes > 0) {
        let instantSpeed: number = (deltaBytes * 1000) / deltaMs
        if (this.smoothedSpeed <= 0) {
          this.smoothedSpeed = instantSpeed
        } else {
          this.smoothedSpeed = SpeedEstimator.EMA_ALPHA * instantSpeed +
            (1 - SpeedEstimator.EMA_ALPHA) * this.smoothedSpeed
        }
        this.lastGrowthTimestamp = now
      }
    }
    this.lastTimestamp = now
    this.lastSentBytes = sentBytes
  }

  /** 复位全部采样状态（会话结束或新会话开始时调用）。 */
  reset(): void {
    this.lastTimestamp = 0
    this.lastSentBytes = 0
    this.smoothedSpeed = 0
    this.lastGrowthTimestamp = 0
  }

  /** 当前平滑速度（字节/秒），尚未采样到字节增长时为 0。 */
  getSpeed(): number {
    return this.smoothedSpeed
  }

  /**
   * 预计剩余时间（秒）：剩余字节 / 平滑速度。
   * 已无剩余字节返回 0；速度不可用返回 -1（展示层回退占位符）。
   */
  etaSeconds(totalBytes: number, sentBytes: number): number {
    let remainingBytes: number = totalBytes - sentBytes
    if (remainingBytes <= 0) {
      return 0
    }
    if (this.smoothedSpeed <= 0) {
      return -1
    }
    return remainingBytes / this.smoothedSpeed
  }

  /**
   * 速度是否已过期：尚无字节增长，或距最近一次增长已达阈值毫秒。
   * 过期时展示层应回退占位符，避免显示陈旧速度。
   */
  isStale(now: number, thresholdMs: number): boolean {
    if (this.lastGrowthTimestamp <= 0) {
      return true
    }
    return now - this.lastGrowthTimestamp >= thresholdMs
  }
}
