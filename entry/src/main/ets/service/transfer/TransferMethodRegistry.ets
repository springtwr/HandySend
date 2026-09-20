/**
 * TransferMethodRegistry.ets — 传输方式注册表
 *
 * 「不经设备发现的其它发起/接收方式」注册为描述符（名称、图标、可用条件、
 * 动作、分组）。发送页方式菜单按分组展示（「网页」组与「其它方式」组）。
 */

import { TransferMethodDescriptor, TransferMethodGroup } from '../../model/transfer/Registries';

const methodMap: Map<string, TransferMethodDescriptor> = new Map();

/** 注册方式描述符（同键重复注册以最后一次为准）。 */
export function registerMethod(descriptor: TransferMethodDescriptor): void {
  methodMap.set(descriptor.key, descriptor);
}

/** 取方式描述符（未注册返回 undefined）。 */
export function getMethod(key: string): TransferMethodDescriptor | undefined {
  return methodMap.get(key);
}

/** 列举全部方式（按 order 升序）。 */
export function listMethods(): Array<TransferMethodDescriptor> {
  let result: Array<TransferMethodDescriptor> = [];
  methodMap.forEach((descriptor: TransferMethodDescriptor) => {
    result.push(descriptor);
  });
  result.sort((a: TransferMethodDescriptor, b: TransferMethodDescriptor): number => a.order - b.order);
  return result;
}

/** 按分组列举方式（组内按 order 升序）。 */
export function listMethodsByGroup(group: TransferMethodGroup): Array<TransferMethodDescriptor> {
  let all = listMethods();
  let result: Array<TransferMethodDescriptor> = [];
  for (let i = 0; i < all.length; i++) {
    if (all[i].group === group) {
      result.push(all[i]);
    }
  }
  return result;
}

/** 清空注册表（仅测试使用）。 */
export function clearMethods(): void {
  methodMap.clear();
}
