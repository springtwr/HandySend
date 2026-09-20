/**
 * DeviceSourceRegistry.ets — 设备来源注册表
 *
 * 每个协议注册一份来源描述符（唯一键、标签、图标、排序、发现数据源、
 * 空态与条件化引导、是否参与收藏）。发送页通用渲染，不硬编码协议分支。
 */

import { DeviceSourceDescriptor } from '../../model/transfer/Registries';

const sourceMap: Map<string, DeviceSourceDescriptor> = new Map();

/** 注册来源描述符（同键重复注册以最后一次为准）。 */
export function registerSource(descriptor: DeviceSourceDescriptor): void {
  sourceMap.set(descriptor.key, descriptor);
}

/** 取来源描述符（未注册返回 undefined）。 */
export function getSource(key: string): DeviceSourceDescriptor | undefined {
  return sourceMap.get(key);
}

/** 列举全部来源（按 order 升序）。 */
export function listSources(): Array<DeviceSourceDescriptor> {
  let result: Array<DeviceSourceDescriptor> = [];
  sourceMap.forEach((descriptor: DeviceSourceDescriptor) => {
    result.push(descriptor);
  });
  result.sort((a: DeviceSourceDescriptor, b: DeviceSourceDescriptor): number => a.order - b.order);
  return result;
}

/**
 * 过滤出「本次会话曾发现过设备」的来源（按 order 升序）。
 * 从未发现过的来源不展示标签；为空时调用方展示默认空态。
 */
export function filterSeenSources(sources: Array<DeviceSourceDescriptor>,
  seenKeys: Array<string>): Array<DeviceSourceDescriptor> {
  let result: Array<DeviceSourceDescriptor> = [];
  for (let i = 0; i < sources.length; i++) {
    if (seenKeys.indexOf(sources[i].key) >= 0) {
      result.push(sources[i]);
    }
  }
  return result;
}

/** 清空注册表（仅测试使用）。 */
export function clearSources(): void {
  sourceMap.clear();
}
