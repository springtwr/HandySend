/**
 * SessionDetailStack.ets — 当前已打开的会话详情页层数
 *
 * 用于前台新传输直达详情前的去重：同一会话的详情页已经在栈中时不重复推入；
 * 页面弹出时递减层数。只记录标识与层数，不持有页面或视图模型。
 */

const openCounts: Map<string, number> = new Map<string, number>();

/** 详情页出现：该会话的层数加一。 */
export function markSessionDetailOpen(sessionId: string): void {
  let count: number = openCounts.get(sessionId) ?? 0;
  openCounts.set(sessionId, count + 1);
}

/** 详情页消失：该会话的层数减一，归零后移除。 */
export function markSessionDetailClosed(sessionId: string): void {
  let count: number = openCounts.get(sessionId) ?? 0;
  if (count <= 1) {
    openCounts.delete(sessionId);
    return;
  }
  openCounts.set(sessionId, count - 1);
}

/** 该会话详情页是否已在任意一层打开。 */
export function isSessionDetailOpen(sessionId: string): boolean {
  let count: number = openCounts.get(sessionId) ?? 0;
  return count > 0;
}
