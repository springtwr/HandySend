/**
 * SessionAdapter.ets — 协议适配器契约与适配器注册表
 *
 * 每个协议仅通过一个适配器接入：把协议原生事件翻译为注册表操作，
 * 实现确认/拒绝/取消/重试动作，声明能力与展示描述符。
 * 新增协议只需注册适配器与描述符，不改动会话引擎、聚合、后台驱动、
 * 取消分发与统一页面外壳。
 */

import { SessionCapabilities, SessionDisplayDescriptor } from '../../../model/transfer/TransferSession';
import { MediaFileInfo } from '../../../model/Types';

/**
 * 协议适配器契约。
 *
 * 成员一律声明为「函数类型属性」而非方法：ArkTS 不允许用对象字面量
 * 初始化「带有方法」的接口（arkts-no-untyped-obj-literals），
 * 属性语法下各适配器才能以字面量形式自注册。
 */
export interface SessionAdapter {
  // 协议唯一键（与注册表 protocolKey 一致）
  key: string
  // 建立协议事件订阅（应用启动时调用一次）
  initialize: () => void
  // 能力声明（驱动动作区与取消分发）
  getCapabilities: () => SessionCapabilities
  // 展示描述符（通用详情页/中心条目渲染）
  getDisplayDescriptor: (sessionId: string) => SessionDisplayDescriptor
  // 命令执行（按能力实现；越权调用应为 no-op）
  confirm: (sessionId: string) => void
  decline: (sessionId: string) => void
  cancel: (sessionId: string) => void
  retry: (sessionId: string) => void
  // 适配器侧会话资源清理（注册表回收会话时调用）
  dispose: (sessionId: string) => void
  // 可选：该会话可保存到相册的媒体文件（未实现时由页面回退到既有接收媒体信号）
  getGalleryMediaFiles?: (sessionId: string) => Array<MediaFileInfo>
}

// ── 适配器注册表 ──

const adapterMap: Map<string, SessionAdapter> = new Map();
const adapterOrder: Array<string> = [];

/** 注册适配器（幂等：同键重复注册以最后一次为准）。 */
export function registerAdapter(adapter: SessionAdapter): void {
  if (adapterMap.get(adapter.key) === undefined) {
    adapterOrder.push(adapter.key);
  }
  adapterMap.set(adapter.key, adapter);
}

/** 取适配器（未注册返回 undefined）。 */
export function getAdapter(key: string): SessionAdapter | undefined {
  return adapterMap.get(key);
}

/** 列举全部已注册适配器（按注册顺序）。 */
export function listAdapters(): Array<SessionAdapter> {
  let result: Array<SessionAdapter> = [];
  for (let i = 0; i < adapterOrder.length; i++) {
    let adapter = adapterMap.get(adapterOrder[i]);
    if (adapter !== undefined) {
      result.push(adapter);
    }
  }
  return result;
}

/** 初始化全部适配器（建立协议事件订阅，幂等由适配器自行保证）。 */
export function initializeAdapters(): void {
  let adapters = listAdapters();
  for (let i = 0; i < adapters.length; i++) {
    adapters[i].initialize();
  }
}

/** 展示文案是否非空（ResourceStr 为资源对象时视为非空）。 */
export function hasDisplayText(value: ResourceStr): boolean {
  return typeof value === 'string' ? value.length > 0 : true;
}

/** 空展示描述符（对端信息缺失时的兜底）。 */
export function emptyDisplayDescriptor(): SessionDisplayDescriptor {
  return {
    peerTitle: '',
    peerSubtitle: '',
    badges: [],
    deviceType: 'mobile',
    directionLabel: '',
    supportsTextPreview: false
  };
}
