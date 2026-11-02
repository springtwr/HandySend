/**
 * ProtocolDisableGuard.ets — 协议/方向开关关闭前的活跃会话确认
 *
 * 设置页的方向开关与网页面板的关闭按钮共用同一套确认语义：
 * 无活跃会话时直接执行；有活跃会话（含待确认）时先列出明细并二次确认，
 * 确认后由调用方写入开关、停止服务并中断会话，取消则保持原状态。
 */

import { getAppContext } from '../repository/AppCore';
import { DialogService } from '../DialogService';
import { cancel, listActiveSessionsByProtocolKeys } from './TransferSessionRegistry';
import { SessionDataFlow, TransferSession } from '../../model/transfer/TransferSession';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ProtocolDisableGuard', '协议开关');

// 解析资源为当前语言文本（解析失败回退空串）
function resolveResourceText(res: Resource): string {
  let ctx = getAppContext();
  if (ctx === undefined) {
    return '';
  }
  try {
    return ctx.resourceManager.getStringSync(res.id);
  } catch (e) {
    logger.warn('解析资源文本失败：' + String(e));
    return '';
  }
}

// 会话文件摘要：单文件显示文件名，多文件显示数量
function sessionFileSummary(session: TransferSession): string {
  if (session.files.length === 1) {
    return session.files[0].fileName;
  }
  let countText: string = resolveResourceText($r('app.string.transfer_center_file_count'));
  return countText.replace('%d', String(session.files.length));
}

function buildSessionDetailLine(session: TransferSession): string {
  let templateRes: Resource = session.dataFlow === SessionDataFlow.outbound ?
    $r('app.string.protocol_disable_session_send') : $r('app.string.protocol_disable_session_receive');
  let template: string = resolveResourceText(templateRes);
  // 模板含两个 %s：依次填对端名与文件摘要
  return template.replace('%s', session.peer.displayName).replace('%s', sessionFileSummary(session));
}

/** 构建活跃会话明细行（方向 + 对端名 + 文件名/数量）。 */
export function buildSessionDetailLines(sessions: Array<TransferSession>): Array<string> {
  let lines: Array<string> = [];
  for (let i = 0; i < sessions.length; i++) {
    lines.push(buildSessionDetailLine(sessions[i]));
  }
  return lines;
}

/** 逐会话中断（落取消终态；声明不可取消的会话由 cancel 内部跳过）。 */
export function cancelSessions(sessions: Array<TransferSession>): void {
  for (let i = 0; i < sessions.length; i++) {
    cancel(sessions[i].id);
  }
}

/**
 * 关闭方向前确认。
 * - 无活跃会话：直接回调 onConfirmed（空列表），不弹窗；
 * - 有活跃会话：弹窗列出明细，确认后回调 onConfirmed（会话列表），取消时回调 onCancelled。
 */
export function confirmDisableDirection(label: string, sessionKeys: Array<string>,
  onConfirmed: (sessions: Array<TransferSession>) => void, onCancelled?: () => void): void {
  let active: Array<TransferSession> = listActiveSessionsByProtocolKeys(sessionKeys);
  if (active.length === 0) {
    onConfirmed(active);
    return;
  }
  DialogService.showProtocolDisableConfirmDialog(label, buildSessionDetailLines(active),
    (confirmed: boolean) => {
      if (confirmed) {
        onConfirmed(active);
      } else if (onCancelled !== undefined) {
        onCancelled();
      }
    });
}
