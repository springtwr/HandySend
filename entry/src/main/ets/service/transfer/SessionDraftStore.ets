/**
 * SessionDraftStore.ets — 会话草稿持久化
 *
 * 强杀后恢复任务与接收历史所需的会话草稿，每个会话一个 JSON 文件，
 * 位于应用私有持久目录 `<filesDir>/session_drafts/`。
 *
 * 只记录状态变化（创建、文件完成、终结），不记录字节进度；写入使用
 * 临时文件 + rename 原子替换，避免强杀留下半个 JSON。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { getAppContext } from '../repository/AppCore';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import {
  SessionCapabilities,
  SessionDataFlow,
  SessionFileStage,
  SessionInitiator,
  SessionPeer,
  SessionStage
} from '../../model/transfer/TransferSession';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionDraft', '会话草稿');

export const SESSION_DRAFT_SCHEMA_VERSION: number = 1;
export const SESSION_DRAFT_DIR_NAME: string = 'session_drafts';
const DRAFT_SUFFIX: string = '.json';
const DRAFT_TMP_SUFFIX: string = '.json.tmp';
const DRAFT_STALE_MS: number = 7 * 24 * 60 * 60 * 1000;

/** 草稿中的单个文件。 */
export interface SessionDraftFile {
  fileId: string
  fileName: string
  fileType: string
  totalBytes: number
  occurrence: number
  checksum: string
  finalPath: string
  tempPath: string
  stage: SessionFileStage
  bytesSent: number
  completedAt: number
  isTextMessage: boolean
}

/** 一个会话的草稿快照。 */
export interface SessionDraft {
  schemaVersion: number
  sessionId: string
  protocolKey: string
  protocolSessionId: string
  dataFlow: SessionDataFlow
  initiatedBy: SessionInitiator
  stage: SessionStage
  textMessage: boolean
  peer: SessionPeer
  localAlias: string
  localIp: string
  localInterfaceName: string
  startedAt: number
  transferStartedAt: number
  updatedAt: number
  files: Array<SessionDraftFile>
  // 任务目标目录（MTA 占位草稿用于强杀后清理该协议临时区；其他协议可缺省）
  targetDir?: string
  capabilities?: SessionCapabilities
  // 发送方向终态快照（可选）：强杀窗口内用于原样归档，避免把已成功任务降级。
  errorMessage?: string
  errorCode?: string
}

/** 返回草稿根目录；上下文缺失时返回空串。 */
export function sessionDraftDir(): string {
  let context = getAppContext();
  if (context === undefined) {
    return '';
  }
  return context.filesDir + '/' + SESSION_DRAFT_DIR_NAME;
}

/** 目录不存在时创建；成功返回目录，失败返回空串。 */
function ensureSessionDraftDir(): string {
  let dir: string = sessionDraftDir();
  if (dir.length === 0) {
    logger.warn('会话草稿目录不可用：应用上下文缺失');
    return '';
  }
  try {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    return dir;
  } catch (e) {
    logger.warn('创建会话草稿目录失败：' + String(e));
    return '';
  }
}

/** 会话标识转安全文件名：只保留字母、数字、点、下划线和连字符。 */
export function sanitizeDraftId(sessionId: string): string {
  let result: string = '';
  for (let i = 0; i < sessionId.length; i++) {
    let code: number = sessionId.charCodeAt(i);
    let allowed: boolean = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) || code === 46 || code === 95 || code === 45;
    result += allowed ? sessionId.charAt(i) : '_';
  }
  return result.length > 0 ? result : 'session';
}

/** 草稿文件路径。 */
export function sessionDraftPath(sessionId: string): string {
  let dir: string = sessionDraftDir();
  if (dir.length === 0) {
    return '';
  }
  return dir + '/' + sanitizeDraftId(sessionId) + DRAFT_SUFFIX;
}

/** 保存草稿：写临时文件后原子 rename；失败返回 false。 */
export function saveSessionDraft(draft: SessionDraft): boolean {
  let dir: string = ensureSessionDraftDir();
  if (dir.length === 0) {
    return false;
  }
  let path: string = dir + '/' + sanitizeDraftId(draft.sessionId) + DRAFT_SUFFIX;
  let tmp: string = path + '.tmp';
  try {
    let json: string = JSON.stringify(draft);
    let file: fs.File = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY |
      fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, json);
      // 立即落盘：强杀可能发生在保存调用后的极短窗口内，不能依赖后续 flush。
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(tmp, path);
    // rename 只保证目录项在内存中更新；立即强杀仍可能丢失。同步目录项后才算持久化。
    fsyncDirectory(dir);
    logger.debug('保存会话草稿 session=' + sanitizeDraftId(draft.sessionId) +
      ' files=' + draft.files.length + ' stage=' + draft.stage);
    return true;
  } catch (e) {
    logger.warn('保存会话草稿失败 session=' + sanitizeDraftId(draft.sessionId) + '：' + String(e));
    try {
      if (fs.accessSync(tmp)) {
        fs.unlinkSync(tmp);
      }
    } catch (_cleanupError) {
    }
    return false;
  }
}

/** 读取单个草稿；文件不存在、解析失败或版本不匹配时返回 undefined。 */
export function loadSessionDraft(sessionId: string): SessionDraft | undefined {
  let path: string = sessionDraftPath(sessionId);
  if (path.length === 0) {
    return undefined;
  }
  return loadDraftFile(path);
}

function loadDraftFile(path: string): SessionDraft | undefined {
  try {
    if (!fs.accessSync(path)) {
      return undefined;
    }
    let text: string = fs.readTextSync(path);
    let draft: SessionDraft = JSON.parse(text) as SessionDraft;
    if (draft.schemaVersion !== SESSION_DRAFT_SCHEMA_VERSION) {
      logger.debug('忽略版本不匹配的会话草稿：' + path);
      return undefined;
    }
    if (typeof draft.sessionId !== 'string' || draft.sessionId.length === 0 ||
      !Array.isArray(draft.files)) {
      logger.warn('会话草稿字段不完整：' + path);
      return undefined;
    }
    return draft;
  } catch (e) {
    logger.warn('读取会话草稿失败：' + path + '：' + String(e));
    return undefined;
  }
}

/** 读取目录中全部有效草稿。 */
export function loadAllSessionDrafts(): Array<SessionDraft> {
  let dir: string = sessionDraftDir();
  if (dir.length === 0) {
    return [];
  }
  let drafts: Array<SessionDraft> = [];
  try {
    let names: Array<string> = fs.listFileSync(dir);
    for (let i = 0; i < names.length; i++) {
      let name: string = names[i];
      if (!name.endsWith(DRAFT_SUFFIX)) {
        continue;
      }
      let draft: SessionDraft | undefined = loadDraftFile(dir + '/' + name);
      if (draft !== undefined) {
        drafts.push(draft);
      }
    }
  } catch (e) {
    logger.warn('枚举会话草稿失败：' + String(e));
  }
  logger.debug('读取会话草稿 count=' + drafts.length);
  return drafts;
}

/** 删除指定会话的草稿与临时文件。 */
export function removeSessionDraft(sessionId: string): void {
  let path: string = sessionDraftPath(sessionId);
  if (path.length === 0) {
    return;
  }
  removeFileIfExists(path);
  removeFileIfExists(path + '.tmp');
}

/** 清理原子写遗留的临时文件。 */
export function cleanupSessionDraftTmp(): void {
  let dir: string = sessionDraftDir();
  if (dir.length === 0) {
    return;
  }
  try {
    let names: Array<string> = fs.listFileSync(dir);
    for (let i = 0; i < names.length; i++) {
      if (names[i].endsWith(DRAFT_TMP_SUFFIX)) {
        removeFileIfExists(dir + '/' + names[i]);
      }
    }
  } catch (e) {
    logger.debug('清理会话草稿临时文件失败：' + String(e));
  }
}

/** 删除超过保留期的草稿；用于避免无法恢复的旧文件长期占用空间。 */
export function cleanupStaleSessionDrafts(now: number): void {
  let drafts: Array<SessionDraft> = loadAllSessionDrafts();
  for (let i = 0; i < drafts.length; i++) {
    let draft: SessionDraft = drafts[i];
    if (draft.updatedAt > 0 && now - draft.updatedAt > DRAFT_STALE_MS) {
      removeSessionDraft(draft.sessionId);
    }
  }
}

function removeFileIfExists(path: string): void {
  try {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  } catch (e) {
    logger.debug('删除会话草稿文件失败：' + path + '：' + String(e));
  }
}

/**
 * 同步目录项：rename 后不 fsync 目录时，强杀可能丢失新建/改名的目录项，
 * 出现“保存日志已打印、重启后 count=0”。文件系统不支持目录 fsync 时静默忽略。
 */
function fsyncDirectory(dir: string): void {
  let directory: fs.File | undefined = undefined;
  try {
    directory = fs.openSync(dir, fs.OpenMode.READ_ONLY);
    fs.fsyncSync(directory.fd);
  } catch (e) {
    // 部分文件系统不支持对目录 fsync；记录诊断，文件内容已在 rename 前 fsync。
    logger.debug('目录 fsync 跳过：' + String(e));
  } finally {
    if (directory !== undefined) {
      try {
        fs.closeSync(directory);
      } catch (_e) {
      }
    }
  }
}
