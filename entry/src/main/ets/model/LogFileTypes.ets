/**
 * LogFileTypes.ets — 双通道文件日志的公共类型
 *
 * events：关键日志（info/warn/error/fatal），始终写入且不包含 debug
 * detail：页面时间线，始终写入 info+；详细日志开启时追加 debug
 */

import { LogViewEntry } from './Types';

export enum LogFileKind {
  EVENTS = 'events',
  DETAIL = 'detail'
}

/** 文件尾部/增量读取结果。 */
export interface LogReadResult {
  entries: Array<LogViewEntry>
  nextOffset: number
  generation: number
  reset: boolean
  hasMore: boolean
}

/** 日志文件变化通知（写入端 flush/轮转/清空后触发）。 */
export interface LogFileChangeEvent {
  kind: LogFileKind
  generation: number
}

/** 日志导出状态。 */
export type LogExportStatus = 'success' | 'empty' | 'cancelled' | 'failed'

/** 日志导出结果：成功后附带生成的文件名，供页面提示保存位置。 */
export interface LogExportResult {
  status: LogExportStatus
  fileName: string
}

/** 邮件附件打包状态。 */
export type LogAttachmentStatus = 'ready' | 'empty' | 'failed'

/** 邮件附件打包结果：ready 时附带 cacheDir 下的 ZIP 路径与文件名。 */
export interface LogAttachmentResult {
  status: LogAttachmentStatus
  filePath: string
  fileName: string
}
