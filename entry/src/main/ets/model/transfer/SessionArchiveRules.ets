/**
 * SessionArchiveRules.ets — 任务历史归档规则（纯函数，无 UI、无状态）
 *
 * 提供统一会话成功终结前可复用的归档前置判定：文本消息必须有可预览路径，
 * 避免归档后详情页只能显示「内容不可用」。判定只覆盖文本消息；失败/拒绝/取消
 * 等没有内容交付的终态不在此列。
 */

import { SessionFile, TransferSession } from './TransferSession';
import { isTextFile } from '../../utils/MimeUtils';

/**
 * 文本消息会话是否具备归档所需的可预览路径：
 * 非文本消息不受约束；文本消息至少需要一个文本类文件且 path 非空。
 * 仅检查路径是否已记录，不检查文件当前是否存在（文件删除由历史清理与详情页降级处理）。
 */
export function hasPreviewableTextPath(session: TransferSession): boolean {
  if (!session.textMessage) {
    return true;
  }
  for (let i = 0; i < session.files.length; i++) {
    let file: SessionFile = session.files[i];
    if (isTextFile(file.fileType, file.fileName) && file.path.length > 0) {
      return true;
    }
  }
  return false;
}
