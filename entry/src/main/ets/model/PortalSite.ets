/**
 * PortalSite.ets — 远程传输站点模型与纯逻辑。
 *
 * 站点来源分两类：随应用发布的预设（builtin）与用户手动添加（非 builtin）。
 * 预设可被远程配置文件整体更新；用户删除过的预设记入 dismissed，
 * 日常同步不复活，只有「恢复默认」才清空。
 *
 * 本文件不访问存储与网络，便于设备端用例直接覆盖校验、合并与排序。
 */

import { readJsonArray, readJsonNumber, readJsonString } from '../utils/JsonGuard';

/** 配置结构版本，不匹配时整体丢弃。 */
export const PORTAL_SCHEMA_VERSION: number = 1;

/** 徽标键：免登录。 */
export const PORTAL_BADGE_NO_LOGIN: string = 'no-login';
/** 徽标键：需要登录。 */
export const PORTAL_BADGE_LOGIN: string = 'login';
/** 徽标键：浏览器之间点对点传输，文件不经过站点服务器。 */
export const PORTAL_BADGE_P2P: string = 'p2p';
/** 徽标键：支持大文件。 */
export const PORTAL_BADGE_LARGE_FILE: string = 'large-file';
/** 徽标键：分享临时有效。 */
export const PORTAL_BADGE_TEMPORARY: string = 'temporary';

/** 允许的徽标键；远程配置只接受这些值。 */
export const PORTAL_KNOWN_BADGES: Array<string> = [
  PORTAL_BADGE_NO_LOGIN,
  PORTAL_BADGE_LOGIN,
  PORTAL_BADGE_P2P,
  PORTAL_BADGE_LARGE_FILE,
  PORTAL_BADGE_TEMPORARY
];

/** 站点数量上限，避免远程配置无限膨胀。 */
const MAX_SITES: number = 30;
/** 显示名称长度上限。 */
const MAX_NAME_LENGTH: number = 40;
/** 地址长度上限。 */
const MAX_URL_LENGTH: number = 512;

/** 单个站点。 */
export interface PortalSite {
  id: string;
  name: string;
  url: string;
  badges: Array<string>;
  builtin: boolean;
  order: number;
}

/** 远程或内置配置的整体结构。 */
export interface PortalSiteConfig {
  schemaVersion: number;
  sites: Array<PortalSite>;
}

/** 地址规范化：只接受带主机名的 http(s) 地址，其余一律返回空串。 */
export function normalizePortalUrl(raw: string): string {
  let value: string = raw.trim();
  if (value.length === 0 || value.length > MAX_URL_LENGTH) {
    return '';
  }
  let lower: string = value.toLowerCase();
  let rest: string = '';
  if (lower.startsWith('https://')) {
    rest = value.substring(8);
  } else if (lower.startsWith('http://')) {
    rest = value.substring(7);
  } else {
    return '';
  }
  // 拒绝空白与控制字符：URL 中出现它们通常意味着粘贴了多余内容
  for (let i = 0; i < value.length; i++) {
    if (value.charCodeAt(i) <= 32) {
      return '';
    }
  }
  let slash: number = rest.indexOf('/');
  let host: string = slash >= 0 ? rest.substring(0, slash) : rest;
  if (host.length === 0 || host.startsWith('.')) {
    return '';
  }
  // 拒绝 userinfo，避免 https://user:pass@host 形式误导用户
  if (host.indexOf('@') >= 0) {
    return '';
  }
  return value;
}

/** 显示名称规范化：去首尾空白与控制字符，超长截断。 */
export function sanitizePortalName(raw: string): string {
  let value: string = '';
  for (let i = 0; i < raw.length; i++) {
    let code: number = raw.charCodeAt(i);
    if (code >= 32 && code !== 127) {
      value += raw.charAt(i);
    }
  }
  value = value.trim();
  return value.length > MAX_NAME_LENGTH ? value.substring(0, MAX_NAME_LENGTH) : value;
}

/** 徽标清洗：只保留已知键，去重并按固定顺序输出。 */
export function sanitizePortalBadges(raw: Array<Object>): Array<string> {
  let present: Array<string> = [];
  for (let i = 0; i < raw.length; i++) {
    let item: Object = raw[i];
    if (typeof item !== 'string') {
      continue;
    }
    if (PORTAL_KNOWN_BADGES.indexOf(item) >= 0 && present.indexOf(item) < 0) {
      present.push(item);
    }
  }
  let result: Array<string> = [];
  for (let i = 0; i < PORTAL_KNOWN_BADGES.length; i++) {
    if (present.indexOf(PORTAL_KNOWN_BADGES[i]) >= 0) {
      result.push(PORTAL_KNOWN_BADGES[i]);
    }
  }
  return result;
}

/** 按 order 升序排列；同序时保持输入顺序。 */
export function sortPortalSites(sites: Array<PortalSite>): Array<PortalSite> {
  let result: Array<PortalSite> = sites.slice(0);
  result.sort((a: PortalSite, b: PortalSite): number => a.order - b.order);
  return result;
}

/** 解析配置文件；结构不合法、版本不匹配或没有任何有效站点时返回 undefined。 */
export function parsePortalSiteConfig(text: string): PortalSiteConfig | undefined {
  let parsed: Object;
  try {
    parsed = JSON.parse(text);
  } catch (_e) {
    return undefined;
  }
  let version: number = readJsonNumber(parsed, 'schemaVersion', 0);
  if (version !== PORTAL_SCHEMA_VERSION) {
    return undefined;
  }
  let rawSites: Array<Object> = readJsonArray(parsed, 'sites');
  let sites: Array<PortalSite> = [];
  for (let i = 0; i < rawSites.length && sites.length < MAX_SITES; i++) {
    let item: Object = rawSites[i];
    let id: string = readJsonString(item, 'id', '').trim();
    let name: string = sanitizePortalName(readJsonString(item, 'name', ''));
    let url: string = normalizePortalUrl(readJsonString(item, 'url', ''));
    if (id.length === 0 || name.length === 0 || url.length === 0) {
      continue;
    }
    // 同 id 重复条目只保留第一条
    let duplicated: boolean = false;
    for (let j = 0; j < sites.length; j++) {
      if (sites[j].id === id) {
        duplicated = true;
        break;
      }
    }
    if (duplicated) {
      continue;
    }
    let site: PortalSite = {
      id: id,
      name: name,
      url: url,
      badges: sanitizePortalBadges(readJsonArray(item, 'badges')),
      builtin: true,
      order: readJsonNumber(item, 'order', i * 10)
    };
    sites.push(site);
  }
  if (sites.length === 0) {
    return undefined;
  }
  return { schemaVersion: version, sites: sites };
}

/**
 * 合并预设与用户站点。
 * 结果 = 远程预设（排除已删除） + 本地用户站点，按 order 排序。
 * 预设以远程为准，用户站点不受影响。
 */
export function mergePortalSites(local: Array<PortalSite>, presets: Array<PortalSite>,
  dismissed: Array<string>): Array<PortalSite> {
  let result: Array<PortalSite> = [];
  for (let i = 0; i < presets.length; i++) {
    if (dismissed.indexOf(presets[i].id) < 0) {
      result.push(presets[i]);
    }
  }
  for (let i = 0; i < local.length; i++) {
    if (!local[i].builtin) {
      result.push(local[i]);
    }
  }
  return sortPortalSites(result);
}

/** 判断两组站点是否等价（id、名称、地址、徽标、顺序一致）。 */
export function samePortalSites(a: Array<PortalSite>, b: Array<PortalSite>): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i].id !== b[i].id || a[i].name !== b[i].name || a[i].url !== b[i].url ||
      a[i].order !== b[i].order || a[i].builtin !== b[i].builtin ||
      a[i].badges.join(',') !== b[i].badges.join(',')) {
      return false;
    }
  }
  return true;
}

/** 生成用户站点标识：时间戳 + 随机后缀，进程内足够唯一。 */
export function generatePortalSiteId(now: number): string {
  let random: number = Math.floor(Math.random() * 1679616);
  return 'u' + now.toString(36) + random.toString(36);
}

/** 下一个用户站点排序值：追加在预设之后，间距 10 便于插入。 */
export function nextPortalSiteOrder(sites: Array<PortalSite>): number {
  let maxOrder: number = 999;
  for (let i = 0; i < sites.length; i++) {
    if (sites[i].order > maxOrder) {
      maxOrder = sites[i].order;
    }
  }
  return maxOrder + 10;
}

/** 解析逗号分隔的已删除预设标识；空串返回空数组。 */
export function parseDismissedIds(text: string): Array<string> {
  let result: Array<string> = [];
  let parts: Array<string> = text.split(',');
  for (let i = 0; i < parts.length; i++) {
    let id: string = parts[i].trim();
    if (id.length > 0 && result.indexOf(id) < 0) {
      result.push(id);
    }
  }
  return result;
}
