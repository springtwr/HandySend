/**
 * SendTextPreparation.ets — 发送页手动文本相关的纯函数
 *
 * 提供两项共享判定，供发送链路复用：
 * 1. 从发送页的暂存条目集合中筛出「手动文本」条目并产出其源定位列表，供发送条目
 *    准备入口按来源补设文本消息内容信息（preview）。发送页的预准备缓存路径与
 *    网页分享路径（SendViewModel）均调用此处，不再各自维护筛选循环。
 * 2. 判定暂存条目集合是否「全部为手动文本」，供局域网发送参数构建与互传联盟发送
 *    参数构建复用，不再各自累算。
 * 手动文本仅指用户手动输入、粘贴或分享的文本；用户主动选择的 `.txt` 文件不带
 * 来源标记，一律排除。
 * 仅依赖 model/Types 的类型声明，无 ArkUI / 系统 API / 原生桥接依赖，可脱离运行时单测。
 */

import { StagedFile } from './Types';

/**
 * 筛出手动文本条目的源定位列表（纯函数，不修改入参）。
 *
 * 仅收集来源标记为手动文本（`isManualText === true`）的条目，结果保持输入的相对顺序；
 * 未标记来源的条目（如选择器选取的文件）一律排除；空集合输入返回空集合，不抛异常。
 */
export function collectManualTextUris(stagedFiles: Array<StagedFile>): Array<string> {
  let uris: Array<string> = [];
  for (let i = 0; i < stagedFiles.length; i++) {
    if (stagedFiles[i].isManualText === true) {
      uris.push(stagedFiles[i].uri);
    }
  }
  return uris;
}

/**
 * 判定暂存条目集合是否「全部为手动文本」（纯函数，不修改入参）。
 *
 * 集合非空且每个条目的来源标记均为手动文本（`isManualText === true`）时返回真；
 * 空集合返回假（沿用既有约定：没有内容不视为文本发送；两条调用路径均在空集合时
 * 提前返回，此分支为防御性定义并由本地纯函数用例锁定）；存在任一未标记来源的
 * 条目（`undefined` 或显式 `false`）即返回假。
 */
export function isAllManualText(stagedFiles: Array<StagedFile>): boolean {
  if (stagedFiles.length === 0) {
    return false;
  }
  for (let i = 0; i < stagedFiles.length; i++) {
    if (stagedFiles[i].isManualText !== true) {
      return false;
    }
  }
  return true;
}
