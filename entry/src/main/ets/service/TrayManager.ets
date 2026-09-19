/**
 * TrayManager.ets — PC/2in1 系统托盘（状态栏图标）管理
 *
 * 基于 Desktop Extension Kit statusBarManager：
 * - 传输中最小化时接入状态栏图标（hover 提示 + 左键进度弹窗 + 右键菜单）；
 * - 图标资源为 rawfile 双主题单色剪影（tray_white/tray_black，24vp 建议）；
 * - 该能力仅中国境内 PC/2in1 生效，境外调用抛错 → ensureTrayIcon 返回 false
 *   由调用方决定回退（正常退出），不影响传输本身。
 *
 * 模块级单例组织方式与 BackgroundTransferService 一致。
 */

import { statusBarManager } from '@kit.DeskTopExtensionKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TrayManager', '托盘');

// 图标是否已接入状态栏（addToStatusBar 幂等标志；重复添加无效）
let trayIconAdded: boolean = false;

// 从 rawfile 加载单色图标为 PixelMap
async function loadTrayPixelMap(context: common.UIAbilityContext, fileName: string): Promise<image.PixelMap> {
  let fileData = context.resourceManager.getRawFileContentSync(fileName);
  let imageSource: image.ImageSource = image.createImageSource(fileData.buffer);
  return imageSource.createPixelMap();
}

/**
 * 接入状态栏图标（幂等）。成功返回 true；失败（境外/非 PC/能力不可用）返回 false。
 * hover 初始提示为"传输中"，此后由 updateHoverTips 随进度刷新（T15）。
 */
export async function ensureTrayIcon(context: common.UIAbilityContext): Promise<boolean> {
  if (trayIconAdded) {
    return true;
  }
  try {
    let white: image.PixelMap = await loadTrayPixelMap(context, 'tray_white.png');
    let black: image.PixelMap = await loadTrayPixelMap(context, 'tray_black.png');
    let icons: statusBarManager.StatusBarIcon = {
      white: white,
      black: black
    };
    // 右键菜单：自定义"打开 HandySend"（拉起主界面），系统自动追加"退出"项
    let openAction: statusBarManager.StatusBarMenuAction = {
      abilityName: 'EntryAbility'
    };
    let menuItem: statusBarManager.StatusBarMenuItem = {
      title: context.resourceManager.getStringSync($r('app.string.tray_open_app').id),
      menuAction: openAction
    };
    let groupMenus: Array<statusBarManager.StatusBarGroupMenu> = [];
    groupMenus.push([menuItem]);
    // 左键弹窗：TrayPanelAbility 加载 pages/StatusBarPage 渲染聚合进度
    let operation: statusBarManager.QuickOperation = {
      abilityName: 'TrayPanelAbility',
      title: 'HandySend',
      height: 240,
      moduleName: 'entry'
    };
    let item: statusBarManager.StatusBarItem = {
      icons: icons,
      quickOperation: operation,
      statusBarGroupMenu: groupMenus,
      hoverTips: context.resourceManager.getStringSync($r('app.string.bg_transfer_title').id)
    };
    statusBarManager.addToStatusBar(context, item);
    trayIconAdded = true;
    logger.info('tray icon added to status bar');
    return true;
  } catch (e) {
    // 境外/非 PC/2in1/能力不可用：按调用方回退策略处理，不中断传输
    logger.warn('addToStatusBar failed: ' + JSON.stringify(e));
    return false;
  }
}

/**
 * 移除状态栏图标（幂等）。托盘"退出"/无传输正常退出等场景调用；
 * 进程退出时图标随进程自动消失，此处用于显式清理。
 */
export function removeTrayIcon(context: common.UIAbilityContext): void {
  if (!trayIconAdded) {
    return;
  }
  try {
    statusBarManager.removeFromStatusBar(context);
    trayIconAdded = false;
    logger.info('tray icon removed from status bar');
  } catch (e) {
    logger.warn('removeFromStatusBar failed: ' + JSON.stringify(e));
  }
}

/**
 * 更新图标 hover 提示文本（长度 1~128）。未接入图标时为空操作。
 */
export async function updateHoverTips(context: common.UIAbilityContext, text: string): Promise<void> {
  if (!trayIconAdded) {
    return;
  }
  try {
    await statusBarManager.updateStatusBarHoverTips(context, text);
  } catch (e) {
    logger.warn('updateHoverTips failed: ' + JSON.stringify(e));
  }
}

/**
 * 是否支持状态栏能力（API 26+）。返回 false 表示境外/能力不可用，
 * 调用方（关闭拦截）应回退为正常退出。
 * API 23–25 无此接口：调用抛异常时无法探测，按境内处理返回 true。
 */
export async function isTrayCapabilitySupported(context: common.UIAbilityContext): Promise<boolean> {
  try {
    return await statusBarManager.isStatusBarCapabilitySupported(context);
  } catch (e) {
    logger.info('isStatusBarCapabilitySupported unavailable, assume supported: ' + JSON.stringify(e));
    return true;
  }
}
