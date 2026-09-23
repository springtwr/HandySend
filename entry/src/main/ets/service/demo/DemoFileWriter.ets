/**
 * DemoFileWriter.ets — 演示文件落盘与接收历史写入（仅演示分支存在）
 *
 * 收方向场景完成前生成小体积占位文件（图片为可解码 1×1 PNG、文本为内容文件），
 * 使接收历史页的类型图标、缩略图、文本缩略预览等既有要素真实渲染。
 * 占位文件大小与演示元数据（GB/MB 级）解耦：历史条目 size 按演示元数据显示。
 * 落盘目录与真实 MTA 接收一致（Download/<bundleName>），解析失败回退应用沙箱目录。
 */

import { common } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { ReceiveHistoryEntry } from '../../model/Types';
import { addEntry } from '../repository/ReceiveHistoryService';
import { uniquePath } from '../repository/ReceiveTargets';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { DemoFileKind, DemoFileSpec } from './DemoData';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:DemoFileWriter', '演示落盘');

/** 已落盘的演示文件（fileId 与会话文件条目对应，供调用方回填会话路径） */
export interface DemoWrittenFile {
  fileId: string
  fileName: string
  /** 完整磁盘路径 */
  path: string
}

/** 可解码的 1×1 透明 PNG 占位图（接收历史缩略图真实渲染用） */
const PLACEHOLDER_PNG_BYTES: Uint8Array = new Uint8Array([
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
  0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0,
  0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 100, 248, 15, 0, 1, 5,
  1, 1, 39, 24, 227, 102, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130
]);

/** 通用占位文件内容（非图片/文本条目的占位说明） */
const GENERIC_PLACEHOLDER_TEXT: string = 'HandySend 演示占位文件：实际内容以会话元数据为准。';

// 演示落盘目录（initDemoModule 时解析缓存；空串表示未初始化）
let demoRecvDir: string = '';

// 接收历史条目序号（保证演示条目 id 唯一）
let historySeq: number = 0;

/**
 * 解析演示落盘目录：优先 Download/<bundleName>（与真实 MTA 接收一致），
 * 解析失败回退应用沙箱 filesDir/demo_received。
 */
export function initDemoFileWriter(context: common.Context): void {
  if (demoRecvDir.length > 0) {
    return;
  }
  let resolved: string = '';
  try {
    let bundleFlags = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
    let info = bundleManager.getBundleInfoForSelfSync(bundleFlags);
    let uri = `file://docs/storage/Users/currentUser/Download/${info.name}`;
    resolved = new fileUri.FileUri(uri).path;
  } catch (e) {
    logger.warn('解析 Download 目录失败，回退应用沙箱目录: ' + String(e));
    resolved = `${context.filesDir}/demo_received`;
  }
  try {
    if (!fs.accessSync(resolved)) {
      fs.mkdirSync(resolved, true);
    }
    demoRecvDir = resolved;
  } catch (e) {
    logger.warn('演示落盘目录不可用: ' + String(e));
    demoRecvDir = '';
  }
}

/** 取演示落盘目录（未初始化或解析失败时返回空串，调用方据此跳过落盘） */
export function getDemoRecvDir(): string {
  return demoRecvDir;
}

/**
 * 按演示清单生成占位文件（同名冲突自动编号），返回已落盘条目。
 * 目录不可用或单文件写失败时跳过该条目（不中断场景收尾）。
 */
export function writeDemoFiles(specs: Array<DemoFileSpec>): Array<DemoWrittenFile> {
  let written: Array<DemoWrittenFile> = [];
  if (demoRecvDir.length === 0) {
    logger.warn('演示落盘目录未就绪，跳过占位文件生成');
    return written;
  }
  for (let i = 0; i < specs.length; i++) {
    let spec = specs[i];
    let fileName = uniquePath(demoRecvDir, spec.fileName);
    let path = `${demoRecvDir}/${fileName}`;
    try {
      if (spec.demoKind === DemoFileKind.image) {
        writePlaceholderPng(path);
      } else {
        writeTextFile(path, GENERIC_PLACEHOLDER_TEXT);
      }
      written.push({ fileId: spec.fileId, fileName: fileName, path: path });
    } catch (e) {
      logger.warn('演示占位文件写入失败: ' + spec.fileName + ' 原因: ' + String(e));
    }
  }
  return written;
}

/** 写入指定文本内容为演示文本文件，返回完整路径；失败返回空串 */
export function writeDemoTextFile(fileName: string, content: string): string {
  if (demoRecvDir.length === 0) {
    return '';
  }
  let resolvedName = uniquePath(demoRecvDir, fileName);
  let path = `${demoRecvDir}/${resolvedName}`;
  try {
    writeTextFile(path, content);
    return path;
  } catch (e) {
    logger.warn('演示文本文件写入失败: ' + fileName + ' 原因: ' + String(e));
    return '';
  }
}

/**
 * 按演示元数据构造接收历史条目并写入（文件场景每个文件一条，文本场景单条）。
 * fileSize 按演示元数据显示（与占位文件实际大小解耦）。
 */
export function appendReceiveHistory(specs: Array<DemoFileSpec>, written: Array<DemoWrittenFile>,
  senderAlias: string, isMessage: boolean, textContent?: string): void {
  for (let i = 0; i < specs.length; i++) {
    let spec = specs[i];
    let path = findWrittenPath(written, spec.fileId);
    let entry: ReceiveHistoryEntry = {
      id: `demo-hist-${Date.now()}-${historySeq}`,
      fileName: path.fileName.length > 0 ? path.fileName : spec.fileName,
      fileType: spec.fileType,
      path: path.path,
      savedToGallery: false,
      isMessage: isMessage,
      fileSize: spec.sizeBytes,
      senderAlias: senderAlias,
      timestamp: Date.now()
    };
    if (isMessage && textContent !== undefined) {
      entry.textContent = textContent;
    }
    historySeq++;
    addEntry(entry);
  }
}

/** 写入文本内容（fs 无按路径写的同步接口，按项目既有 open/write/close 模式实现） */
function writeTextFile(path: string, content: string): void {
  let file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE |
    fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, content);
  } finally {
    fs.closeSync(file);
  }
}

/** 写入 PNG 占位图字节 */
function writePlaceholderPng(path: string): void {
  let file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE |
    fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, PLACEHOLDER_PNG_BYTES.buffer);
  } finally {
    fs.closeSync(file);
  }
}

/** 按 fileId 查找已落盘路径（未命中返回空值对象） */
function findWrittenPath(written: Array<DemoWrittenFile>, fileId: string): DemoWrittenFile {
  for (let i = 0; i < written.length; i++) {
    if (written[i].fileId === fileId) {
      return written[i];
    }
  }
  let empty: DemoWrittenFile = { fileId: fileId, fileName: '', path: '' };
  return empty;
}
