/**
 * SessionRecoveryService.ets — 强杀后的会话恢复
 *
 * 启动时读取会话草稿，按文件系统实际状态补写任务历史与接收历史：
 * - 最终路径存在且大小匹配：视为已完成，补写接收历史；
 * - 最终路径不存在或大小不符：视为未完成，清理临时区但不删除最终路径；
 * - 草稿会话以部分完成/成功写入任务历史，保证任务列表不丢失。
 *
 * 恢复只读，不启动网络传输、不重建文件、不提供手动重发。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import {
  SessionDataFlow,
  SessionFile,
  SessionFileStage,
  SessionStage,
  TransferSession,
  isTerminalStage
} from '../../model/transfer/TransferSession';
import { ReceiveHistoryEntry } from '../../model/Types';
import { baseNameOf, dirNameOf, LEGACY_TEMP_DIR_NAMES, tempPathForFinal } from '../../model/transfer/TransferTempPaths';
import {
  SessionDraft,
  SessionDraftFile,
  cleanupSessionDraftTmp,
  loadAllSessionDrafts,
  removeSessionDraft
} from './SessionDraftStore';
import { archiveSession } from './SessionHistoryStore';
import { addEntriesIfAbsent } from '../repository/ReceiveHistoryService';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionRecovery', '会话恢复');

export interface SessionRecoveryResult {
  drafts: number
  recovered: number
  failed: number
  files: number
}

/** 启动恢复入口：同步读取与校验，由调用方放到异步任务中执行。 */
export function recoverSessionDrafts(): SessionRecoveryResult {
  cleanupSessionDraftTmp();
  let drafts: Array<SessionDraft> = loadAllSessionDrafts();
  let result: SessionRecoveryResult = {
    drafts: drafts.length,
    recovered: 0,
    failed: 0,
    files: 0
  };
  for (let i = 0; i < drafts.length; i++) {
    let draft: SessionDraft = drafts[i];
    try {
      let completedFiles: number = recoverOne(draft);
      result.recovered++;
      result.files += completedFiles;
    } catch (e) {
      result.failed++;
      logger.warn('恢复会话失败 session=' + draft.sessionId + '：' + String(e));
    }
  }
  if (result.drafts > 0) {
    logger.info('启动恢复完成 草稿=' + result.drafts + ' 成功=' + result.recovered +
      ' 失败=' + result.failed + ' 已完成文件=' + result.files);
  }
  return result;
}

/** 恢复单个草稿，返回已完成文件数；历史写入成功后才删除草稿。 */
function recoverOne(draft: SessionDraft): number {
  let session: TransferSession = new TransferSession();
  session.id = draft.sessionId;
  session.protocolKey = draft.protocolKey;
  session.protocolSessionId = draft.protocolSessionId;
  session.dataFlow = draft.dataFlow;
  session.initiatedBy = draft.initiatedBy;
  session.textMessage = draft.textMessage;
  session.peer = draft.peer;
  session.localAlias = draft.localAlias;
  session.localIp = draft.localIp;
  session.localInterfaceName = draft.localInterfaceName;
  session.startedAt = draft.startedAt;
  session.transferStartedAt = draft.transferStartedAt;
  session.errorCode = 'app_killed';
  session.errorMessage = '应用异常退出，传输已中断';
  if (draft.capabilities !== undefined) {
    session.capabilities = draft.capabilities;
  }

  let isOutbound: boolean = draft.dataFlow === SessionDataFlow.outbound;
  if (isOutbound && isTerminalStage(draft.stage)) {
    // 终态草稿：历史可能已写入，也可能停在写入前；按终态原样归档（upsert），
    // 避免把已成功任务降级为失败，也避免强杀窗口丢历史。
    let terminalCompleted: number = 0;
    let terminalBytes: number = 0;
    let terminalTotal: number = 0;
    for (let i = 0; i < draft.files.length; i++) {
      let file: SessionDraftFile = draft.files[i];
      let completed: boolean = file.stage === SessionFileStage.completed;
      if (completed) {
        terminalCompleted++;
        terminalBytes += file.totalBytes;
      }
      terminalTotal += file.totalBytes;
      session.files.push(buildSessionFile(file, completed,
        file.stage === SessionFileStage.cancelled ? SessionFileStage.cancelled :
          SessionFileStage.failed));
    }
    session.stage = draft.stage;
    session.errorCode = draft.errorCode !== undefined ? draft.errorCode : '';
    session.errorMessage = draft.errorMessage !== undefined ? draft.errorMessage : '';
    session.totalBytes = terminalTotal;
    session.bytesSent = terminalBytes;
    session.finishedAt = draft.updatedAt > 0 ? draft.updatedAt : draft.startedAt;
    if (session.finishedAt <= 0) {
      session.finishedAt = Date.now();
    }
    archiveSession(session);
    removeSessionDraft(draft.sessionId);
    return terminalCompleted;
  }

  let receiveEntries: Array<ReceiveHistoryEntry> = [];
  let completedFlags: Array<boolean> = [];
  let actualSizes: Array<number> = [];
  let completedCount: number = 0;
  let completedBytes: number = 0;
  let totalBytes: number = 0;
  for (let i = 0; i < draft.files.length; i++) {
    let file: SessionDraftFile = draft.files[i];
    // 发送方向没有接收落盘路径，只能按草稿记录的文件阶段归档；
    // 接收方向按最终文件大小校验，不能信任可能缺失的完成事件。
    let actualSize: number = isOutbound ? -1 : statSize(file.finalPath);
    let completed: boolean = isOutbound ? file.stage === SessionFileStage.completed :
      (actualSize >= 0 && actualSize === file.totalBytes);
    if (!isOutbound) {
      // 临时区只清理未完成或遗留的临时文件，最终路径永远不自动删除。
      cleanupTempFile(file);
    }
    completedFlags.push(completed);
    actualSizes.push(actualSize);
    if (completed) {
      completedCount++;
      completedBytes += isOutbound ? file.totalBytes : actualSize;
    }
    totalBytes += file.totalBytes;
  }

  // 按会话阶段区分恢复结果：
  // - 待确认阶段强杀：任务从未开始，归档为已取消，不能显示「部分成功」；
  // - 已开始但零个文件完成：归档为失败；
  // - 部分完成：部分成功；全部完成：成功。
  // 发送方向无法确认对端是否收到，非待确认且已有完成文件时按部分成功归档。
  let allCompleted: boolean = completedCount === draft.files.length && draft.files.length > 0;
  let incompleteStage: SessionFileStage = SessionFileStage.failed;
  if (isOutbound) {
    if (draft.stage === SessionStage.awaitingConfirmation) {
      session.stage = SessionStage.cancelled;
      session.errorCode = 'app_killed_before_start';
      session.errorMessage = '应用异常退出，传输未开始';
      incompleteStage = SessionFileStage.cancelled;
    } else if (completedCount === 0) {
      session.stage = SessionStage.failed;
      session.errorCode = 'app_killed';
      session.errorMessage = '应用异常退出，发送已中断';
    } else {
      session.stage = SessionStage.partiallyFailed;
      session.errorCode = 'app_killed';
      session.errorMessage = '应用异常退出，发送状态未确认';
    }
  } else if (allCompleted) {
    session.stage = SessionStage.succeeded;
    session.errorCode = '';
    session.errorMessage = '';
  } else if (draft.stage === SessionStage.awaitingConfirmation) {
    session.stage = SessionStage.cancelled;
    session.errorCode = 'app_killed_before_start';
    session.errorMessage = '应用异常退出，传输未开始';
    incompleteStage = SessionFileStage.cancelled;
  } else if (completedCount === 0) {
    session.stage = SessionStage.failed;
    session.errorCode = 'app_killed';
    session.errorMessage = '应用异常退出，传输已中断';
  } else {
    session.stage = SessionStage.partiallyFailed;
    session.errorCode = 'app_killed';
    session.errorMessage = '应用异常退出，部分文件已完成';
  }
  for (let i = 0; i < draft.files.length; i++) {
    let file: SessionDraftFile = draft.files[i];
    session.files.push(buildSessionFile(file, completedFlags[i], incompleteStage));
    if (!isOutbound && completedFlags[i]) {
      receiveEntries.push(buildReceiveEntry(draft, file, actualSizes[i]));
    }
  }
  session.totalBytes = totalBytes;
  session.bytesSent = completedBytes;
  session.finishedAt = draft.updatedAt > 0 ? draft.updatedAt : draft.startedAt;
  if (session.finishedAt <= 0) {
    session.finishedAt = Date.now();
  }

  archiveSession(session);
  if (receiveEntries.length > 0) {
    addEntriesIfAbsent(receiveEntries);
  }
  removeSessionDraft(draft.sessionId);
  return completedCount;
}

function buildSessionFile(file: SessionDraftFile, completed: boolean,
  incompleteStage: SessionFileStage): SessionFile {
  let sessionFile: SessionFile = new SessionFile();
  sessionFile.fileId = file.fileId;
  sessionFile.fileName = file.fileName;
  sessionFile.fileType = file.fileType;
  sessionFile.totalBytes = file.totalBytes;
  sessionFile.occurrence = file.occurrence;
  sessionFile.checksum = file.checksum;
  sessionFile.path = file.finalPath;
  sessionFile.bytesSent = completed ? file.totalBytes : file.bytesSent;
  sessionFile.stage = completed ? SessionFileStage.completed : incompleteStage;
  return sessionFile;
}

function buildReceiveEntry(draft: SessionDraft, file: SessionDraftFile,
  actualSize: number): ReceiveHistoryEntry {
  let fileName: string = baseNameOf(file.finalPath);
  if (fileName.length === 0) {
    fileName = file.fileName;
  }
  let entry: ReceiveHistoryEntry = {
    id: draft.sessionId + '_' + file.fileId,
    fileName: fileName,
    fileType: file.fileType,
    path: file.finalPath,
    savedToGallery: false,
    isMessage: file.isTextMessage,
    fileSize: actualSize,
    senderAlias: draft.peer.displayName,
    timestamp: file.completedAt > 0 ? file.completedAt : draft.updatedAt
  };
  return entry;
}

/** 返回文件大小；不存在或不可读返回 -1。 */
function statSize(path: string): number {
  if (path.length === 0) {
    return -1;
  }
  try {
    if (!fs.accessSync(path)) {
      return -1;
    }
    return fs.statSync(path).size;
  } catch (e) {
    return -1;
  }
}

/** 删除未完成临时文件，并尝试移除已空的临时目录；不触碰最终路径。 */
function cleanupTempFile(file: SessionDraftFile): void {
  // 无最终路径也无临时路径（如 MTA 下载中强杀的占位草稿）时不要推导目录，
  // 避免把相对路径 `.handysend-temp` 当成真实临时区。
  if (file.finalPath.length === 0 && file.tempPath.length === 0) {
    return;
  }
  let tempPath: string = file.tempPath.length > 0 ? file.tempPath :
    tempPathForFinal(file.finalPath);
  if (tempPath.length === 0) {
    return;
  }
  try {
    if (fs.accessSync(tempPath)) {
      fs.unlinkSync(tempPath);
    }
  } catch (e) {
    logger.debug('清理临时文件失败：' + tempPath + '：' + String(e));
  }
  let tempDir: string = dirNameOf(tempPath);
  if (tempDir.length === 0) {
    return;
  }
  try {
    if (fs.accessSync(tempDir)) {
      fs.rmdirSync(tempDir);
    }
  } catch (_e) {
    // 目录非空说明还有其他残留或用户文件，保留。
  }
  cleanupLegacyTempDirs(file.finalPath);
}

/** 清理最终目录下的旧版本临时区；启动时无活跃传输，可安全删除其中所有文件。 */
function cleanupLegacyTempDirs(finalPath: string): void {
  let parent: string = dirNameOf(finalPath);
  if (parent.length === 0) {
    return;
  }
  for (let i = 0; i < LEGACY_TEMP_DIR_NAMES.length; i++) {
    let dir: string = parent + '/' + LEGACY_TEMP_DIR_NAMES[i];
    try {
      if (!fs.accessSync(dir)) {
        continue;
      }
      let names: Array<string> = fs.listFileSync(dir);
      for (let k = 0; k < names.length; k++) {
        try {
          fs.unlinkSync(dir + '/' + names[k]);
        } catch (_e) {
        }
      }
      fs.rmdirSync(dir);
    } catch (_e) {
    }
  }
}
