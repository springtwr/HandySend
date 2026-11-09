/**
 * TempWorkspaceSweep.ets — 接收临时区清扫
 *
 * 统一清理 `<目标目录>/.handysend-temp/` 下各协议子目录、旧版协议子目录与
 * 旧版临时区中的未完成文件，完成后移除空目录。活跃会话登记的临时路径一律
 * 保留，避免误删仍在写入的半成品。
 *
 * 与 Rust 侧 `bridge/temp_workspace.rs` 的目录规则保持一致；本模块负责
 * ArkTS 启动恢复阶段的兜底清扫。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { isTerminalStage } from '../../model/transfer/TransferSession';
import {
  dirNameOf,
  LEGACY_TEMP_DIR_NAMES,
  LEGACY_TEMP_SUBDIRS,
  TEMP_DIR_NAME,
  TEMP_SUBDIRS,
  tempPathsForFinal
} from '../../model/transfer/TransferTempPaths';
import { SessionDraft, loadAllSessionDrafts } from './SessionDraftStore';
import { findByProtocol, getSession } from './TransferSessionRegistry';
import {
  ensureRecvTextDir,
  getRegisteredRecvTempPaths,
  removeDirectoryIfEmpty
} from '../repository/ReceiveTargets';
import { ensureReceiveDirectory } from '../repository/ReceiveDirectory';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:TempSweep', '临时区清扫');

/** 一次清扫的统计结果。 */
export interface TempSweepSummary {
  dirs: number
  files: number
}

/** 清扫单个目标目录，返回删除的临时文件数；keep 中的路径不删除。 */
export function sweepTempWorkspaceDir(targetDir: string, keep: Set<string>): number {
  if (targetDir.length === 0) {
    return 0;
  }
  let root: string = targetDir + '/' + TEMP_DIR_NAME;
  let removed: number = 0;
  for (let i = 0; i < TEMP_SUBDIRS.length; i++) {
    removed += sweepFlatDir(root + '/' + TEMP_SUBDIRS[i], keep);
  }
  // 旧版协议子目录：新版本不再写入，全部视为遗留
  for (let i = 0; i < LEGACY_TEMP_SUBDIRS.length; i++) {
    removed += sweepFlatDir(root + '/' + LEGACY_TEMP_SUBDIRS[i], keep);
  }
  // 旧版根目录直接存放的临时文件（协议子目录之前的结构）
  removed += sweepRootFiles(root, keep);
  // 旧版临时区目录
  for (let i = 0; i < LEGACY_TEMP_DIR_NAMES.length; i++) {
    removed += sweepFlatDir(targetDir + '/' + LEGACY_TEMP_DIR_NAMES[i], keep);
  }
  removeDirectoryIfEmpty(root);
  return removed;
}

/** 清扫多个目标目录（去重），返回统计结果。 */
export function sweepTempWorkspaceDirs(dirs: Array<string>,
  keep: Set<string>): TempSweepSummary {
  let unique: Set<string> = new Set<string>();
  for (let i = 0; i < dirs.length; i++) {
    if (dirs[i].length > 0) {
      unique.add(dirs[i]);
    }
  }
  let summary: TempSweepSummary = {
    dirs: 0,
    files: 0
  };
  unique.forEach((dir: string) => {
    summary.files += sweepTempWorkspaceDir(dir, keep);
    summary.dirs++;
  });
  return summary;
}

/** 草稿对应会话是否仍在注册表中且未终结（进程存活、仅 Ability 重建的场景）。 */
function isDraftSessionActive(draft: SessionDraft): boolean {
  let session = getSession(draft.sessionId);
  if (session === undefined && draft.protocolSessionId.length > 0) {
    session = findByProtocol(draft.protocolKey, draft.protocolSessionId);
  }
  return session !== undefined && !isTerminalStage(session.stage);
}

/** 收集活跃会话需要保留的临时路径（含进程内已登记但草稿尚未写入的目标）。 */
export function collectActiveTempKeepSet(drafts: Array<SessionDraft>): Set<string> {
  let keep: Set<string> = new Set<string>();
  for (let i = 0; i < drafts.length; i++) {
    let draft: SessionDraft = drafts[i];
    if (!isDraftSessionActive(draft)) {
      continue;
    }
    for (let j = 0; j < draft.files.length; j++) {
      let file = draft.files[j];
      if (file.tempPath.length > 0) {
        keep.add(file.tempPath);
      }
      if (file.finalPath.length > 0) {
        let candidates: Array<string> = tempPathsForFinal(file.finalPath);
        for (let k = 0; k < candidates.length; k++) {
          keep.add(candidates[k]);
        }
      }
    }
  }
  let registered: Array<string> = getRegisteredRecvTempPaths();
  for (let i = 0; i < registered.length; i++) {
    keep.add(registered[i]);
  }
  return keep;
}

/** 从草稿收集需要清扫的目标目录（最终文件父目录与 MTA 草稿的目标目录）。 */
export function collectDraftTempDirs(drafts: Array<SessionDraft>): Array<string> {
  let dirs: Set<string> = new Set<string>();
  for (let i = 0; i < drafts.length; i++) {
    let draft: SessionDraft = drafts[i];
    if (draft.targetDir !== undefined && draft.targetDir.length > 0) {
      dirs.add(draft.targetDir);
    }
    for (let j = 0; j < draft.files.length; j++) {
      let finalPath: string = draft.files[j].finalPath;
      if (finalPath.length === 0) {
        continue;
      }
      let dir: string = dirNameOf(finalPath);
      if (dir.length > 0) {
        dirs.add(dir);
      }
    }
  }
  let result: Array<string> = [];
  dirs.forEach((dir: string) => {
    result.push(dir);
  });
  return result;
}

/**
 * 启动清扫：先同步清扫草稿涉及的目录，再异步解析接收目录后兜底清扫。
 *
 * 同步部分在首次 await 之前完成，保证调用方紧接着执行恢复逻辑时草稿目录
 * 已被清扫；接收目录解析完成后补扫无草稿可推导的残留。
 */
export function sweepReceiveTempWorkspacesOnInit(): Promise<TempSweepSummary> {
  let drafts: Array<SessionDraft> = loadAllSessionDrafts();
  let keep: Set<string> = collectActiveTempKeepSet(drafts);
  let dirs: Array<string> = collectDraftTempDirs(drafts);
  let textDir: string = ensureRecvTextDir();
  if (textDir.length > 0) {
    dirs.push(textDir);
  }
  let summary: TempSweepSummary = sweepTempWorkspaceDirs(dirs, keep);
  return ensureReceiveDirectory().then((receiveDir: string): TempSweepSummary => {
    if (receiveDir.length > 0) {
      let more: TempSweepSummary = sweepTempWorkspaceDirs([receiveDir], keep);
      summary.dirs += more.dirs;
      summary.files += more.files;
    }
    if (summary.files > 0) {
      logger.info('启动清扫接收临时区 目录=' + summary.dirs + ' 文件=' + summary.files);
    }
    return summary;
  }).catch((e: Error): TempSweepSummary => {
    logger.warn('启动清扫接收临时区失败：' + e.message);
    return summary;
  });
}

/** 清扫单个目录的直接子文件；子目录与非 keep 路径保留。 */
function sweepFlatDir(dir: string, keep: Set<string>): number {
  let removed: number = 0;
  try {
    if (!fs.accessSync(dir)) {
      return 0;
    }
    let names: Array<string> = fs.listFileSync(dir);
    for (let i = 0; i < names.length; i++) {
      let path: string = dir + '/' + names[i];
      let isDir: boolean = false;
      try {
        isDir = fs.statSync(path).isDirectory();
      } catch (_e) {
        continue;
      }
      if (isDir || keep.has(path)) {
        continue;
      }
      try {
        fs.unlinkSync(path);
        removed++;
      } catch (_e) {
      }
    }
  } catch (_e) {
    return removed;
  }
  removeDirectoryIfEmpty(dir);
  return removed;
}

/** 清扫临时区根目录下直接存放的旧版临时文件；子目录由调用方分别处理。 */
function sweepRootFiles(root: string, keep: Set<string>): number {
  let removed: number = 0;
  try {
    if (!fs.accessSync(root)) {
      return 0;
    }
    let names: Array<string> = fs.listFileSync(root);
    for (let i = 0; i < names.length; i++) {
      let path: string = root + '/' + names[i];
      let isDir: boolean = false;
      try {
        isDir = fs.statSync(path).isDirectory();
      } catch (_e) {
        continue;
      }
      if (isDir || keep.has(path)) {
        continue;
      }
      try {
        fs.unlinkSync(path);
        removed++;
      } catch (_e) {
      }
    }
  } catch (_e) {
    return removed;
  }
  return removed;
}
