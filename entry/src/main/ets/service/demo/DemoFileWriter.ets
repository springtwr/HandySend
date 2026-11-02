/**
 * DemoFileWriter.ets — 演示文件落盘与接收历史写入（仅演示分支存在）
 *
 * 收方向场景完成前生成小体积占位文件（图片为可解码的渐变 PNG、文本为内容文件），
 * 使接收历史页的类型图标、缩略图、文本缩略预览等既有要素真实渲染。
 * 占位文件大小与演示元数据（GB/MB 级）解耦：历史条目 size 按演示元数据显示。
 * 落盘目录与真实 MTA 接收一致（Download/<bundleName>），解析失败回退应用沙箱目录。
 */

import { common } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { ReceiveHistoryEntry } from '../../model/Types';
import { addEntries } from '../repository/ReceiveHistoryService';
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

/**
 * 可解码的 32×32 渐变 PNG 占位图（base64）：缩略图渲染出可见图案，
 * 避免 1×1 透明图在列表里呈现为空白、被误判为「没有缩略图」。
 */
const PLACEHOLDER_PNG_BASE64: string =
  'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAEXUlEQVR42r3VaVObZRgF4Of/qKPWuiCiiAiDkcLESJuJMYWGFMzECKUxBVNKi4hYShdaW8pSoCn7viUQAoGwBwo0bIVSRETUqtVxHMcvR48zcVy6sLzpL7hyzrnzvCLf7EROUjsy9A0wx1fCqCmFTlmAeNVlaNWFiNMUITa2GPsPlEATfwXvHiyFOrEM7+jLoTJchfJ9K/Z9cA17kysQk1KJt01VUJir8VZqDeQf1SL6aB2ijtVjz/EGRGY24s2sJsiym/FGTgsiTrZCED+T1oPswzakG5tgSqyG4UD5I8HDc//8AUxOPC/dhawjnbAcakGKoRbvHbT6HQ/La4Ng7UxOPPdEPzItDqR+2IakpHok6Cv8ir9+ph2Cm7N2Jiee88kAMjKcMKd1wHi4ETpjld/w0HMdEDw4bs7amZx49mdDSP+4F6Z0OwxHmqE9VOMX/LXzNgjftXNz1s7kxLPyRmD5tA8pJ7qgt7Qi1lQnOR7yuR3in9fOzVk7kxPPPDeGtFw3krK6kXCsHZrUBknxVy91Qvz3r8bNWTuTE8+4MA7z6UEYc3qgy7RBfbRJMvyVy10Q9/qrcXPWzuTE0wuuw5Q/DMMpF7TZnVAdb5EEf7nIAXG//zk3Z+1MTtxSPIWUi6PQn+1H3EkH9mW17RgPKumGeND/nJuzdiYnnlZ2A8mFHiRcGIDmtBMxOR07wl8qdUI87JHh5qydyYmbr83AeGUCuoIhqPN7oThl3zYeWN4DsZlHhpuzdiYnbqqeg+HqJLTFI1Bd7IP8bNe28BetvRCbfeG4OWtncuIp9QvQV04jrmwMykI3os47towHVLggtvLCcXPWzuTEk5sXkVjrhcbqQUzJACIvObeEv1DVB7HV55Wbs3YmJ25sW4KuYQbqqgkoyocgK+rdNP5cdT/Edp5Xbs7amZy4wb4MbcscVHWTkFeMIKK0b1P4s7VuiO2+7dyctTM5cX33CuI6FqBsmkZUzRjCrO6H4rvrByB28rZzc9bO5MQTXavQdC0ips2LyIZxhFYNPhB/pnEQYqcfFm7O2pmcuG5gDeqeW1DYZyFruY6QuuH74ruahyCk+LBwc9bO5MS1I+tQ9d+GvHseER1TCG4avSf+dOswhFRfNW7O2pmceNz4BpRDXyDadRNhnTcQ1Or5H/5U+wiEVF81Hhw3Z+1MTnz/1LeIGf0Ske4lhDpnEGib+Bf+pG0UQircd+3cnLUzOXG19w4UE19BNryMkL45BDgm/8af6ByDkBL3XTs3Z+1MTlw1/wPk018jwrOC4MEFPN87/Rf+uMMDITXuu3ZuztqZnLhy6S6iZ79B+OQqgkYXsdvtxWPOcQh/4L5r5+asncmJ7135GZE3v0Oodw2BE7ewa3gWwl+479q5OWtncuKKtV8gW/4eIfPrCJi+DeFP3Hft3Jy1Mzlx+caviFj9EcFLGxD+xn3Xzs1ZO5MTj77zG8LXf4J4FDivnQfHzVk7kxPfc/d3/AGQ42IK+BxmzwAAAABJRU5ErkJggg==';

// 解码后的占位图字节（首次使用时解码并缓存；解码失败缓存空数组）
let placeholderPngBytes: Uint8Array | undefined = undefined;

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
 * 确保演示占位文件就位：同名文件已存在则复用（启动多次不重复落盘），
 * 缺失时按文件类型写入（图片写可解码 PNG，其余写入给定内容），返回完整路径；
 * 目录不可用或写入失败返回空串。
 */
export function ensureDemoFile(fileName: string, kind: DemoFileKind, content: string): string {
  if (demoRecvDir.length === 0) {
    return '';
  }
  let path = `${demoRecvDir}/${fileName}`;
  try {
    if (!fs.accessSync(path)) {
      if (kind === DemoFileKind.image) {
        writePlaceholderPng(path);
      } else {
        writeTextFile(path, content);
      }
    }
    return path;
  } catch (e) {
    logger.warn('演示占位文件准备失败: ' + fileName + ' 原因: ' + String(e));
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
    addEntries([entry]);
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

/** 写入 PNG 占位图字节（首次调用解码并缓存；解码失败写入空文件，由渲染端按不可用降级） */
function writePlaceholderPng(path: string): void {
  if (placeholderPngBytes === undefined) {
    try {
      placeholderPngBytes = new util.Base64Helper().decodeSync(PLACEHOLDER_PNG_BASE64, util.Type.BASIC);
    } catch (e) {
      logger.warn('演示占位图解码失败: ' + String(e));
      placeholderPngBytes = new Uint8Array(0);
    }
  }
  let file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE |
    fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, placeholderPngBytes.buffer);
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
