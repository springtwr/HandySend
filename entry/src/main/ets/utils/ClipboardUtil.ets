import { pasteboard } from '@kit.BasicServicesKit';

/**
 * ClipboardUtil
 * 系统能力封装：写入剪贴板。无 UI 状态。
 *
 * 返回 true = createData 成功并已发起 setData；
 * 返回 false = createData 抛同步异常（剪贴板锁定或不可用）。
 * 注：setData 本身是异步的，调用方若需严格确认写入完成应自行 await；
 * 当前业务（Toast 反馈）容忍 setData 的异步延迟。
 */
export function copyText(text: string): boolean {
  try {
    let pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(pasteData);
    return true;
  } catch (_e) {
    return false;
  }
}
