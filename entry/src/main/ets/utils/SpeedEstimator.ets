// SpeedEstimator：传输速度滑动窗口估算器（纯逻辑类，无 UI/native 依赖，可单元测试）。
// 速度 = 最近一个完整窗口内"累计字节差 ÷ 实际耗时"：
// - 发送管线（读盘通道 + TLS/TCP 缓冲）滞留的字节在稳态下为常量，窗口两端点差分
//   自动抵消，速度无偏；窗口覆盖传输起点（管线灌充期）时会被尖峰污染，因此历史
//   不足一个完整窗口时不输出速度；
// - 差分只依赖窗口两端点，采样间隔不均（事件被通道丢弃或压缩到达）不影响结果。
//
// 平滑与离群剔除：窗口差分之外再按窗口内各采样区间的速率取中位数，窗口差分高于
// 中位数 OUTLIER_FACTOR 倍时判定为瞬时尖峰（事件突发到达、尾部一次性产出等），
// 改用中位速率呈现；中位数天然不受少数离群区间影响，正常传输（两者相近）不受影响。

/** 速度滑动窗口估算器 */
export class SpeedEstimator {
  // 速度计算窗口（毫秒）：过短易被管线灌充尖峰污染，过长则响应迟钝。
  private static readonly WINDOW_MS: number = 2000
  // 离群阈值：窗口速率高于区间中位速率该倍数时判定为瞬时尖峰，改用中位速率。
  private static readonly OUTLIER_FACTOR: number = 3
  // 采样缓冲（索引 0 为最旧）：仅保留窗口内样本 + 紧邻窗口起点的一个锚点样本。
  private sampleTimes: Array<number> = []
  private sampleBytes: Array<number> = []
  // 上一次采样的累计字节数（用于识别增长）。
  private lastSentBytes: number = 0
  // 最近一次字节数增长的时间戳（用于判定速度是否过期）。
  private lastGrowthTimestamp: number = 0

  /** 输入一次进度采样（累计字节 + 当前毫秒时间戳；调用方传入用于速率的口径，如网络字节），维护窗口内样本。 */
  update(sentBytes: number, now: number): void {
    // 存在前序样本且字节数增长时刷新增长时间戳
    if (this.sampleTimes.length > 0 && sentBytes > this.lastSentBytes) {
      this.lastGrowthTimestamp = now
    }
    this.sampleTimes.push(now)
    this.sampleBytes.push(sentBytes)
    this.lastSentBytes = sentBytes
    // 窗口外（含窗口起点时刻）的旧样本仅保留最新的一个作为差分锚点
    let cutoff: number = now - SpeedEstimator.WINDOW_MS
    let outCount: number = 0
    while (outCount < this.sampleTimes.length && this.sampleTimes[outCount] <= cutoff) {
      outCount++
    }
    if (outCount > 1) {
      this.sampleTimes.splice(0, outCount - 1)
      this.sampleBytes.splice(0, outCount - 1)
    }
  }

  /**
   * 当前窗口速度（字节/秒）：历史不足一个完整窗口或窗口内无字节增长时为 0。
   * 含离群剔除：窗口差分远高于区间中位速率（瞬时尖峰）时改用中位速率。
   */
  getSpeed(): number {
    let base: number = this.windowSpeed()
    if (base <= 0) {
      return 0
    }
    let median: number = this.medianIntervalRate()
    if (median <= 0) {
      return base
    }
    return base > median * SpeedEstimator.OUTLIER_FACTOR ? median : base
  }

  /** 窗口两端点差分速率（字节/秒）：历史不足一个完整窗口时返回 0。 */
  private windowSpeed(): number {
    let n: number = this.sampleTimes.length
    if (n < 2) {
      return 0
    }
    let latestTime: number = this.sampleTimes[n - 1]
    let windowStart: number = latestTime - SpeedEstimator.WINDOW_MS
    // 历史不足一个完整窗口：窗口覆盖传输起点（管线灌充期），不出速度
    if (this.sampleTimes[0] > windowStart) {
      return 0
    }
    // 锚点：不晚于窗口起点的最新样本
    let anchorIdx: number = 0
    while (anchorIdx + 1 < n && this.sampleTimes[anchorIdx + 1] <= windowStart) {
      anchorIdx++
    }
    let deltaBytes: number = this.sampleBytes[n - 1] - this.sampleBytes[anchorIdx]
    let deltaMs: number = latestTime - this.sampleTimes[anchorIdx]
    if (deltaBytes <= 0 || deltaMs <= 0) {
      return 0
    }
    return (deltaBytes * 1000) / deltaMs
  }

  /**
   * 窗口内各采样区间速率的中位数（字节/秒）：仅统计字节增长且间隔为正的区间，
   * 无有效区间时返回 0。中位数抗离群，作为尖峰判定基准。
   */
  private medianIntervalRate(): number {
    let rates: Array<number> = []
    for (let i = 1; i < this.sampleTimes.length; i++) {
      let deltaMs: number = this.sampleTimes[i] - this.sampleTimes[i - 1]
      let deltaBytes: number = this.sampleBytes[i] - this.sampleBytes[i - 1]
      if (deltaMs > 0 && deltaBytes > 0) {
        rates.push((deltaBytes * 1000) / deltaMs)
      }
    }
    if (rates.length === 0) {
      return 0
    }
    rates.sort((a: number, b: number): number => a - b)
    let mid: number = Math.floor(rates.length / 2)
    if (rates.length % 2 === 0) {
      return (rates[mid - 1] + rates[mid]) / 2
    }
    return rates[mid]
  }

  /** 复位全部采样状态（会话结束或新会话开始时调用）。 */
  reset(): void {
    this.sampleTimes = []
    this.sampleBytes = []
    this.lastSentBytes = 0
    this.lastGrowthTimestamp = 0
  }

  /**
   * 预计剩余时间（秒）：剩余字节 / 窗口速度。
   * 已无剩余字节返回 0；速度不可用返回 -1（展示层回退占位符）。
   */
  etaSeconds(totalBytes: number, sentBytes: number): number {
    let remainingBytes: number = totalBytes - sentBytes
    if (remainingBytes <= 0) {
      return 0
    }
    let speed: number = this.getSpeed()
    if (speed <= 0) {
      return -1
    }
    return remainingBytes / speed
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
