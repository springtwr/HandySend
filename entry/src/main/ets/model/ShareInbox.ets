/**
 * ShareInbox.ets — 外部分享收件箱的纯逻辑
 *
 * 负责系统分享进来的 URI/文本的解析、合并与上限截断。
 * 上限只约束“代码收件箱”，系统分享面板是否展示应用由 module.json5 的
 * maxFileSupported 决定，两者应保持同一量级。
 */

import { readJsonString } from '../utils/JsonGuard';

/**
 * 单次分享/多次分享合并后最多保留的文件或文件夹数量。
 * Share Kit 数据记录上限为 500 项，清单与代码统一取 500；
 * 模拟器“最多可选 100 个文件”是模拟器文件选择器限制，不是系统分享上限。
 */
export const SHARE_MAX_ITEMS: number = 500;
/** 文本分享最多保留的条目数。 */
export const SHARE_MAX_TEXTS: number = 20;
/** 文本分享最多保留的总字符数。 */
export const SHARE_MAX_TEXT_CHARS: number = 200000;

export interface ShareMergeResult {
  json: string;
  truncatedCount: number;
}

/** 解析 URI 数组 JSON：非数组/脏数据返回空数组。 */
export function parseShareUriList(json: string): Array<string> {
  if (json.length === 0) {
    return [];
  }
  try {
    let parsed: Object = JSON.parse(json);
    if (!Array.isArray(parsed)) {
      return [];
    }
    let raw: Array<Object> = parsed as Array<Object>;
    let result: Array<string> = [];
    for (let i = 0; i < raw.length; i++) {
      if (typeof raw[i] === 'string') {
        result.push(raw[i] as string);
      }
    }
    return result;
  } catch (_e) {
    return [];
  }
}

/** 解析文本记录数组 JSON：字段缺失或类型不符的条目按空串补齐。 */
export function parseShareTextList(json: string): Array<Record<string, string>> {
  let result: Array<Record<string, string>> = [];
  if (json.length === 0) {
    return result;
  }
  try {
    let parsed: Object = JSON.parse(json);
    if (!Array.isArray(parsed)) {
      return result;
    }
    let raw: Array<Object> = parsed as Array<Object>;
    for (let i = 0; i < raw.length; i++) {
      let content: string = readJsonString(raw[i], 'content', '');
      let title: string = readJsonString(raw[i], 'title', '');
      let utd: string = readJsonString(raw[i], 'utd', '');
      let record: Record<string, string> = {
        'content': content,
        'title': title,
        'utd': utd
      };
      result.push(record);
    }
  } catch (_e) {
  }
  return result;
}

/** 文本条数与总字符双上限截断；返回截断条数。 */
export function truncateShareTexts(texts: Array<Record<string, string>>): ShareMergeResult {
  let capped: Array<Record<string, string>> = texts.slice(0, SHARE_MAX_TEXTS);
  let total: number = 0;
  let kept: number = 0;
  for (let i = 0; i < capped.length; i++) {
    total = total + capped[i]['content'].length + capped[i]['title'].length;
    if (total > SHARE_MAX_TEXT_CHARS) {
      // 与旧逻辑一致：至少保留 1 条，避免整批文本被清空
      kept = i > 0 ? i : 1;
      break;
    }
    kept = i + 1;
  }
  let result: Array<Record<string, string>> = capped.slice(0, kept);
  return {
    json: JSON.stringify(result),
    truncatedCount: texts.length - result.length
  };
}

/** 未消费 pending 与本次新增合并（去重后按上限截断）。 */
export function mergeShareUriJson(prevJson: string, nextJson: string): ShareMergeResult {
  let merged: Array<string> = parseShareUriList(prevJson);
  let incoming: Array<string> = parseShareUriList(nextJson);
  for (let i = 0; i < incoming.length; i++) {
    if (!merged.includes(incoming[i])) {
      merged.push(incoming[i]);
    }
  }
  let total: number = merged.length;
  if (merged.length > SHARE_MAX_ITEMS) {
    merged = merged.slice(0, SHARE_MAX_ITEMS);
  }
  return {
    json: JSON.stringify(merged),
    truncatedCount: total - merged.length
  };
}

/** 未消费 pending 与本次新增文本合并，再按条数/字符双上限截断。 */
export function mergeShareTextJson(prevJson: string, nextJson: string): ShareMergeResult {
  let merged: Array<Record<string, string>> = parseShareTextList(prevJson);
  let incoming: Array<Record<string, string>> = parseShareTextList(nextJson);
  for (let i = 0; i < incoming.length; i++) {
    merged.push(incoming[i]);
  }
  return truncateShareTexts(merged);
}
