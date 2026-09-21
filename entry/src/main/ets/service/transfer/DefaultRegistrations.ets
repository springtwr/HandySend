/**
 * DefaultRegistrations.ets — 协议默认注册（设备来源 / 传输方式 / 设置分组）
 *
 * 这是「新增协议」的唯一接入清单之一：协议在此注册描述符与适配器即可被
 * 发送页、传输中心与设置页通用渲染，无需改动页面外壳。
 */

import { DeviceSourceDescriptor, SettingGroupDescriptor, TransferMethodDescriptor, TransferMethodGroup } from '../../model/transfer/Registries';
import { DiscoveredDevice } from '../../model/Types';
import { registerSource } from './DeviceSourceRegistry';
import { registerMethod } from './TransferMethodRegistry';
import { registerSettingsGroup } from './SettingsGroupRegistry';
import { getDiscoveredDevices } from '../repository/DiscoveryRepository';
import { getMtaDiscoveredDevices, isMtaBluetoothOn } from '../repository/MtaRepository';

// ── 方式动作分发（由发送页注入真实副作用：弹窗/导航/分享链接） ──

let methodDispatcher: ((key: string) => void) | undefined = undefined;

/** 注入方式动作分发（发送页 onAppear 时调用）。 */
export function setTransferMethodDispatcher(dispatcher: (key: string) => void): void {
  methodDispatcher = dispatcher;
}

function dispatch(key: string): void {
  if (methodDispatcher !== undefined) {
    methodDispatcher(key);
  }
}

// ── 设备来源 ──

/** 非 MTA 的局域网设备（LocalSend 来源）。 */
function localSendDevices(): Array<DiscoveredDevice> {
  let all = getDiscoveredDevices();
  let result: Array<DiscoveredDevice> = [];
  for (let i = 0; i < all.length; i++) {
    if (all[i].protocol !== 'mta') {
      result.push(all[i]);
    }
  }
  return result;
}

/** MTA（互传联盟）来源设备。 */
function mtaDevices(): Array<DiscoveredDevice> {
  return getMtaDiscoveredDevices();
}

/** 注册协议默认的设备来源描述符。 */
export function registerDefaultSources(): void {
  let localSend: DeviceSourceDescriptor = {
    key: 'localsend',
    label: $r('app.string.discovery_source_localsend'),
    icon: $r('app.media.ic_tab_send'),
    order: 10,
    favoritable: true,
    emptyState: {
      text: $r('app.string.no_devices_found'),
      hint: $r('app.string.discovery_empty_hint_localsend'),
      hintVisible: (): boolean => false
    },
    discoveryProvider: localSendDevices
  };
  registerSource(localSend);

  let mta: DeviceSourceDescriptor = {
    key: 'mta',
    label: $r('app.string.discovery_source_mta'),
    icon: $r('app.media.ic_tab_receive'),
    order: 20,
    favoritable: false,
    emptyState: {
      text: $r('app.string.mta_devices_empty'),
      // 蓝牙关闭时切换为开启蓝牙提示（沿用原发送页互传空态判定）
      dynamicText: (): ResourceStr => {
        return isMtaBluetoothOn() ? $r('app.string.mta_devices_empty') : $r('app.string.mta_bluetooth_off');
      },
      hint: $r('app.string.mta_bluetooth_off'),
      hintVisible: (): boolean => false
    },
    discoveryProvider: mtaDevices
  };
  registerSource(mta);

  // 网页分享（浏览器下载）不对应可发现设备：注册来源描述符仅为统一会话条目提供「来源协议标签」。
  // 空发现数据源使其不会成为发送页来源标签（标签按「曾发现过设备」出现）。
  let web: DeviceSourceDescriptor = {
    key: 'web',
    label: $r('app.string.discovery_source_web'),
    icon: $r('app.media.ic_tab_send'),
    order: 30,
    favoritable: false,
    emptyState: {
      text: $r('app.string.no_devices_found'),
      hint: $r('app.string.no_devices_found'),
      hintVisible: (): boolean => false
    },
    discoveryProvider: (): Array<DiscoveredDevice> => []
  };
  registerSource(web);
}

// ── 传输方式 ──

/** 注册协议默认的传输方式描述符（「网页」组与「其它方式」组）。 */
export function registerDefaultMethods(): void {
  let webSend: TransferMethodDescriptor = {
    key: 'web-send',
    label: $r('app.string.send_method_web_send'),
    icon: $r('app.media.ic_tab_send'),
    group: TransferMethodGroup.web,
    order: 10,
    available: (): boolean => true,
    action: (): void => {
      dispatch('web-send');
    }
  };
  registerMethod(webSend);

  let webReceive: TransferMethodDescriptor = {
    key: 'web-receive',
    label: $r('app.string.send_method_web_receive'),
    icon: $r('app.media.ic_tab_receive'),
    group: TransferMethodGroup.web,
    order: 20,
    // 网页接收依赖本机「互传接收」开关之外的浏览器上传通道，始终可用
    available: (): boolean => true,
    action: (): void => {
      dispatch('web-receive');
    }
  };
  registerMethod(webReceive);

  let byIp: TransferMethodDescriptor = {
    key: 'by-ip',
    label: $r('app.string.send_method_ip'),
    icon: $r('app.media.ic_tab_send'),
    group: TransferMethodGroup.other,
    order: 30,
    available: (): boolean => true,
    action: (): void => {
      dispatch('by-ip');
    }
  };
  registerMethod(byIp);
}

// ── 设置分组 ──

/**
 * 注册默认设置分组：按使用频率顺序排列——
 * 设备通用信息 → 通用（接收与发送）→ LocalSend → 互传联盟（MTA）→ 外观 → 更多。
 * 通用组与协议组共用同一 order 序列（见 SettingsGroupRegistry.listSettingsGroups）。
 */
export function registerDefaultSettingsGroups(): void {
  let device: SettingGroupDescriptor = {
    key: 'device-identity',
    title: $r('app.string.settings_group_device_info'),
    order: 10,
    protocol: false,
    sectionKey: 'device',
    // 首个分组不渲染分组标题：其卡片直接作为设置页内容区的首元素，与另两个主页顶部对齐
    showTitle: false
  };
  registerSettingsGroup(device);

  let general: SettingGroupDescriptor = {
    key: 'general',
    title: $r('app.string.settings_group_general'),
    order: 20,
    protocol: false,
    sectionKey: 'general'
  };
  registerSettingsGroup(general);

  let localSend: SettingGroupDescriptor = {
    key: 'localsend',
    title: $r('app.string.settings_source_localsend'),
    order: 30,
    protocol: true,
    sectionKey: 'localsend'
  };
  registerSettingsGroup(localSend);

  let mta: SettingGroupDescriptor = {
    key: 'mta',
    title: $r('app.string.mta_settings'),
    order: 40,
    protocol: true,
    sectionKey: 'mta'
  };
  registerSettingsGroup(mta);

  let appearance: SettingGroupDescriptor = {
    key: 'appearance',
    title: $r('app.string.appearance_settings'),
    order: 50,
    protocol: false,
    sectionKey: 'appearance'
  };
  registerSettingsGroup(appearance);

  let more: SettingGroupDescriptor = {
    key: 'more',
    title: $r('app.string.more_settings'),
    order: 60,
    protocol: false,
    sectionKey: 'more'
  };
  registerSettingsGroup(more);
}

/** 注册全部默认项（门面初始化时调用；幂等由注册表覆盖语义保证）。 */
export function registerProtocolDefaults(): void {
  registerDefaultSources();
  registerDefaultMethods();
  registerDefaultSettingsGroups();
  // 桩协议仅用于扩展性测试（测试期由用例显式调用 registerStubProtocol），
  // 生产流程不注册，避免桩来源标签与桩设置分组出现在发送页与设置页。
}
