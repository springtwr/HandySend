// 传输批量上限的唯一事实源：发送、接收与历史摘要共用，避免多处字面量分叉。

/** 单次会话最多包含的文件数（文件夹内文件与普通文件合计）。 */
export const MAX_BATCH_FILES: number = 2000;

/** 发送侧软提示阈值：超过后建议压缩目录，但仍允许继续。 */
export const SOFT_WARN_BATCH_FILES: number = 500;

/** 历史摘要阈值：超过该文件数的批次不保存逐文件明细。 */
export const SUMMARY_DETAIL_THRESHOLD: number = 100;

/** 文件与图库选择器单次可选数量上限。 */
export const MAX_PICK_SELECT_NUMBER: number = 500;

/** 是否超过单次会话硬上限。 */
export function isOverBatchLimit(count: number): boolean {
  return count > MAX_BATCH_FILES;
}

/** 是否需要提示压缩（软阈值，不阻断）。 */
export function needsCompressHint(count: number): boolean {
  return count > SOFT_WARN_BATCH_FILES;
}
