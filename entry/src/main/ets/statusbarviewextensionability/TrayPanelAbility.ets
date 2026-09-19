/**
 * TrayPanelAbility.ets — 状态栏图标左键弹窗的扩展 Ability
 *
 * 继承 StatusBarViewExtensionAbility，onSessionCreate 加载 pages/StatusBarPage。
 * 应用内 extensionAbility 未配置独立进程，与主 UIAbility 同进程运行，
 * StatusBarPage 直接读取 AppCore/聚合快照单例（无需进程间通信）。
 */

import { StatusBarViewExtensionAbility } from '@kit.DeskTopExtensionKit';
import { UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TrayPanelAbility', '托盘面板');

export default class TrayPanelAbility extends StatusBarViewExtensionAbility {
  onCreate(): void {
    logger.debug('TrayPanelAbility onCreate');
  }

  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    logger.debug('TrayPanelAbility onSessionCreate');
    session.loadContent('pages/StatusBarPage');
  }

  onSessionDestroy(session: UIExtensionContentSession): void {
    logger.debug('TrayPanelAbility onSessionDestroy');
  }

  onDestroy(): void {
    logger.debug('TrayPanelAbility onDestroy');
  }
}
