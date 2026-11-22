/**
 * LocalSendRestartGuard.ets — LocalSend 服务重启前的传输确认
 *
 * 重启 LocalSend 服务会中断进行中的 LocalSend 收发传输；MTA 与网页服务
 * 独立运行，不受影响。设置页重启入口与壳层待生效提示卡共用本逻辑：
 * 无进行中传输直接执行；有则提示“LocalSend 传输将会中断”，确认后中断。
 *
 * 确认弹窗由壳层组件注册 presenter 打开：DialogV2 的 builder 形式必须绑定
 * 组件上下文，不能在非 UI 服务里直接构建。
 */

import { cancel, listActiveSessionsByProtocolKeys } from './TransferSessionRegistry';
import { LOCAL_SEND_KEY } from './adapters/LocalSendSendAdapter';
import { LOCAL_RECEIVE_KEY } from './adapters/LocalSendReceiveAdapter';
import { TransferSession } from '../../model/transfer/TransferSession';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:LocalSendRestartGuard', '设置待生效');
const LOCAL_SEND_KEYS: Array<string> = [LOCAL_SEND_KEY, LOCAL_RECEIVE_KEY];
// 确认弹窗是否已打开：避免连续点击重启入口叠出多个弹窗
let confirming: boolean = false;
// 确认弹窗宿主：由主页壳层组件注册，负责打开 DialogV2 并在用户选择后回调
export type LocalSendRestartConfirmPresenter = (onResult: (confirmed: boolean) => void) => void;
let presenter: LocalSendRestartConfirmPresenter | undefined = undefined;

/** 注册/注销确认弹窗宿主（主页壳层挂载时注册，卸载时注销）。 */
export function setLocalSendRestartConfirmPresenter(value: LocalSendRestartConfirmPresenter): void {
  presenter = value;
}

export function clearLocalSendRestartConfirmPresenter(): void {
  presenter = undefined;
}

/**
 * 询问是否继续重启：无进行中 LocalSend 传输时直接返回 true；
 * 有传输时由壳层弹窗提示并等待确认，确认后中断这些传输并返回 true。
 */
export function confirmLocalSendRestart(): Promise<boolean> {
  if (listActiveSessionsByProtocolKeys(LOCAL_SEND_KEYS).length === 0) {
    return Promise.resolve(true);
  }
  if (confirming) {
    return Promise.resolve(false);
  }
  if (presenter === undefined) {
    logger.warn('重启确认缺少 UI 宿主，按取消处理');
    return Promise.resolve(false);
  }
  let confirmPresenter: LocalSendRestartConfirmPresenter = presenter;
  confirming = true;
  return new Promise<boolean>((resolve: (confirmed: boolean) => void): void => {
    try {
      confirmPresenter((confirmed: boolean): void => {
        confirming = false;
        if (!confirmed) {
          resolve(false);
          return;
        }
        // 弹窗期间可能新增会话：确认后重新取活跃会话一并中断，避免重启后悬挂
        let active: Array<TransferSession> = listActiveSessionsByProtocolKeys(LOCAL_SEND_KEYS);
        for (let i = 0; i < active.length; i++) {
          cancel(active[i].id);
        }
        resolve(true);
      });
    } catch (e) {
      // 弹窗打开失败时按取消处理，并复位标记避免后续重启入口永久失效
      confirming = false;
      logger.warn('重启确认弹窗打开失败：' + String(e));
      resolve(false);
    }
  });
}
