/**
 * StubAdapter.ets — 最小桩协议适配器
 *
 * 扩展性验证用：仅注册一个适配器 + 一份来源/设置描述符（不发真实流量），
 * 即可让该协议的会话出现在传输中心与通用详情页、可取消、可参与后台聚合，
 * 且不修改会话引擎、聚合、后台驱动、取消分发与页面外壳。
 */

import {
  SessionCapabilities,
  SessionDataFlow,
  SessionDisplayDescriptor,
  SessionInitiator,
  SessionStage
} from '../../../model/transfer/TransferSession';
import { DeviceSourceDescriptor } from '../../../model/transfer/Registries';
import { DiscoveredDevice } from '../../../model/Types';
import { getLogger } from '../../../utils/Logger';
import { LogDomains } from '../../../common/LogDomains';
import { createSession, finish, getSession, setStageProgress } from '../TransferSessionRegistry';
import { registerSource } from '../DeviceSourceRegistry';
import { registerSettingsGroup } from '../SettingsGroupRegistry';
import { SessionAdapter, emptyDisplayDescriptor, registerAdapter } from './SessionAdapter';

export const STUB_KEY: string = 'stub';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionAdapter', '协议适配');

// 桩协议不发真实流量：会话仅用于验证扩展点（进度由外部驱动或保持阶段文案）
let stubSeq: number = 0;

function capabilities(): SessionCapabilities {
  return {
    canCancel: true,
    canRetry: false,
    needsConfirm: false,
    hasByteProgress: false,
    canSaveToGallery: false,
    hasVerify: false
  };
}

/** 创建一个桩协议会话（默认进行中）。 */
export function beginStubSession(peerName: string, stageText: ResourceStr): string {
  stubSeq++;
  let session = createSession({
    protocolKey: STUB_KEY,
    protocolSessionId: 'stub-' + stubSeq,
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: { displayName: peerName, deviceType: 'mobile', badges: ['Stub'] },
    files: [{ fileId: 'stub-file-' + stubSeq, fileName: 'stub.bin', fileType: '', totalBytes: 0 }],
    capabilities: capabilities(),
    stage: SessionStage.active,
    stageText: stageText
  });
  return session.id;
}

/** 推进桩会话的离散阶段文案（经注册表，与其它适配器一致）。 */
export function advanceStubSession(sessionId: string, stageText: ResourceStr): void {
  setStageProgress(sessionId, stageText);
}

/** 终结桩会话。 */
export function finishStubSession(sessionId: string, success: boolean): void {
  finish(sessionId, success ? SessionStage.succeeded : SessionStage.failed);
}

const adapter: SessionAdapter = {
  key: STUB_KEY,
  initialize: (): void => {
    // 桩协议无可订阅的原生事件
  },
  getCapabilities: capabilities,
  getDisplayDescriptor: (sessionId: string): SessionDisplayDescriptor => {
    let session = getSession(sessionId);
    if (session === undefined) {
      return emptyDisplayDescriptor();
    }
    return {
      peerTitle: session.peer.displayName.length > 0 ? session.peer.displayName : 'Stub device',
      peerSubtitle: 'Stub protocol',
      badges: session.peer.badges,
      deviceType: session.peer.deviceType ?? 'mobile',
      directionLabel: 'Stub',
      supportsTextPreview: false
    };
  },
  confirm: (): void => {
  },
  decline: (): void => {
  },
  cancel: (sessionId: string): void => {
    logger.debug('stub cancel: ' + sessionId);
  },
  retry: (): void => {
  },
  dispose: (_sessionId: string): void => {
  }
};

/**
 * 注册最小桩协议：适配器 + 来源描述符 + 设置分组。
 * 这一步即「新增协议」的全部改动面（不含真实协议 I/O）。
 * 仅测试期显式调用（扩展性用例），生产流程不注册，避免桩来源与桩设置分组进入正式界面。
 */
export function registerStubProtocol(): void {
  registerAdapter(adapter);
  let stubSource: DeviceSourceDescriptor = {
    key: STUB_KEY,
    label: $r('app.string.stub_source_label'),
    icon: $r('app.media.ic_tab_send'),
    order: 90,
    favoritable: false,
    emptyState: {
      text: $r('app.string.stub_source_empty'),
      hint: $r('app.string.stub_source_empty_hint'),
      hintVisible: (): boolean => false
    },
    discoveryProvider: (): Array<DiscoveredDevice> => []
  };
  registerSource(stubSource);
  registerSettingsGroup({
    key: STUB_KEY,
    title: $r('app.string.stub_source_label'),
    order: 90,
    protocol: true,
    sectionKey: STUB_KEY
  });
}
