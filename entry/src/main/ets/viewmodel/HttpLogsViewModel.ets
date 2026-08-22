import { LogEntry } from '../model/Types';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { getLogs, clearLogs, saveLogsToFile } from '../service/AppService';
import { formatLogsAsText } from '../utils/LogFormatter';

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
 * HTTP 日志页的视图模型。进入页面时加载一次日志快照，不做实时订阅。
 * 保存时直接从 AppCore 拉最新日志，保证导出的是当前数据。
 */
@ObservedV2
export class HttpLogsViewModel {
  @Trace public logEntries: Array<LogEntry> = [];

  /**
   * 加载日志快照用于 UI 显示。必须在 Page 的 aboutToAppear 中调用。
   */
  loadLogs(): void {
    this.logEntries = getLogs().slice();
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
      console.error('HttpLogsViewModel saveLogs failed: ' + err.code + ' ' + err.message);
      return 'failed';
    }
  }

  /**
   * 清空内存日志源数据，并清空 UI 显示。
   */
  clearLogs(): void {
    clearLogs();
    this.logEntries = [];
  }
}
