/**
 * SettingsGroupRegistry.ets — 设置分组注册表
 *
 * 设置页 = 固定顺序的通用分组 + 由协议注册的协议分组。
 * 每个协议注册自己的设置分组；新增协议无需修改设置页结构。
 */

import { SettingGroupDescriptor } from '../../model/transfer/Registries';

const groupMap: Map<string, SettingGroupDescriptor> = new Map();
const groupOrder: Array<string> = [];

/** 注册设置分组（同键重复注册以最后一次为准）。 */
export function registerSettingsGroup(descriptor: SettingGroupDescriptor): void {
  if (groupMap.get(descriptor.key) === undefined) {
    groupOrder.push(descriptor.key);
  }
  groupMap.set(descriptor.key, descriptor);
}

/**
 * 列举全部设置分组（按 order 升序；order 相同时保持注册先后）。
 * 通用组与协议组按同一个 order 序列混排，以支持「设备通用信息 → 通用 → 协议组 → 外观 → 更多」的
 * 按使用频率顺序；新增协议仍只需注册自己的分组，页面结构零改动。
 */
export function listSettingsGroups(): Array<SettingGroupDescriptor> {
  let all: Array<SettingGroupDescriptor> = [];
  for (let i = 0; i < groupOrder.length; i++) {
    let descriptor = groupMap.get(groupOrder[i]);
    if (descriptor !== undefined) {
      all.push(descriptor);
    }
  }
  all.sort((a: SettingGroupDescriptor, b: SettingGroupDescriptor): number => a.order - b.order);
  return all;
}

/** 清空注册表（仅测试使用）。 */
export function clearSettingsGroups(): void {
  groupMap.clear();
  groupOrder.splice(0, groupOrder.length);
}
