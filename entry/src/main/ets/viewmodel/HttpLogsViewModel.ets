import { LogEntry } from '../model/Types';
import { getLogs } from '../service/AppService';
import { formatLogsAsText } from '../utils/LogFormatter';
import { copyText } from '../utils/ClipboardUtil';

/**
 * HttpLogsViewModel
 * HTTP 日志页的视图模型。持有 UI 状态 logEntries，暴露加载/复制/清空命令。
 *
 * 反模式合规：
 * - 不依赖 UI 组件（反模式 2 ✓）
 * - 不持有 UIContext / PromptAction（反模式 2 ✓）
 * - copyLogs 返回 boolean，Toast 显示由 Page 决定（VM 不触达 UI 反馈）
 *
 * 列表项 LogEntry 决策：选方案 A（简洁折中）。
 * 理由：LogEntry 是只读 interface DTO（timestamp/level/message 三字段），
 * Page 不修改单条 entry，只整体清空。包装成 LogEntryViewModel 字段一一对应纯冗余。
 * 未来 ReceiveHistoryPage 等需要单条观测/修改的列表页再切方案 B。
 */
@ObservedV2
export class HttpLogsViewModel {
  @Trace public logEntries: Array<LogEntry> = [];

  /**
   * 从 AppService 加载日志。必须在 Page 的 aboutToAppear 中调用。
   */
  loadLogs(): void {
    this.logEntries = getLogs();
  }

  /**
   * 格式化日志并写入剪贴板。返回是否成功（createData 未抛异常）。
   * Toast 反馈由 Page 根据返回值决定。
   */
  copyLogs(): boolean {
    let text = formatLogsAsText(this.logEntries);
    return copyText(text);
  }

  /**
   * 清空当前显示的日志列表（仅清 UI 状态，不影响 AppService 内的累积）。
   */
  clearLogs(): void {
    this.logEntries = [];
  }
}
