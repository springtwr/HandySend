/**
 * UriPermission.ets — Picker URI 的持久化授权与激活
 *
 * Picker 返回的 URI 只带临时授权，超过有效期或应用重启后即不可读（重启无关，时间到期同样失效）。
 * 官方提供的正解是把临时授权持久化到系统数据库（不占应用存储），重启后再激活：
 * - persistPermission：选择文件后立即调用，把当时的临时授权转成持久授权；
 * - activatePermission：每次进程启动后按需调用，使已持久化的授权在本进程生效。
 *
 * 本模块只做能力封装与失败降级：持久化/激活失败不阻断业务流程（文件届时按不可读处理）。
 */

import { fileShare } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { getLogger } from './Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:UriPermission', 'URI授权');

/** 设备是否具备文件持久化授权能力 */
const PERSIST_CAPABILITY: string = 'SystemCapability.FileManagement.AppFileService.FolderAuthorization';

/** 本进程内已激活成功的 URI：避免每次访问都调用系统接口 */
const activatedUris: Set<string> = new Set();
/** 本进程内激活失败的 URI（旧会话未持久化过）：不再重复调用，读取动作自会降级 */
const activationFailedUris: Set<string> = new Set();
/** 本进程内已激活读写授权的目录 URI（与只读集合分开，避免只读激活被误判为已具备写权限） */
const activatedWritableUris: Set<string> = new Set();
/** 本进程内读写授权激活失败的目录 URI */
const activationFailedWritableUris: Set<string> = new Set();

function isSupported(): boolean {
  try {
    return canIUse(PERSIST_CAPABILITY);
  } catch (_e) {
    return false;
  }
}

/** 仅对 file:// 定位执行（沙箱路径无需系统授权） */
function isUriLike(path: string): boolean {
  return path.startsWith('file://');
}

/**
 * 选择文件后立即调用：把 Picker 给出的临时授权持久化，供后续（跨过期时间 / 跨进程）使用。
 * 逐 URI 构造只读策略；部分 URI 失败只记录日志，不影响已成功的部分。
 */
export async function persistPickedUris(uris: Array<string>): Promise<void> {
  if (!isSupported() || uris.length === 0) {
    return;
  }
  let policies: Array<fileShare.PolicyInfo> = [];
  for (let i = 0; i < uris.length; i++) {
    if (!isUriLike(uris[i])) {
      continue;
    }
    let policy: fileShare.PolicyInfo = {
      uri: uris[i],
      operationMode: fileShare.OperationMode.READ_MODE
    };
    policies.push(policy);
  }
  if (policies.length === 0) {
    return;
  }
  try {
    await fileShare.persistPermission(policies);
    // 持久化成功后清除此前的激活失败标记：下次访问会重新尝试激活
    for (let i = 0; i < policies.length; i++) {
      activationFailedUris.delete(policies[i].uri);
    }
    logger.debug('URI 持久化授权成功 数量=' + policies.length);
  } catch (e) {
    // 部分失败时错误对象内带逐 URI 的原因，记录首个失败便于定位
    logger.warn('URI 持久化授权失败 数量=' + policies.length + ' 原因=' + String(e));
  }
}

/**
 * 访问前调用：确保该 URI 的持久化授权在当前进程生效。
 * 已激活过的 URI 直接返回；未持久化过的 URI（旧会话）会失败，按不可读降级。
 */
export async function ensureUriAccess(uri: string): Promise<void> {
  if (!isUriLike(uri) || activatedUris.has(uri) || activationFailedUris.has(uri)) {
    return;
  }
  if (!isSupported()) {
    return;
  }
  let policy: fileShare.PolicyInfo = {
    uri: uri,
    operationMode: fileShare.OperationMode.READ_MODE
  };
  try {
    await fileShare.activatePermission([policy]);
    activatedUris.add(uri);
  } catch (e) {
    // 未持久化（旧会话）/ 非持久化来源：记录后不再重复调用，交由实际读取动作给出结果
    activationFailedUris.add(uri);
    logger.debug('URI 授权激活失败 uri=' + uri + ' 原因=' + String(e));
  }
}

/**
 * 选择目录后立即调用：把目录 URI 的临时授权持久化为读写权限。
 * 接收文件需要在目录内创建新文件，READ_MODE 不足，必须带 WRITE_MODE。
 */
export async function persistWritableUri(uri: string): Promise<void> {
  if (!isSupported() || !isUriLike(uri)) {
    return;
  }
  let policy: fileShare.PolicyInfo = {
    uri: uri,
    operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
  };
  try {
    await fileShare.persistPermission([policy]);
    // 持久化成功后清除此前的激活失败标记：下次访问会重新尝试激活
    activationFailedUris.delete(uri);
    activationFailedWritableUris.delete(uri);
    logger.debug('目录读写授权持久化成功 uri=' + uri);
  } catch (e) {
    logger.warn('目录读写授权持久化失败 uri=' + uri + ' 原因=' + String(e));
  }
}

/**
 * 访问自定义接收目录前调用：激活已持久化的读写授权。
 * 未持久化过或授权已被撤销时记录后不再重复调用，由目录校验兜底回退默认目录。
 */
export async function ensureWritableUriAccess(uri: string): Promise<void> {
  if (!isUriLike(uri) || activatedWritableUris.has(uri) || activationFailedWritableUris.has(uri)) {
    return;
  }
  if (!isSupported()) {
    return;
  }
  let policy: fileShare.PolicyInfo = {
    uri: uri,
    operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
  };
  try {
    await fileShare.activatePermission([policy]);
    activatedWritableUris.add(uri);
  } catch (e) {
    activationFailedWritableUris.add(uri);
    logger.debug('目录读写授权激活失败 uri=' + uri + ' 原因=' + String(e));
  }
}

/** 历史记录被删除时撤销对应授权，避免系统侧持久化条目无限累积。 */
export async function revokeUriAccess(uris: Array<string>): Promise<void> {
  if (!isSupported() || uris.length === 0) {
    return;
  }
  let policies: Array<fileShare.PolicyInfo> = [];
  for (let i = 0; i < uris.length; i++) {
    if (!isUriLike(uris[i])) {
      continue;
    }
    activatedUris.delete(uris[i]);
    let policy: fileShare.PolicyInfo = {
      uri: uris[i],
      operationMode: fileShare.OperationMode.READ_MODE
    };
    policies.push(policy);
  }
  if (policies.length === 0) {
    return;
  }
  try {
    await fileShare.revokePermission(policies);
  } catch (e) {
    logger.debug('URI 撤销持久化授权失败 数量=' + policies.length + ' 原因=' + String(e));
  }
}
