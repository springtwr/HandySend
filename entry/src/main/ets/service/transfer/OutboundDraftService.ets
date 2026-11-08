/**
 * OutboundDraftService.ets — 发送方向会话草稿
 *
 * 发送方向（LocalSend 发送、MTA 发送、Web 下载）在会话创建时写草稿，
 * 文件完成时更新状态，终态删除。强杀恢复只补任务历史，标记“发送已中断”，
 * 不重建文件、不生成接收历史，也不触碰源文件。
 */

import {
  SESSION_DRAFT_SCHEMA_VERSION,
  SessionDraft,
  SessionDraftFile,
  completedAtForDraft,
  loadSessionDraft,
  removeSessionDraft,
  saveSessionDraft
} from './SessionDraftStore';
import {
  SessionCapabilities,
  SessionDataFlow,
  SessionFile,
  SessionFileDescriptor,
  SessionFileStage,
  SessionInitiator,
  SessionPeer,
  SessionStage,
  TransferSession
} from '../../model/transfer/TransferSession';

/**
 * 协议握手前的占位草稿：任务刚发起、统一会话尚未创建时使用。
 * 强杀后恢复为已取消，避免任务整条丢失；统一会话创建后由注册表草稿替换。
 */
export function savePreparedOutboundDraft(draftId: string, protocolKey: string,
  peer: SessionPeer, files: Array<SessionFileDescriptor>, capabilities: SessionCapabilities,
  textMessage: boolean): void {
  let draftFiles: Array<SessionDraftFile> = [];
  for (let i = 0; i < files.length; i++) {
    let f: SessionFileDescriptor = files[i];
    draftFiles.push({
      fileId: f.fileId,
      fileName: f.fileName,
      fileType: f.fileType,
      totalBytes: f.totalBytes,
      occurrence: f.occurrence !== undefined ? f.occurrence : 1,
      checksum: f.checksum !== undefined ? f.checksum : '',
      finalPath: f.path !== undefined ? f.path : '',
      tempPath: '',
      stage: SessionFileStage.waiting,
      bytesSent: 0,
      completedAt: 0,
      isTextMessage: textMessage
    });
  }
  let now: number = Date.now();
  let draft: SessionDraft = {
    schemaVersion: SESSION_DRAFT_SCHEMA_VERSION,
    sessionId: draftId,
    protocolKey: protocolKey,
    protocolSessionId: '',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    stage: SessionStage.awaitingConfirmation,
    textMessage: textMessage,
    peer: peer,
    localAlias: '',
    localIp: '',
    localInterfaceName: '',
    startedAt: now,
    transferStartedAt: 0,
    updatedAt: now,
    files: draftFiles,
    capabilities: capabilities
  };
  saveSessionDraft(draft);
}

/** 创建会话时写出站草稿；非发送方向为空操作。 */
export function saveOutboundDraft(session: TransferSession): void {
  if (session.dataFlow !== SessionDataFlow.outbound) {
    return;
  }
  let previous: SessionDraft | undefined = loadSessionDraft(session.id);
  let files: Array<SessionDraftFile> = [];
  for (let i = 0; i < session.files.length; i++) {
    let f: SessionFile = session.files[i];
    files.push({
      fileId: f.fileId,
      fileName: f.fileName,
      fileType: f.fileType,
      totalBytes: f.totalBytes,
      occurrence: f.occurrence,
      checksum: f.checksum,
      // 发送方向没有接收落盘路径；保存发送源路径，供历史详情预览/复制/打开使用。
      finalPath: f.path,
      tempPath: '',
      stage: f.stage,
      bytesSent: f.bytesSent,
      completedAt: completedAtForDraft(previous, f.fileId,
        f.stage === SessionFileStage.completed),
      isTextMessage: session.textMessage
    });
  }
  let draft: SessionDraft = {
    schemaVersion: SESSION_DRAFT_SCHEMA_VERSION,
    sessionId: session.id,
    protocolKey: session.protocolKey,
    protocolSessionId: session.protocolSessionId,
    dataFlow: session.dataFlow,
    initiatedBy: session.initiatedBy,
    stage: session.stage,
    textMessage: session.textMessage,
    peer: session.peer,
    localAlias: session.localAlias,
    localIp: session.localIp,
    localInterfaceName: session.localInterfaceName,
    startedAt: session.startedAt,
    transferStartedAt: session.transferStartedAt,
    updatedAt: Date.now(),
    files: files,
    capabilities: session.capabilities,
    errorMessage: session.errorMessage,
    errorCode: session.errorCode
  };
  saveSessionDraft(draft);
}

/** 单文件完成时更新草稿状态；非发送方向或草稿不存在时为空操作。 */
export function updateOutboundDraftFile(sessionId: string, fileId: string,
  stage: SessionFileStage, bytesSent: number): void {
  let draft: SessionDraft | undefined = loadSessionDraft(sessionId);
  if (draft === undefined || draft.dataFlow !== SessionDataFlow.outbound) {
    return;
  }
  for (let i = 0; i < draft.files.length; i++) {
    let file: SessionDraftFile = draft.files[i];
    if (file.fileId !== fileId) {
      continue;
    }
    file.stage = stage;
    file.bytesSent = bytesSent;
    if (stage === SessionFileStage.completed && file.completedAt === 0) {
      file.completedAt = Date.now();
    }
    draft.updatedAt = Date.now();
    saveSessionDraft(draft);
    return;
  }
}

/** 会话终结后删除出站草稿。 */
export function removeOutboundDraft(sessionId: string): void {
  removeSessionDraft(sessionId);
}
