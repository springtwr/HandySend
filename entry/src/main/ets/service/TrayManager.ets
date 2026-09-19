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
import { subscribe as subscribeTransferChanges } from './repository/AppCore';
import {
  gatherSessionSnapshots,
  resolveTerminalKind,
  TransferTerminalKind,
  throttleDelayMs
} from './BackgroundTransferService';
import {
  computeOverallTransferSnapshot,
  OverallTransferSnapshot,
  TransferSessionSnapshot
} from '../utils/TransferProgressUtil';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TrayManager', '托盘');

// 图标是否已接入状态栏（addToStatusBar 幂等标志；重复添加无效）
let trayIconAdded: boolean = false;

// hover 文案刷新间隔（与通知发布节流同频）
const HOVER_UPDATE_INTERVAL_MS = 1000;

// hover 进度订阅状态（模块级单例，进程生命周期内订阅一次）
let hoverContext: common.UIAbilityContext | null = null;
let hoverSubscribed: boolean = false;
let lastHoverUpdateMs: number = -1;
let hoverTimer: number = -1;
let lastHoverText: string = '';

/**
 * hover 文案决策（纯函数）：
 * - 有活跃会话 → "传输中 xx%"（百分比四舍五入取整）；
 * - 全部终态 → 按成败取 完成/失败/部分失败 文案；
 * - 无会话（输入为空）返回空串，调用方跳过更新。
 */
export function buildTrayHoverText(snapshots: Array<TransferSessionSnapshot>,
  overall: OverallTransferSnapshot,
  activeLabel: string, doneLabel: string, failedLabel: string, partialLabel: string): string {
  if (overall.active) {
    return activeLabel + ' ' + Math.round(overall.percent) + '%';
  }
  if (!overall.allFinished) {
    return '';
  }
  let allFailed: boolean = true;
  for (let i = 0; i < snapshots.length; i++) {
    if (!snapshots[i].active && snapshots[i].success) {
      allFailed = false;
      break;
    }
  }
  let kind: TransferTerminalKind = resolveTerminalKind(overall.hasFailure, allFailed);
  if (kind === TransferTerminalKind.failed) {
    return failedLabel;
  }
  if (kind === TransferTerminalKind.partial) {
    return partialLabel;
  }
  return doneLabel;
}

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
    // 清理 hover 刷新状态，下次接入从当前快照重新发布
    lastHoverText = '';
    lastHoverUpdateMs = -1;
    if (hoverTimer >= 0) {
      clearTimeout(hoverTimer);
      hoverTimer = -1;
    }
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

// 读取最新聚合快照并发布 hover 文案；文案未变化（含无会话）时跳过
function refreshAndPublishHover(context: common.UIAbilityContext): void {
  let snapshots = gatherSessionSnapshots();
  let overall = computeOverallTransferSnapshot(snapshots, 0);
  let text: string = buildTrayHoverText(snapshots, overall,
    context.resourceManager.getStringSync($r('app.string.bg_transfer_title').id),
    context.resourceManager.getStringSync($r('app.string.bg_transfer_title_done').id),
    context.resourceManager.getStringSync($r('app.string.bg_transfer_title_failed').id),
    context.resourceManager.getStringSync($r('app.string.bg_transfer_title_partial').id));
  if (text === '' || text === lastHoverText) {
    return;
  }
  lastHoverUpdateMs = Date.now();
  lastHoverText = text;
  updateHoverTips(context, text);
}

// changeBus 回调：1s 节流，pending 定时器到期时重读最新快照（同帧合并）
function onTrayTransferChanged(): void {
  let context = hoverContext;
  if (context === null || !trayIconAdded) {
    return;
  }
  let delay = throttleDelayMs(Date.now(), lastHoverUpdateMs, HOVER_UPDATE_INTERVAL_MS);
  if (delay === 0) {
    refreshAndPublishHover(context);
    return;
  }
  if (hoverTimer < 0) {
    hoverTimer = setTimeout(() => {
      hoverTimer = -1;
      let ctx = hoverContext;
      if (ctx !== null && trayIconAdded) {
        refreshAndPublishHover(ctx);
      }
    }, delay);
  }
}

/**
 * 启动 hover 进度刷新（幂等）：订阅 changeBus 并立即按当前快照刷一次
 * （接入图标后 hover 从静态"传输中"变为带百分比的实时文案）。
 * 全部会话终态后文案停留"传输完成"，图标保留至进程退出，由用户经
 * 托盘右键"退出"/重新打开应用自行处置。
 */
export function startTrayHoverUpdates(context: common.UIAbilityContext): void {
  hoverContext = context;
  if (!hoverSubscribed) {
    hoverSubscribed = true;
    subscribeTransferChanges(onTrayTransferChanged);
  }
  if (trayIconAdded) {
    refreshAndPublishHover(context);
  }
}
