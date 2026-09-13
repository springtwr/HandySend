// MtaProgressUtil：MTA 互传进度口径相关的纯逻辑（无 UI / 系统 IO 依赖，可单元测试）。
// 两端口径统一为「实际字节 ÷ sendRequest 声明的原始总大小」：发送端分子为已读源字节
// （由 Rust 流式写出过程上报），接收端分子为已解压字节（由 Rust 流式解压会话返回）。
// 本文件保留发送完成态进度解析与进度上报时间节流。

import { MtaSendProgress } from '../model/mta/MtaSendModels';

/** 进度上报默认最小间隔（毫秒），与发送端既有节流间隔同量级 */
const DEFAULT_REPORT_INTERVAL_MS: number = 200;

/**
 * 计算发送完成态进度：总量优先沿用最近一次传输进度中的源总大小，
 * 从未收到进度时才回退声明总量；已发送字节等于总量、百分比为 100。
 */
export function resolveSendCompletedProgress(last: MtaSendProgress, declaredTotal: number): MtaSendProgress {
  let total = last.totalBytes > 0 ? last.totalBytes : declaredTotal;
  if (total < 0) {
    total = 0;
  }
  let progress = new MtaSendProgress();
  progress.sentBytes = total;
  progress.totalBytes = total;
  progress.percent = 100;
  return progress;
}

/**
 * 进度上报时间节流器：限制进度向展示层的上报频率；完成事件不受最小间隔限制，
 * 必须及时送达。复位用于新会话开始或会话终结。
 */
export class ProgressReportThrottle {
  /** 最小上报间隔（毫秒） */
  private readonly minIntervalMs: number;
  /** 最近一次上报时间（0 表示尚未上报） */
  private lastReportAt: number = 0;

  constructor(minIntervalMs: number = DEFAULT_REPORT_INTERVAL_MS) {
    this.minIntervalMs = minIntervalMs;
  }

  /** 判断当前是否应上报；完成事件无条件允许并刷新计时 */
  shouldReport(now: number, isComplete: boolean): boolean {
    if (isComplete) {
      this.lastReportAt = now;
      return true;
    }
    if (this.lastReportAt === 0 || now - this.lastReportAt >= this.minIntervalMs) {
      this.lastReportAt = now;
      return true;
    }
    return false;
  }

  /** 复位节流状态（新会话开始或会话终结时调用） */
  reset(): void {
    this.lastReportAt = 0;
  }
}
