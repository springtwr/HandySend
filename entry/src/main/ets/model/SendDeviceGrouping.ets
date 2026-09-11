/**
 * SendDeviceGrouping.ets — 发送页附近设备按类型分组的纯函数
 *
 * 按设备来源协议把统一设备集合拆分为「局域网（LocalSend）」与「互传联盟（MTA）」两组，
 * 供发送页设备类型标签分别渲染与计数。仅依赖 model/Types 与 model/mta/MtaMainModels，
 * 无 ArkUI / 系统 API 依赖，可脱离运行时单测。
 */

import { DiscoveredDevice } from './Types';
import { isMtaDevice } from './mta/MtaMainModels';

/** 设备类型分组结果：local 为局域网设备，mta 为互传联盟设备 */
export interface DeviceTypePartition {
  local: Array<DiscoveredDevice>
  mta: Array<DiscoveredDevice>
}

/**
 * 按设备类型拆分设备集合（纯函数，不修改入参，组内保持输入相对顺序）。
 */
export function partitionDevicesByType(devices: Array<DiscoveredDevice>): DeviceTypePartition {
  let local: Array<DiscoveredDevice> = [];
  let mta: Array<DiscoveredDevice> = [];
  for (let i = 0; i < devices.length; i++) {
    if (isMtaDevice(devices[i])) {
      mta.push(devices[i]);
    } else {
      local.push(devices[i]);
    }
  }
  return { local: local, mta: mta };
}

/**
 * 集合中是否至少包含一个互传联盟设备。
 */
export function hasAnyMtaDevice(devices: Array<DiscoveredDevice>): boolean {
  for (let i = 0; i < devices.length; i++) {
    if (isMtaDevice(devices[i])) {
      return true;
    }
  }
  return false;
}
