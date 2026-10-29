// 文本弹窗对齐判定：整段文本在内容区单行显示时居中、多行时左对齐。
// 口径与既有「协议会话 ID / 指纹」弹窗一致（单行测量宽度 vs 内容区可用宽度），
// 供多处文本预览弹窗复用，避免重复实现分叉。

import { UIContext } from '@kit.ArkUI';

/**
 * 文本是否含显式换行（CR/LF/Unicode 行分隔符）。
 * measureText 会把换行当作零宽字符，多行短文本的测量宽度可能仍小于内容区宽度，
 * 故必须先按显式换行判定为多行，不能只依赖测量宽度。
 */
export function hasExplicitLineBreak(text: string): boolean {
  return text.indexOf('\n') >= 0 || text.indexOf('\r') >= 0 ||
    text.indexOf('\u2028') >= 0 || text.indexOf('\u2029') >= 0;
}

/**
 * 判定单行/多行对齐：
 * - 含显式换行 → 多行左对齐（TextAlign.Start）；
 * - 可用宽度 ≤ 0（尚未测量到）→ 左对齐（TextAlign.Start）；
 * - 整段文本单行测量宽度 ≤ 内容区可用宽度 → 单行居中（TextAlign.Center）；
 * - 否则多行左对齐（TextAlign.Start）。
 * @param uiContext 当前 UI 上下文（提供测量与 vp→px 换算）
 * @param text 待展示的完整文本
 * @param fontSize 文本字号（fp，与渲染时一致）
 * @param availableWidthVp 内容区可用宽度（vp，由内容文本 onAreaChange 获取）
 */
export function resolveSingleLineTextAlign(uiContext: UIContext, text: string, fontSize: number,
  availableWidthVp: number): TextAlign {
  if (hasExplicitLineBreak(text) || availableWidthVp <= 0) {
    return TextAlign.Start;
  }
  let singleLineWidthPx: number = uiContext.getMeasureUtils().measureText({
    textContent: text,
    fontSize: fontSize
  });
  let availableWidthPx: number = uiContext.vp2px(availableWidthVp);
  return singleLineWidthPx <= availableWidthPx ? TextAlign.Center : TextAlign.Start;
}
