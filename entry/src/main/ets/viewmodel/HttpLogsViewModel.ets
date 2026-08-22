import { LogEntry } from '../model/Types';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { getLogs, clearLogs, subscribe, unsubscribe, saveLogsToFile } from '../service/AppService';
import { formatLogsAsText } from '../utils/LogFormatter';

/**
 * 保存日志的结果。VM 只返回结果，Toast 等 UI 反馈由 Page 负责（严格 MVVM：VM 不触达 UI）。
 * - success：已写入文件
 * - empty：无日志可保存（Page 据此提示"暂无日志"）
 * - cancelled：用户取消文件选择器（Page 不弹失败 Toast）
 * - failed：保存过程出错（Page 据此提示"保存失败"）
 */
export type SaveLogsResult = 'success' | 'empty' | 'cancelled' | 'failed';

/**
 * HttpLogsViewModel
 * HTTP 日志页的视图模型。持有 UI 状态 logEntries，暴露加载/保存/清空命令。
 *
 * 严格 MVVM 合规：
 * - 不依赖 UI 组件、不持有 UIContext / PromptAction / fs / picker。
 * - 保存动作（picker + fs 写入）下沉到 AppCore.saveLogsToFile（纯逻辑仓库方法），
 *   VM 仅编排：拼文本 → 调 Service → 把结果映射为 SaveLogsResult 返回。
 * - Toast 文案/Resource→字符串转换等 UI 反馈留在 Page，VM 完全不碰 UI。
 */
@ObservedV2
export class HttpLogsViewModel {
  @Trace public logEntries: Array<LogEntry> = [];
  // 日志变化回调（箭头函数持有 this），订阅/退订时用同一引用，对齐项目 subscribe 范式
  // （SendContent/ReceiveContent/TransferPage 等均用 refreshCallback 字段，避免 this 丢失）。
  private logChangedCallback: () => void = (): void => {
    this.refreshLogs();
  };

  /**
   * 从 AppService 加载日志并订阅日志变化通知。必须在 Page 的 aboutToAppear 中调用。
   */
  loadLogs(): void {
    this.refreshLogs();
    subscribe(this.logChangedCallback);
  }

  /**
   * 重拉最新日志数组，触发 UI 刷新（正序，最早在上）。
   * 必须拷贝出新的数组引用：AppCore.logs 在 addLog 时多为原地 push（引用不变），
   * 若直接 logEntries = getLogs() 赋值同一引用，@Trace 判定值未变而不刷新。
   * 拷贝一份新数组可强制触发 @Trace 的属性更新。
   */
  private refreshLogs(): void {
    this.logEntries = getLogs().slice();
  }

  /**
   * 退订日志变化通知。必须在 Page 的 aboutToDisappear 中调用，防止页面销毁后泄漏。
   */
  dispose(): void {
    unsubscribe(this.logChangedCallback);
  }

  /**
   * 保存日志到文件（DOWNLOAD 模式，落盘用户可见的 Downloads/应用目录）。
   * 编排 AppCore.saveLogsToFile，把异常映射为 SaveLogsResult 返回，不弹 Toast。
   * @param context UIAbilityContext，由 Page 传入（picker 构造需要），VM 不自行获取 UI 上下文。
   */
  async saveLogs(context: common.UIAbilityContext): Promise<SaveLogsResult> {
    if (this.logEntries.length === 0) {
      return 'empty';
    }
    let text: string = formatLogsAsText(this.logEntries);
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
   * 清空日志。同时清空 AppCore 内存源数据（否则后台持续写入会立即覆盖 UI 副本），
   * 并刷新 UI 状态为空的源数组。
   */
  clearLogs(): void {
    clearLogs();
    this.refreshLogs();
  }
}
