/**
 * DemoDevices.ets — 固定虚拟设备定义（仅演示分支存在）
 *
 * 4 台演示设备以完整 DiscoveredDevice 形状常驻发送页设备列表：
 * LocalSend 手机 × 1、LocalSend 桌面 × 1、MTA 手机 × 2（Xiaomi / Honor 品牌）。
 * 设备昵称/型号为固定常量，不随应用语言切换（截图一致性）。
 * 演示设备以固定 fingerprint 集合精确识别（isDemoDevice，LocalSend 为证书指纹
 * 形状、MTA 为 BLE 地址形状，均取固定真实感值），
 * 供发送点击拦截（打开场景菜单）与真实设备分流。
 */

import { DiscoveredDevice } from '../../model/Types';

/** LocalSend 手机演示设备 */
const DEMO_LOCALSEND_PHONE: DiscoveredDevice = {
  alias: '张三',
  ip: '192.168.31.108',
  port: 53317,
  fingerprint: 'f5d6a3b89c2e4170afd63c1e9b7a5428dc0fe13b6a94e7d2c5f8310aeb7d94c2',
  version: '2.1',
  deviceModel: 'SM-S9280',
  deviceType: 'mobile',
  protocol: 'localsend',
  lastSeen: 0,
  channels: [{ host: '192.168.31.108', port: 53317, protocol: 'http' }]
};

/** LocalSend 桌面演示设备 */
const DEMO_LOCALSEND_DESKTOP: DiscoveredDevice = {
  alias: 'Kat',
  ip: '192.168.31.112',
  port: 53317,
  fingerprint: 'c81e4a72f0b35d69ce4a1f2b8d7c53a09e6b14d2f8a37c5e019b4d6f2a8c3e57',
  version: '2.1',
  deviceModel: 'Mac mini (M4)',
  deviceType: 'desktop',
  protocol: 'localsend',
  lastSeen: 0,
  channels: [{ host: '192.168.31.112', port: 53317, protocol: 'http' }]
};

/** MTA 手机一演示设备（品牌取注册表内 Xiaomi，形状对齐 mtaDeviceToDiscoveredDevice：无 IP/型号） */
const DEMO_MTA_PHONE_1: DiscoveredDevice = {
  alias: 'Leo',
  ip: '',
  port: 0,
  fingerprint: '8C:4B:14:6F:A2:31',
  version: '',
  deviceModel: '',
  deviceType: 'mobile',
  protocol: 'mta',
  lastSeen: 0,
  channels: [],
  mtaBleAddress: '8C:4B:14:6F:A2:31',
  mtaSenderIdHex: 'f1',
  mtaBrandId: 30,
  mtaBrandName: 'Xiaomi',
  mtaIs5Ghz: true,
  mtaRssi: -48
};

/** MTA 手机二演示设备（品牌取注册表内 Honor，形状对齐 mtaDeviceToDiscoveredDevice：无 IP/型号） */
const DEMO_MTA_PHONE_2: DiscoveredDevice = {
  alias: '张三',
  ip: '',
  port: 0,
  fingerprint: '6C:D8:03:7A:B2:44',
  version: '',
  deviceModel: '',
  deviceType: 'mobile',
  protocol: 'mta',
  lastSeen: 0,
  channels: [],
  mtaBleAddress: '6C:D8:03:7A:B2:44',
  mtaSenderIdHex: 'f1',
  mtaBrandId: 140,
  mtaBrandName: 'Honor',
  mtaIs5Ghz: true,
  mtaRssi: -48
};

/** 全部演示设备（固定顺序：LocalSend 手机 → LocalSend 桌面 → MTA 手机一 → MTA 手机二） */
const DEMO_DEVICES: Array<DiscoveredDevice> = [
  DEMO_LOCALSEND_PHONE,
  DEMO_LOCALSEND_DESKTOP,
  DEMO_MTA_PHONE_1,
  DEMO_MTA_PHONE_2
];

/** 是否演示设备（按固定 fingerprint 精确匹配设备表） */
export function isDemoDevice(fingerprint: string): boolean {
  for (let i = 0; i < DEMO_DEVICES.length; i++) {
    if (DEMO_DEVICES[i].fingerprint === fingerprint) {
      return true;
    }
  }
  return false;
}

/**
 * 按来源协议取演示设备（供发送页设备来源映射处合并，演示设备排序置后）。
 * protocol 传 'localsend' 或 'mta'；其余值返回空数组。
 * 返回浅拷贝数组，避免调用方修改演示设备常量。
 */
export function getDemoDevices(protocol: string): Array<DiscoveredDevice> {
  let result: Array<DiscoveredDevice> = [];
  for (let i = 0; i < DEMO_DEVICES.length; i++) {
    if (DEMO_DEVICES[i].protocol === protocol) {
      result.push(DEMO_DEVICES[i]);
    }
  }
  return result;
}
