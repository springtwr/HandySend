/**
 * PortalSiteRepository.ets — 在线服务站点数据访问层。
 *
 * 站点全部本地化：预设来自随包内置的 rawfile 配置，用户站点与编辑覆盖存于偏好存储。
 * 不发起网络请求，也不提供网页内容服务；点击卡片由页面交给系统浏览器打开。
 *
 * 「恢复默认」清空用户删除记录与编辑覆盖，重新读取内置预设。
 */

import { util } from '@kit.ArkTS';
import {
  preferencesUtil,
  KEY_PORTAL_USER_SITES,
  KEY_PORTAL_PRESET_OVERRIDES,
  KEY_PORTAL_DISMISSED,
  KEY_PORTAL_RISK_ACCEPTED
} from '../../utils/PreferencesUtil';
import { getAppContext, notifyChange, subscribe, unsubscribe } from './AppCore';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import {
  PortalSite,
  PortalSiteConfig,
  mergePortalSites,
  normalizePortalUrl,
  parseDismissedIds,
  parsePortalSiteConfig,
  sanitizePortalName
} from '../../model/PortalSite';

const logger = getLogger(LogDomains.SETTINGS, 'HandySend:PortalSite', '在线服务');

/** 随包内置的推荐站点配置。 */
const BUILTIN_CONFIG_FILE: string = 'portal_sites.json';

/** 站点点数上限。 */
const MAX_SITES: number = 30;

// 用户添加的站点
let userSites: Array<PortalSite> = [];
// 随包内置预设
let presetConfig: PortalSiteConfig | undefined = undefined;
// 用户编辑过的预设副本（按 id 替换内置条目）
const presetOverrides: Map<string, PortalSite> = new Map();
// 已删除的预设标识
let dismissed: Array<string> = [];
// 合并后的对外快照（预设 + 用户站点）
let sites: Array<PortalSite> = [];
let initialized: boolean = false;

/** 把任意外部 JSON 解析为用户站点（builtin 一律为 false）。 */
function parseUserSites(text: string): Array<PortalSite> {
  let config: PortalSiteConfig | undefined = parsePortalSiteConfig(text);
  if (config === undefined) {
    return [];
  }
  let result: Array<PortalSite> = [];
  for (let i = 0; i < config.sites.length; i++) {
    let item: PortalSite = config.sites[i];
    let site: PortalSite = {
      id: item.id,
      name: item.name,
      url: item.url,
      badges: item.badges,
      builtin: false,
      order: item.order
    };
    result.push(site);
  }
  return result;
}

/** 读取随包内置配置。 */
function readBundledConfig(): PortalSiteConfig | undefined {
  let context = getAppContext();
  if (context === undefined) {
    return undefined;
  }
  try {
    let bytes: Uint8Array = context.resourceManager.getRawFileContentSync(BUILTIN_CONFIG_FILE);
    let text: string = new util.TextDecoder().decodeToString(bytes);
    return parsePortalSiteConfig(text);
  } catch (e) {
    logger.warn('读取内置站点配置失败：' + String(e));
    return undefined;
  }
}

/** 持久化预设覆盖。 */
function persistOverrides(): void {
  let list: Array<PortalSite> = [];
  presetOverrides.forEach((site: PortalSite): void => {
    list.push(site);
  });
  preferencesUtil.setString(KEY_PORTAL_PRESET_OVERRIDES,
    JSON.stringify({ schemaVersion: 1, sites: list }));
}

/** 按用户站点、预设（含覆盖）与删除记录重建对外快照。 */
function rebuild(): void {
  let presets: Array<PortalSite> = presetConfig !== undefined ? presetConfig.sites : [];
  let effective: Array<PortalSite> = [];
  for (let i = 0; i < presets.length; i++) {
    let override: PortalSite | undefined = presetOverrides.get(presets[i].id);
    effective.push(override !== undefined ? override : presets[i]);
  }
  sites = mergePortalSites(userSites, effective, dismissed);
}

/** 首次访问：加载内置预设，并从偏好存储恢复用户站点、覆盖与删除记录。 */
function ensureInitialized(): void {
  if (initialized) {
    return;
  }
  initialized = true;
  presetConfig = readBundledConfig();
  userSites = parseUserSites(preferencesUtil.getString(KEY_PORTAL_USER_SITES, ''));
  dismissed = parseDismissedIds(preferencesUtil.getString(KEY_PORTAL_DISMISSED, ''));
  let overrideText: string = preferencesUtil.getString(KEY_PORTAL_PRESET_OVERRIDES, '');
  let overrideConfig: PortalSiteConfig | undefined = parsePortalSiteConfig(overrideText);
  if (overrideConfig !== undefined) {
    for (let i = 0; i < overrideConfig.sites.length; i++) {
      presetOverrides.set(overrideConfig.sites[i].id, overrideConfig.sites[i]);
    }
  }
  rebuild();
}

function persistUserSites(): void {
  preferencesUtil.setString(KEY_PORTAL_USER_SITES, JSON.stringify({ schemaVersion: 1, sites: userSites }));
}

function persistDismissed(): void {
  preferencesUtil.setString(KEY_PORTAL_DISMISSED, dismissed.join(','));
}

/** 是否已确认首次进入远程传输页的风险声明。 */
export function isPortalRiskAccepted(): boolean {
  return preferencesUtil.getBoolean(KEY_PORTAL_RISK_ACCEPTED, false);
}

/** 记录风险声明已确认；立即落盘，避免覆盖安装或强杀时丢失。 */
export function acceptPortalRisk(): void {
  preferencesUtil.setBoolean(KEY_PORTAL_RISK_ACCEPTED, true);
  preferencesUtil.flushNow();
}

/** 当前站点快照（预设在前，用户站点在后）。 */
export function getPortalSites(): Array<PortalSite> {
  ensureInitialized();
  return sites.slice(0);
}

/** 订阅站点变化（复用全局变更总线）。 */
export function subscribePortalSites(callback: () => void): void {
  subscribe(callback);
}

export function unsubscribePortalSites(callback: () => void): void {
  unsubscribe(callback);
}

/** 添加用户站点；返回空串表示成功，否则为错误标识。 */
export function addPortalSite(name: string, url: string, badges: Array<string>): string {
  ensureInitialized();
  let siteName: string = sanitizePortalName(name);
  if (siteName.length === 0) {
    return 'name';
  }
  let siteUrl: string = normalizePortalUrl(url);
  if (siteUrl.length === 0) {
    return 'url';
  }
  if (sites.length >= MAX_SITES) {
    return 'full';
  }
  for (let i = 0; i < sites.length; i++) {
    if (sites[i].url === siteUrl) {
      return 'duplicate';
    }
  }
  let now: number = Date.now();
  let site: PortalSite = {
    id: 'u' + now.toString(36) + Math.floor(Math.random() * 1679616).toString(36),
    name: siteName,
    url: siteUrl,
    badges: badges,
    builtin: false,
    order: 1000 + userSites.length
  };
  userSites.push(site);
  persistUserSites();
  rebuild();
  notifyChange();
  return '';
}

/** 编辑站点；返回空串表示成功，否则为错误标识。预设的修改以覆盖形式保留。 */
export function updatePortalSite(id: string, name: string, url: string,
  badges: Array<string>): string {
  ensureInitialized();
  let siteName: string = sanitizePortalName(name);
  if (siteName.length === 0) {
    return 'name';
  }
  let siteUrl: string = normalizePortalUrl(url);
  if (siteUrl.length === 0) {
    return 'url';
  }
  let target: PortalSite | undefined = undefined;
  for (let i = 0; i < sites.length; i++) {
    if (sites[i].id === id) {
      target = sites[i];
      break;
    }
  }
  if (target === undefined) {
    return 'notfound';
  }
  for (let i = 0; i < sites.length; i++) {
    if (sites[i].id !== id && sites[i].url === siteUrl) {
      return 'duplicate';
    }
  }
  if (target.builtin) {
    let override: PortalSite = {
      id: target.id,
      name: siteName,
      url: siteUrl,
      badges: badges,
      builtin: true,
      order: target.order
    };
    presetOverrides.set(id, override);
    persistOverrides();
  } else {
    for (let i = 0; i < userSites.length; i++) {
      if (userSites[i].id === id) {
        userSites[i].name = siteName;
        userSites[i].url = siteUrl;
        userSites[i].badges = badges;
        break;
      }
    }
    persistUserSites();
  }
  rebuild();
  notifyChange();
  return '';
}

/** 删除站点：预设记入删除列表，用户站点直接移除。 */
export function removePortalSite(id: string): void {
  ensureInitialized();
  let target: PortalSite | undefined = undefined;
  for (let i = 0; i < sites.length; i++) {
    if (sites[i].id === id) {
      target = sites[i];
      break;
    }
  }
  if (target === undefined) {
    return;
  }
  if (target.builtin) {
    if (dismissed.indexOf(id) < 0) {
      dismissed.push(id);
      persistDismissed();
    }
    presetOverrides.delete(id);
    persistOverrides();
  } else {
    let next: Array<PortalSite> = [];
    for (let i = 0; i < userSites.length; i++) {
      if (userSites[i].id !== id) {
        next.push(userSites[i]);
      }
    }
    userSites = next;
    persistUserSites();
  }
  rebuild();
  notifyChange();
}

/**
 * 恢复默认：清空删除记录与编辑覆盖，重新读取内置预设，保留用户站点。
 * 返回 false 表示内置配置不可用（正常安装不会发生）。
 */
export function restoreDefaultPortalSites(): boolean {
  ensureInitialized();
  dismissed = [];
  persistDismissed();
  presetOverrides.clear();
  persistOverrides();
  presetConfig = readBundledConfig();
  rebuild();
  notifyChange();
  return presetConfig !== undefined;
}

/** 供测试与重置场景清空内存状态。 */
export function resetPortalSiteCache(): void {
  initialized = false;
  userSites = [];
  presetConfig = undefined;
  presetOverrides.clear();
  dismissed = [];
  sites = [];
}
