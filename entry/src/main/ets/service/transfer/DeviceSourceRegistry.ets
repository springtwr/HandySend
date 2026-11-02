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
 * 过滤出发送页可展示的设备来源（按 order 升序）：
 * 仅设备来源且协议开关开启。集合不随发现结果变化；
 * 全部来源均无设备时由调用方回退总空态。
 */
export function filterEnabledDeviceSources(
  sources: Array<DeviceSourceDescriptor>): Array<DeviceSourceDescriptor> {
  let result: Array<DeviceSourceDescriptor> = [];
  for (let i = 0; i < sources.length; i++) {
    let descriptor: DeviceSourceDescriptor = sources[i];
    if (descriptor.deviceSource && descriptor.enabled()) {
      result.push(descriptor);
    }
  }
  return result;
}

/** 清空注册表（仅测试使用）。 */
export function clearSources(): void {
  sourceMap.clear();
}
