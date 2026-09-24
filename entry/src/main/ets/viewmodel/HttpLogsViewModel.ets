import { LogEntry } from '../model/Types';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { getLogs, clearLogs, saveLogsToFile, subscribeLogs, unsubscribeLogs } from '../service/AppService';
import { formatLogsAsText } from '../utils/LogFormatter';
import { isDebugEnabled, setDebugEnabled, getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:HttpLogsViewModel', '日志页');

// 合并窗口时长（ms）：与 Rust 侧日志轮询（~500ms）同拍，避免高频刷新抖动
const MERGE_WINDOW_MS: number = 500;
// 积压阈值：窗口内累计通知达到该值即立即刷新，兜底 DEBUG 洪水下的上屏延迟
const BACKLOG_THRESHOLD: number = 100;

/**
 * 保存日志的结果。
 * - success：已写入文件
 * - empty：无日志可保存（Page 据此提示"暂无日志"）
 * - cancelled：用户取消文件选择器（Page 不弹失败 Toast）
 * - failed：保存过程出错（Page 据此提示"保存失败"）
 */
export type SaveLogsResult = 'success' | 'empty' | 'cancelled' | 'failed';

/**
 * HttpLogsViewModel
 * 诊断日志页的视图模型。进入页面时加载一次日志快照，之后订阅日志刷新通道实时增量刷新；
 * 保存时直接从 AppCore 拉最新日志，保证导出的是当前数据。
 */
@ObservedV2
export class HttpLogsViewModel {
  @Trace public logEntries: Array<LogEntry> = [];
  // 详细日志（DEBUG）开关状态：初始取 Logger 当前内存态（Release 默认关闭，重启复位）
  @Trace public debugLogEnabled: boolean = isDebugEnabled();

  // 已从源缓冲加载的条数：用于增量追加与「源长度回退 = 发生裁剪」的检测
  private loadedCount: number = 0;
  // 列表稳定键（与 logEntries 一一对应）：由时间戳 + 全局单调序号构成、不含数组下标，
  // 使尾部追加不改变既有键；仅在裁剪触发的整体重载时重新对齐
  private entryKeys: Array<string> = [];
  // 全局单调序号：跨加载/追加持续递增，裁剪重载时亦不回退，保证键不重复
  private keySeq: number = 0;
  // 节流状态：合并窗口定时器标识、窗口内累计通知数、待刷新标记
  private refreshTimer: number = -1;
  private notifyCountInWindow: number = 0;
  private pendingRefresh: boolean = false;
  // 订阅守卫：避免重复订阅（订阅与退订由页面成对调用）
  private subscribed: boolean = false;

  // 订阅回调需保持稳定引用以支持按引用退订
  private logBusCallback: () => void = () => {
    this.handleLogBusNotification();
  };

  /**
   * 加载当前最新日志快照用于 UI 显示，并记录已加载条数。必须在 Page 的 aboutToAppear 中调用。
   */
  loadLogs(): void {
    let source: Array<LogEntry> = getLogs();
    this.entryKeys = this.buildKeys(source, 0);
    this.logEntries = source.slice();
    this.loadedCount = source.length;
  }

  /**
   * 订阅日志刷新通道。页面打开期间调用，须与 unsubscribeLogs() 成对使用。
   * 内部守卫避免重复订阅导致回调累积。
   */
  subscribeLogs(): void {
    if (this.subscribed) {
      return;
    }
    this.subscribed = true;
    subscribeLogs(this.logBusCallback);
  }

  /** 退订日志刷新通道，并清理未决的合并窗口（防止页面销毁后仍被回调持有）。 */
  unsubscribeLogs(): void {
    if (!this.subscribed) {
      return;
    }
    this.subscribed = false;
    unsubscribeLogs(this.logBusCallback);
    this.cancelScheduledRefresh();
  }

  /**
   * 保存日志到文件。保存时直接从 AppCore 拉最新日志
   * 保证导出的始终是当前最新的数据。
   * @param context UIAbilityContext
   */
  async saveLogs(context: common.UIAbilityContext): Promise<SaveLogsResult> {
    let currentLogs = getLogs();
    if (currentLogs.length === 0) {
      return 'empty';
    }
    let text: string = formatLogsAsText(currentLogs);
    try {
      await saveLogsToFile(context, text);
      return 'success';
    } catch (e) {
      let err: BusinessError = e as BusinessError;
      // 用户取消选择器（常见错误码 0 / 801）按取消处理，不报错
      if (err.code === 0 || err.code === 801) {
        return 'cancelled';
      }
      logger.error('HttpLogsViewModel saveLogs failed: ' + err.code + ' ' + err.message);
      return 'failed';
    }
  }

  /**
   * 清空内存日志源数据，并清空 UI 显示、重置已加载条数。
   * 保持订阅有效：清空后新产生的日志仍能实时追加。
   */
  clearLogs(): void {
    clearLogs();
    this.logEntries = [];
    this.entryKeys = [];
    this.loadedCount = 0;
  }

  /**
   * 切换「详细日志（DEBUG）」开关：委托 Logger 的内存态。
   * 立即生效且不持久化（应用重启后回到默认）。
   */
  setDebugLogEnabled(on: boolean): void {
    this.debugLogEnabled = on;
    setDebugEnabled(on);
  }

  /**
   * 生成列表项的稳定键（供 Repeat 的 .key() 使用）。
   * 正常走预分配的稳定键；极端越界时回退为按时间戳生成的键，避免空键冲突。
   */
  keyFor(item: LogEntry, index: number): string {
    if (index >= 0 && index < this.entryKeys.length) {
      return this.entryKeys[index];
    }
    return item.timestamp.toString();
  }

  // ── 内部：合并窗口与增量追加 ──

  /**
   * 日志通道通知处理：按「合并窗口 + 积压阈值」双条件刷新。
   * 窗口内仅置待刷新标记、窗口结束时统一刷新；窗口内累计通知达积压阈值则立即刷新。
   */
  private handleLogBusNotification(): void {
    this.notifyCountInWindow++;
    if (this.notifyCountInWindow >= BACKLOG_THRESHOLD) {
      this.flushRefresh();
      return;
    }
    this.pendingRefresh = true;
    if (this.refreshTimer >= 0) {
      // 已在合并窗口内：等待窗口结束统一刷新
      return;
    }
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = -1;
      if (this.pendingRefresh) {
        this.flushRefresh();
      }
    }, MERGE_WINDOW_MS);
  }

  /** 立即刷新并复位节流状态。 */
  private flushRefresh(): void {
    this.cancelScheduledRefresh();
    this.refreshFromSource();
  }

  /** 取消未决的合并窗口定时器并复位节流中间状态。 */
  private cancelScheduledRefresh(): void {
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    this.pendingRefresh = false;
    this.notifyCountInWindow = 0;
  }

  /**
   * 从源缓冲刷新 UI 数据：源长度小于已加载条数说明发生裁剪，退化为整体重载；
   * 否则取源数组尾部新增段增量追加（不整体重建数组，保持虚拟滚动与滚动位置）。
   */
  private refreshFromSource(): void {
    let source: Array<LogEntry> = getLogs();
    if (source.length < this.loadedCount) {
      this.loadLogs();
      return;
    }
    if (source.length === this.loadedCount) {
      return;
    }
    let additions: Array<LogEntry> = [];
    let keys: Array<string> = this.entryKeys.slice();
    for (let i = this.loadedCount; i < source.length; i++) {
      additions.push(source[i]);
      keys.push(this.buildKey(source[i]));
    }
    this.entryKeys = keys;
    this.logEntries = this.logEntries.concat(additions);
    this.loadedCount = source.length;
  }

  /** 为源缓冲 [from, end) 段生成稳定键。 */
  private buildKeys(source: Array<LogEntry>, from: number): Array<string> {
    let keys: Array<string> = [];
    for (let i = from; i < source.length; i++) {
      keys.push(this.buildKey(source[i]));
    }
    return keys;
  }

  /** 单条日志的稳定键：时间戳 + 全局单调序号（不含数组下标）。 */
  private buildKey(entry: LogEntry): string {
    let key: string = entry.timestamp.toString() + '_' + this.keySeq.toString();
    this.keySeq++;
    return key;
  }
}
