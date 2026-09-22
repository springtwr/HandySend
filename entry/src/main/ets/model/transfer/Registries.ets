/**
 * Registries.ets — 三类注册表描述符类型（来源 / 方式 / 设置分组）
 *
 * 发送页与设置页对协议零硬编码：由协议注册描述符，页面通用渲染。
 */

import { DiscoveredDevice } from '../Types';

// ── 设备来源注册表 ──

/** 来源空态描述（含条件化引导，如蓝牙/WLAN 未开时引导开启）。 */
export interface SourceEmptyStateDescriptor {
  text: ResourceStr
  // 动态空态文案（可选）：设置后优先于 text（如互传蓝牙关闭时切换为开启蓝牙提示）
  dynamicText?: () => ResourceStr
  hint: ResourceStr
  // 引导是否展示（条件化：如蓝牙未开启时才提示）
  hintVisible: () => boolean
}

/** 设备来源描述符（每个协议注册一份）。 */
export interface DeviceSourceDescriptor {
  key: string
  label: ResourceStr
  // 该来源设备列表的副标题引导文案（随选中的来源标签切换）
  subtitle: ResourceStr
  icon: Resource
  // 排序值越小越靠前
  order: number
  // 是否参与收藏体系（MTA 等非 LocalSend 来源不参与）
  favoritable: boolean
  emptyState: SourceEmptyStateDescriptor
  // 该来源的发现数据源（发送页目标区通用渲染）
  discoveryProvider: () => Array<DiscoveredDevice>
}

// ── 传输方式注册表 ──

/** 方式分组：「网页」类（网页发送/接收）与「其它方式」（指定 IP 等）。 */
export enum TransferMethodGroup {
  web = 'web',
  other = 'other'
}

/** 传输方式描述符（不经设备发现的其它发起/接收方式）。 */
export interface TransferMethodDescriptor {
  key: string
  label: ResourceStr
  icon: Resource
  group: TransferMethodGroup
  order: number
  // 可用条件（如分享进行中时不可用）
  available: () => boolean
  action: () => void
}

// ── 设置分组注册表 ──

/** 设置分组描述符（通用组固定 + 协议组动态）。 */
export interface SettingGroupDescriptor {
  key: string
  title: ResourceStr
  // 排序值越小越靠前
  order: number
  // true = 协议注册的分组；false = 通用分组
  protocol: boolean
  // 页面装配用的分组渲染键（页面据此装配已知分区组件）
  sectionKey: string
  // 是否渲染该分组的分组标题：缺省（未设置）视为渲染；
  // 置假用于"首张卡片直接作为内容区首元素"的分组（不渲染标题）
  showTitle?: boolean
}
