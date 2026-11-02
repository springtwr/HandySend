import { common } from '@kit.AbilityKit';
import { LogEntry, LogViewEntry } from '../model/Types';
import { LogExportResult, LogFileChangeEvent, LogFileKind } from '../model/LogFileTypes';
import {
  exportAllDiagnosticLogs,
  getDiagnosticLogError,
  isDiagnosticLogAvailable,
  readLogFrom,
  readLogTail,
  setPersistedDebugEnabled,
  subscribeLogFileChanges,
  unsubscribeLogFileChanges
} from '../service/log/DiagnosticLogService';
import {
  clearLogs as clearMemoryLogs,
  getLogs,
  saveLogsToFile,
  subscribeLogs as subscribeMemoryLogs,
  unsubscribeLogs as unsubscribeMemoryLogs
} from '../service/AppService';
import { formatLogsAsText } from '../utils/LogFormatter';
import { isDebugEnabled, setDebugEnabled, getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:HttpLogsViewModel', '日志页');

// 合并窗口：文件日志写入端每 500ms flush 一次，页面稍作合并避免频繁读文件
const MERGE_WINDOW_MS: number = 300;
// 内存回退模式的积压阈值（仅 Service 尚未初始化时使用）
const MEMORY_BACKLOG_THRESHOLD: number = 100;

export type SaveLogsResult = LogExportResult;

/**
 * HttpLogsViewModel
 * 诊断日志页视图模型：
 * - 文件日志可用时，固定读取 detail 当前文件尾部，按偏移增量刷新；
 * - Service 尚未初始化（如部分测试或早期启动）时，回退到 AppCore 的小容量内存缓存。
 */
@ObservedV2
export class HttpLogsViewModel {
  @Trace public logEntries: Array<LogViewEntry> = [];
  @Trace public debugLogEnabled: boolean = isDebugEnabled();
  @Trace public fileLogAvailable: boolean = false;
  @Trace public loading: boolean = false;
  @Trace public fileError: string = '';

  // 页面固定读 detail：它始终记录 info+，详细日志开启时再追加 debug
  private activeKind: LogFileKind = LogFileKind.DETAIL;
  private offset: number = 0;
  private generation: number = 0;
  private filePrefix: string = 'memory';
  private loadedCount: number = 0;
  private memoryMode: boolean = false;
  private refreshing: boolean = false;

  private subscribed: boolean = false;
  private refreshTimer: number = -1;
  private notifyCountInWindow: number = 0;
  private pendingRefresh: boolean = false;

  private fileChangeCallback: (event: LogFileChangeEvent) => void = (event: LogFileChangeEvent): void => {
    if (event.kind !== this.activeKind) {
      return;
    }
    this.scheduleRefresh();
  };

  private memoryChangeCallback: () => void = (): void => {
    this.notifyCountInWindow++;
    if (this.notifyCountInWindow >= MEMORY_BACKLOG_THRESHOLD) {
      this.flushMemoryRefresh();
      return;
    }
    this.pendingRefresh = true;
    if (this.refreshTimer >= 0) {
      return;
    }
    this.refreshTimer = setTimeout((): void => {
      this.refreshTimer = -1;
      if (this.pendingRefresh) {
        this.flushMemoryRefresh();
      }
    }, MERGE_WINDOW_MS);
  };

  /** 页面进入：加载 detail 当前文件尾部。 */
  loadLogs(): void {
    this.activeKind = LogFileKind.DETAIL;
    this.fileLogAvailable = isDiagnosticLogAvailable();
    this.fileError = getDiagnosticLogError();
    this.memoryMode = !this.fileLogAvailable;
    if (this.memoryMode) {
      this.loadMemorySnapshot();
      return;
    }
    this.reloadFile();
  }

  /** 订阅刷新：文件可用走文件通道，否则回退到内存日志通道。 */
  subscribeLogs(): void {
    if (this.subscribed) {
      return;
    }
    this.subscribed = true;
    if (this.memoryMode) {
      subscribeMemoryLogs(this.memoryChangeCallback);
    } else {
      subscribeLogFileChanges(this.fileChangeCallback);
    }
  }

  unsubscribeLogs(): void {
    if (!this.subscribed) {
      return;
    }
    this.subscribed = false;
    if (this.memoryMode) {
      unsubscribeMemoryLogs(this.memoryChangeCallback);
    } else {
      unsubscribeLogFileChanges(this.fileChangeCallback);
    }
    this.cancelRefreshTimer();
  }

  /** 导出应用全部诊断日志（events/detail 的 current/previous）。 */
  async saveLogs(context: common.UIAbilityContext): Promise<SaveLogsResult> {
    if (!this.memoryMode) {
      return await exportAllDiagnosticLogs(context);
    }
    let current: Array<LogEntry> = getLogs();
    if (current.length === 0) {
      return { status: 'empty', fileName: '' };
    }
    try {
      let fileName: string = await saveLogsToFile(context, formatLogsAsText(current));
      if (fileName.length === 0) {
        return { status: 'cancelled', fileName: '' };
      }
      return { status: 'success', fileName: fileName };
    } catch (e) {
      let errText: string = String(e);
      if (errText.includes('801') || errText.includes('code: 0')) {
        return { status: 'cancelled', fileName: '' };
      }
      logger.error('保存诊断日志失败：' + errText);
      return { status: 'failed', fileName: '' };
    }
  }

  /** 清空全部日志并重置页面视图。 */
  clearLogs(): void {
    clearMemoryLogs();
    this.logEntries = [];
    this.offset = 0;
    this.loadedCount = 0;
    this.filePrefix = 'memory';
    this.activeKind = LogFileKind.DETAIL;
    this.fileLogAvailable = isDiagnosticLogAvailable();
    this.memoryMode = !this.fileLogAvailable;
    if (!this.memoryMode) {
      this.reloadFile();
    }
  }

  /**
   * 详细日志开关：只改变后续是否记录 debug，并持久化选择。
   * 页面始终读 detail，不切换数据源，因此开启/关闭都不会清空当前列表。
   */
  setDebugLogEnabled(on: boolean): void {
    if (this.debugLogEnabled === on) {
      return;
    }
    this.debugLogEnabled = on;
    setDebugEnabled(on);
    setPersistedDebugEnabled(on);
  }

  /** 列表稳定键：文件模式下用文件内字节偏移；内存回退模式用加载序号。 */
  keyFor(item: LogViewEntry, index: number): string {
    if (this.memoryMode) {
      return this.filePrefix + ':' + index.toString();
    }
    return this.filePrefix + ':' + item.offset.toString();
  }

  // ── 文件模式 ──

  private async reloadFile(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.loading = true;
    try {
      let result = await readLogTail(this.activeKind);
      this.filePrefix = this.activeKind + ':' + result.generation.toString();
      this.logEntries = result.entries;
      this.offset = result.nextOffset;
      this.generation = result.generation;
      this.fileError = getDiagnosticLogError();
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  private scheduleRefresh(): void {
    if (this.memoryMode) {
      return;
    }
    this.pendingRefresh = true;
    if (this.refreshTimer >= 0) {
      return;
    }
    this.refreshTimer = setTimeout((): void => {
      this.refreshTimer = -1;
      if (this.pendingRefresh) {
        this.flushFileRefresh();
      }
    }, MERGE_WINDOW_MS);
  }

  private async flushFileRefresh(): Promise<void> {
    this.pendingRefresh = false;
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    try {
      let result = await readLogFrom(this.activeKind, this.offset, this.generation);
      if (result.reset) {
        this.filePrefix = this.activeKind + ':' + result.generation.toString();
        this.logEntries = result.entries;
      } else if (result.entries.length > 0) {
        this.logEntries = this.logEntries.concat(result.entries);
      }
      this.offset = result.nextOffset;
      this.generation = result.generation;
    } finally {
      this.refreshing = false;
    }
  }

  private cancelRefreshTimer(): void {
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    this.pendingRefresh = false;
    this.notifyCountInWindow = 0;
  }

  // ── 内存回退模式 ──

  private loadMemorySnapshot(): void {
    let source: Array<LogEntry> = getLogs();
    let entries: Array<LogViewEntry> = [];
    for (let i = 0; i < source.length; i++) {
      entries.push(this.toViewEntry(source[i], i));
    }
    this.filePrefix = 'memory';
    this.logEntries = entries;
    this.loadedCount = source.length;
  }

  private flushMemoryRefresh(): void {
    this.cancelRefreshTimer();
    let source: Array<LogEntry> = getLogs();
    if (source.length < this.loadedCount) {
      this.loadMemorySnapshot();
      return;
    }
    if (source.length === this.loadedCount) {
      return;
    }
    let additions: Array<LogViewEntry> = [];
    for (let i = this.loadedCount; i < source.length; i++) {
      additions.push(this.toViewEntry(source[i], i));
    }
    this.logEntries = this.logEntries.concat(additions);
    this.loadedCount = source.length;
  }

  private toViewEntry(entry: LogEntry, index: number): LogViewEntry {
    return {
      timestamp: entry.timestamp,
      level: entry.level,
      tag: entry.tag,
      message: entry.message,
      offset: index
    };
  }
}
