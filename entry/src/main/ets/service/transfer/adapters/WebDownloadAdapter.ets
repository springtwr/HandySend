/**
 * WebDownloadAdapter.ets — Web 分享下载适配器
 *
 * 一个下载批次 = 一个统一会话：单文件是 1 文件批次，多文件是一个 zip 批次。
 * 服务端在真正开始下发时发 `webDownloadStarted`，应用才建任务；
 * 页面访问、文件列表刷新不产生任务。
 */

import {
  SessionCapabilities,
  SessionDataFlow,
  SessionDisplayDescriptor,
  SessionFileDescriptor,
  SessionFileStage,
  SessionInitiator,
  SessionStage,
  TransferSession,
  isTerminalStage
} from '../../../model/transfer/TransferSession';
import { getLogger } from '../../../utils/Logger';
import { LogDomains } from '../../../common/LogDomains';
import { getMimeForFileName } from '../../../utils/MimeUtils';
import {
  createSession,
  finish,
  getSession,
  markFileStage,
  updateFileProgress
} from '../TransferSessionRegistry';
import { SessionAdapter, emptyDisplayDescriptor, registerAdapter } from './SessionAdapter';
import { nativeCancelWebDownload } from '../../NativeBridge';

export const WEB_DOWNLOAD_KEY: string = 'web-download';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionAdapter', '协议适配');

// 批次标识 → 统一会话标识
const batches: Map<string, string> = new Map();

// 会话文本预览缓存（统一会话标识 → 文本内容）
const textPreviewCache: Map<string, string> = new Map();

function capabilities(): SessionCapabilities {
  return {
    canCancel: true,
    canRetry: false,
    needsConfirm: false,
    hasByteProgress: true,
    canSaveToGallery: false,
    hasVerify: false,
    cancelLabel: $r('app.string.session_end_web_download')
  };
}

function resolveTextPreview(session: TransferSession): string {
  let cached: string | undefined = textPreviewCache.get(session.id);
  return cached !== undefined ? cached : '';
}

/**
 * 批次开始：建（或幂等复用）统一任务。
 * 文件清单由 repository 补齐本地路径；`textPreview` 仅手动输入的文本消息携带，
 * 普通 .txt 文件为空串（不按文本消息展示）。
 * 本函数不持有定时器。
 */
export function beginWebDownloadBatch(batchId: string, ip: string,
  files: Array<SessionFileDescriptor>, textPreview: string = ''): string {
  let existingId: string | undefined = batches.get(batchId);
  if (existingId !== undefined) {
    let existing = getSession(existingId);
    if (existing !== undefined && !isTerminalStage(existing.stage)) {
      return existingId;
    }
    batches.delete(batchId);
  }
  let session = createSession({
    protocolKey: WEB_DOWNLOAD_KEY,
    protocolSessionId: batchId,
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.remote,
    peer: {
      displayName: ip,
      ip: ip,
      deviceType: 'web',
      badges: []
    },
    files: files,
    capabilities: capabilities(),
    stage: SessionStage.active,
    textMessage: textPreview.length > 0
  });
  if (textPreview.length > 0) {
    textPreviewCache.set(session.id, textPreview);
  }
  batches.set(batchId, session.id);
  return session.id;
}

/** 单文件字节进度（zip 内逐条目）。 */
export function handleWebDownloadProgress(batchId: string, fileId: string,
  sentBytes: number, totalBytes: number): void {
  let sessionId = batches.get(batchId);
  if (sessionId === undefined) {
    return;
  }
  updateFileProgress(sessionId, fileId, sentBytes, totalBytes);
}

/** 单文件完成。 */
export function handleWebDownloadFileDone(batchId: string, fileId: string,
  totalBytes: number): void {
  let sessionId = batches.get(batchId);
  if (sessionId === undefined) {
    return;
  }
  markFileStage(sessionId, fileId, SessionFileStage.completed);
  if (totalBytes <= 0) {
    // 0 字节文件没有进度事件：阶段由 markFileStage 补齐即可
    return;
  }
}

/** 批次终态：成功/失败/取消（有已完成文件的部分失败按 partiallyFailed 收口）。 */
export function handleWebDownloadEnded(batchId: string, outcome: string,
  error?: string): void {
  let sessionId = batches.get(batchId);
  if (sessionId === undefined) {
    return;
  }
  batches.delete(batchId);
  let session = getSession(sessionId);
  if (session === undefined || isTerminalStage(session.stage)) {
    return;
  }
  if (outcome === 'succeeded') {
    finish(sessionId, SessionStage.succeeded);
    return;
  }
  if (outcome === 'cancelled') {
    finish(sessionId, SessionStage.cancelled);
    return;
  }
  let completed: boolean = session.files.some((file) =>
    file.stage === SessionFileStage.completed ||
    (file.totalBytes > 0 && file.bytesSent >= file.totalBytes));
  finish(sessionId, completed ? SessionStage.partiallyFailed : SessionStage.failed,
    error !== undefined && error.length > 0 ? error : '网页下载失败');
  logger.warn('Web 下载批次结束 batch=' + batchId + ' outcome=' + outcome +
    ' error=' + (error ?? ''));
}

const adapter: SessionAdapter = {
  key: WEB_DOWNLOAD_KEY,
  initialize: (): void => {
  },
  getCapabilities: capabilities,
  getDisplayDescriptor: (sessionId: string): SessionDisplayDescriptor => {
    let session = getSession(sessionId);
    if (session === undefined) {
      return emptyDisplayDescriptor();
    }
    let preview: string = resolveTextPreview(session);
    return {
      peerTitle: session.peer.displayName,
      peerSubtitle: '',
      badges: [],
      deviceType: session.peer.deviceType ?? 'mobile',
      directionLabel: $r('app.string.session_direction_send'),
      supportsTextPreview: preview.length > 0,
      textPreview: preview
    };
  },
  confirm: (_sessionId: string): void => {
  },
  decline: (_sessionId: string): void => {
  },
  cancel: (sessionId: string): void => {
    let session = getSession(sessionId);
    if (session === undefined) {
      return;
    }
    let batchId: string = session.protocolSessionId;
    if (batchId.length > 0) {
      try {
        nativeCancelWebDownload(batchId);
      } catch (e) {
        logger.warn('取消 Web 下载批次失败 batch=' + batchId + '：' + String(e));
      }
    }
    batches.delete(batchId);
    textPreviewCache.delete(sessionId);
  },
  retry: (_sessionId: string): void => {
  },
  dispose: (sessionId: string): void => {
    textPreviewCache.delete(sessionId);
    let session = getSession(sessionId);
    if (session === undefined) {
      return;
    }
    let batchId: string = session.protocolSessionId;
    if (batchId.length > 0) {
      let mapped = batches.get(batchId);
      if (mapped === sessionId) {
        batches.delete(batchId);
      }
    }
  }
};

registerAdapter(adapter);
