import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { NetworkInterface, NetworkType } from '../../model/Types';
import { NativeServerHandle, NativeDiscoveryConfig } from '../../model/NativeTypes';
import {
  nativeCreateServer,
  nativeStopServer,
  nativeGetServerStatus,
  nativeStartDiscoveryV2,
  nativeDiscoverySetAnswerAnnouncements,
  nativeDiscoveryStop
} from '../NativeBridge';
import {
  getAppContext,
  notifyChange,
  updateLocalInterfaces,
  getLocalInterfaces,
  getServerFingerprint as getServerFingerprintValue,
  setServerFingerprint
} from './AppCore';
import {
  getHttpsEnabled,
  getPort,
  getReceivePin,
  getMulticastGroup,
  getDiscoveryTimeout,
  getNetworkListAsArray,
  clearServerNeedsRestart,
  isVerifyChecksums,
  ensureDefaultNetworkLists
} from './SettingsRepository';
import { KEY_NETWORK_WHITELIST, KEY_NETWORK_BLACKLIST } from '../../utils/PreferencesUtil';
import { getDeviceAlias, getDeviceModel, getDeviceType, getLocalDeviceInfo } from './DeviceRepository';
import { triggerStagedDiscover, clearDiscoveryState, resetScanState } from './DiscoveryRepository';
import { getShareLink, stopShareLink } from './WebShareRepository';
import { getPendingRecvMediaPaths } from './ReceiveRepository';
import { refreshMtaReceiveIdentity } from './MtaRepository';

const logger = getLogger(LogDomains.SERVER, 'HandySend:ServerRepository', '服务端');

// 网络黑名单解析：读取用户配置的黑名单接口名（如 wlan0,ancowlan0），
// 对匹配接口名的本地接口生成精确 IP 列表，传给 Rust 层 InterfaceFilter。
// 无黑名单配置时返回 undefined（Rust 层不排除）。
function resolveNetworkBlacklist(): Array<string> | undefined {
  let blacklistedNames = getNetworkListAsArray(KEY_NETWORK_BLACKLIST);
  if (blacklistedNames === undefined || blacklistedNames.length === 0) {
    return undefined;
  }
  let result: Array<string> = [];
  let interfaces = getLocalInterfaces();
  for (let i = 0; i < interfaces.length; i++) {
    let iface = interfaces[i];
    if (iface.ip === '0.0.0.0') {
      continue;
    }
    for (let j = 0; j < blacklistedNames.length; j++) {
      if (blacklistedNames[j] === iface.name) {
        result.push(iface.ip);
        break;
      }
    }
  }
  if (result.length > 0) {
    logger.debug('黑名单: [' + blacklistedNames.join(', ') + '] -> IP 列表: [' + result.join(', ') + ']');
    return result;
  }
  return undefined;
}

// 根据接口 IP 与前缀长度生成网段通配（IPv4 点分 4 段）：
// prefixLength >= 24 生成 a.b.c.*，否则生成 a.b.*（宁多勿漏，保证包含当前接口 IP）；
// ip 不足 4 段时返回空串。
export function subnetPattern(ip: string, prefixLength: number): string {
  let parts = ip.split('.');
  if (parts.length < 4) {
    return '';
  }
  if (prefixLength >= 24) {
    return parts[0] + '.' + parts[1] + '.' + parts[2] + '.*';
  }
  return parts[0] + '.' + parts[1] + '.*';
}

// 计算 discovery 网络白名单（纯函数）：
// 用户白名单存储接口名（如 wlan0,eth0），将匹配接口名的接口映射为网段通配，
// 使 Rust 只在这些局域网接口上绑定组播 socket。
// - 白名单为空或无匹配接口 → 返回 []（空列表，Rust 侧忽略全部接口，不扫描）
// - 黑名单接口优先排除（即使同时出现在白名单中）
// - 网段通配去重
export function computeDiscoveryWhitelistFrom(
  whitelistedNames: Array<string>,
  blacklistedNames: Array<string>,
  interfaces: Array<NetworkInterface>
): Array<string> {
  // 白名单为空 → 不扫描任何接口
  if (whitelistedNames.length === 0) {
    return [];
  }
  let result: Array<string> = [];
  for (let i = 0; i < interfaces.length; i++) {
    let iface = interfaces[i];

    // 黑名单接口优先排除（即使同时出现在白名单中）
    let isBlacklisted = false;
    for (let j = 0; j < blacklistedNames.length; j++) {
      if (blacklistedNames[j] === iface.name) {
        isBlacklisted = true;
        break;
      }
    }
    if (isBlacklisted) {
      continue;
    }

    // 按白名单接口名匹配
    let shouldInclude = false;
    for (let j = 0; j < whitelistedNames.length; j++) {
      if (whitelistedNames[j] === iface.name) {
        shouldInclude = true;
        break;
      }
    }
    if (!shouldInclude) {
      continue;
    }
    let pattern = subnetPattern(iface.ip, iface.prefixLength);
    if (pattern.length > 0 && result.indexOf(pattern) < 0) {
      result.push(pattern);
    }
  }
  return result;
}

// 计算 discovery 网络白名单（读取当前配置与接口后委托纯函数）。
function computeDiscoveryWhitelist(): Array<string> {
  let whitelistedNames = getNetworkListAsArray(KEY_NETWORK_WHITELIST);
  let blacklistedNames = getNetworkListAsArray(KEY_NETWORK_BLACKLIST);
  let interfaces = getLocalInterfaces();
  let result = computeDiscoveryWhitelistFrom(
    whitelistedNames !== undefined ? whitelistedNames : [],
    blacklistedNames !== undefined ? blacklistedNames : [],
    interfaces
  );
  logger.debug(
    '接口列表: ' + interfaces.map((iface) =>
    iface.name + '(' + iface.ip + '/' + iface.prefixLength + ', ' + iface.type + ')').join(', ') +
      ' -> whitelist([' + (whitelistedNames !== undefined ? whitelistedNames.join(', ') : '') +
      ']): [' + result.join(', ') + ']');
  return result;
}

// ── 服务器运行时状态 ──

let serverRunning = false;
let serverErrorMsg: string = '';
let noWifiWarning: boolean = false;
let allInterfacesDisabled: boolean = false;
// 上一次成功启动 discovery 时的配置签名：配置未变化时跳过无谓的 stop/start 重启
let lastDiscoverySignature: string = '';

export function isServerRunning(): boolean {
  return serverRunning;
}

export function getServerError(): string {
  return serverErrorMsg;
}

export function getNoWifiWarning(): boolean {
  return noWifiWarning;
}

export function getAllInterfacesDisabled(): boolean {
  return allInterfacesDisabled;
}

export function getServerFingerprint(): string {
  return getServerFingerprintValue();
}

// Rust 服务器 save_dir（{filesDir}/HandySend/，持久目录）：
// Rust 层用于 TLS 身份持久化（identity.pem，见 localsend_ohrs/rust/bridge/identity.rs），
// 接收文件不落此处（普通文件 fd-direct 落 Download，文本消息落 cache 临时目录）。
export function getReceiveSaveDir(): string {
  let appContext = getAppContext();
  if (appContext === undefined) {
    return '';
  }
  return appContext.filesDir + '/HandySend/';
}

// 接收文本消息的 cache 临时目录（{cacheDir}/receive/，带尾斜杠）：
// 阅后即删，异常退出残留属应用缓存，可经系统存储设置清除。
export function getReceiveCacheDir(): string {
  let appContext = getAppContext();
  if (appContext === undefined) {
    return '';
  }
  return appContext.cacheDir + '/receive/';
}

// 冷启动清扫接收相关临时目录（EntryAbility.onCreate 调用，此时 AppCore
// 尚未保存应用 context，需显式传入）：
// 1. {cacheDir}/receive/：文本消息临时目录，冷启动无进行中会话，全量删除安全；
// 2. 旧版本遗留的 {filesDir}/HandySend/：曾用作接收文件落盘目录，清除其中
//    临时残留，但保留 identity.pem/identity.key（Rust TLS 身份持久化文件，
//    两者缺一即失效，见 localsend_ohrs/rust/bridge/identity.rs）。
export function cleanupReceiveCacheDirWithContext(context: common.UIAbilityContext): void {
  let cacheDir: string = context.cacheDir + '/receive/';
  try {
    let cacheNames: Array<string> = fs.listFileSync(cacheDir);
    for (let i = 0; i < cacheNames.length; i++) {
      try {
        fs.unlinkSync(cacheDir + cacheNames[i]);
      } catch (_e) {
      }
    }
  } catch (_e) {
    // 目录不存在——忽略
  }
  let legacyDir: string = context.filesDir + '/HandySend/';
  try {
    let legacyNames: Array<string> = fs.listFileSync(legacyDir);
    for (let i = 0; i < legacyNames.length; i++) {
      if (legacyNames[i] === 'identity.pem' || legacyNames[i] === 'identity.key') {
        continue;
      }
      try {
        fs.unlinkSync(legacyDir + legacyNames[i]);
      } catch (_e) {
      }
    }
  } catch (_e) {
    // 目录不存在——忽略
  }
}

// 清理接收临时目录（{cacheDir}/receive/）中的孤儿文件（无对应进行中会话的
// 残留文件，如崩溃/强杀遗留）。best-effort：单个文件删除失败不阻塞；
// fd-direct 后待消费媒体文件（相册保存弹窗仍引用）位于 Download，不落此
// 目录，跳过逻辑仅作防御。
function cleanupOrphanSandboxFiles(): void {
  let saveDir: string = getReceiveCacheDir();
  if (saveDir.length === 0) {
    return;
  }
  let skipPaths: Array<string> = getPendingRecvMediaPaths();
  try {
    let names: Array<string> = fs.listFileSync(saveDir);
    for (let i = 0; i < names.length; i++) {
      let targetPath: string = saveDir + names[i];
      let shouldSkip: boolean = false;
      for (let j = 0; j < skipPaths.length; j++) {
        if (skipPaths[j] === targetPath) {
          shouldSkip = true;
          break;
        }
      }
      if (shouldSkip) {
        continue;
      }
      try {
        fs.unlinkSync(targetPath);
      } catch (_e) {
        // 单文件删除失败——忽略，继续清理其余文件
      }
    }
  } catch (_e) {
    // 目录不存在或读取失败——忽略
  }
}

// 刷新本地网卡 + 重新计算局域网警告（由
// 在 AppService 门面中注册的网络变化监听器）。
// 两种不可发现的情况：
// 1. 没有 WiFi/以太网物理接口（noWifiWarning）
// 2. 所有接口都被用户关闭（allInterfacesDisabled）
export function refreshWifiWarning(): void {
  updateLocalInterfaces();
  let hasLan = getLocalInterfaces().some((iface: NetworkInterface) =>
  iface.type === NetworkType.wifi || iface.type === NetworkType.ethernet);
  noWifiWarning = !hasLan;
  // 检查用户是否关闭了所有接口（过滤后列表为空）
  let localInfo = getLocalDeviceInfo();
  allInterfacesDisabled = localInfo.interfaces.length === 0;
  notifyChange();
}

// 生成 discovery 配置签名：接口 IP 列表 + 白/黑名单 + 协议 + 端口 + 组播组。
// 仅在配置真正变化时才需要重启 discovery（stop + start）。
function computeDiscoverySignature(config: NativeDiscoveryConfig): string {
  let parts: Array<string> = [];
  parts.push('proto=' + config.protocol);
  parts.push('port=' + config.port);
  parts.push('group=' + config.multicastGroup);
  let whitelist = config.networkWhitelist;
  parts.push('wl=' + (whitelist !== undefined ? whitelist.join(',') : ''));
  let blacklist = config.networkBlacklist;
  parts.push('bl=' + (blacklist !== undefined ? blacklist.join(',') : ''));
  let interfaces = getLocalDeviceInfo().interfaces;
  for (let i = 0; i < interfaces.length; i++) {
    parts.push('if=' + interfaces[i].name + ':' + interfaces[i].ip);
  }
  return parts.join(';');
}

// 统一构建 discovery 配置：各启动/重启路径字段来源完全一致，仅 protocol 由调用方决定
function buildDiscoveryConfig(protocol: string): NativeDiscoveryConfig {
  return {
    port: getPort(),
    protocol: protocol,
    multicastGroup: getMulticastGroup(),
    networkWhitelist: computeDiscoveryWhitelist(),
    networkBlacklist: resolveNetworkBlacklist(),
    discoveryTimeoutMs: getDiscoveryTimeout(),
    download: true
  };
}

// 重启发现（不停 HTTP 服务器）：刷新接口列表 → 重算白/黑名单 → stop + start discovery。
// 用于网络接口变化后让组播 socket 绑定适配新接口，无需中断 HTTP 服务。
export async function restartDiscovery(): Promise<void> {
  if (!serverRunning) {
    logger.debug('服务器未运行，跳过');
    return;
  }

  logger.debug('开始重启 discovery');
  updateLocalInterfaces();
  // 确保白名单/黑名单有默认值（网络变化后可能有新接口出现）
  ensureDefaultNetworkLists(getLocalInterfaces());
  // 更新警告状态（白/黑名单变化可能影响 allInterfacesDisabled）
  let hasLan = getLocalInterfaces().some((iface: NetworkInterface) =>
  iface.type === NetworkType.wifi || iface.type === NetworkType.ethernet);
  noWifiWarning = !hasLan;
  let localInfo = getLocalDeviceInfo();
  allInterfacesDisabled = localInfo.interfaces.length === 0;

  // 先按当前配置计算签名：配置未变化时无需 stop/start（如网络监听器注册后的初始检查）
  let protocol = getHttpsEnabled() ? 'https' : 'http';
  let discoveryConfig: NativeDiscoveryConfig = buildDiscoveryConfig(protocol);
  let signature = computeDiscoverySignature(discoveryConfig);
  if (signature === lastDiscoverySignature) {
    logger.debug('配置未变化，跳过重启');
    notifyChange();
    return;
  }

  try {
    nativeDiscoverySetAnswerAnnouncements(false);
    nativeDiscoveryStop();
    // 旧的 discover_staged promise 因 stop 而失效，不会走到 finishScan()，
    // 手动清理扫描状态，避免遗留 isScanning/pendingRescan 干扰后续扫描
    resetScanState();
  } catch (_e) {
  }

  try {
    logger.debug('port=' + discoveryConfig.port +
      ' protocol=' + discoveryConfig.protocol +
      ' whitelist=' + JSON.stringify(discoveryConfig.networkWhitelist) +
      ' blacklist=' + JSON.stringify(discoveryConfig.networkBlacklist));
    await nativeStartDiscoveryV2(discoveryConfig);
    nativeDiscoverySetAnswerAnnouncements(true);
    lastDiscoverySignature = signature;
    logger.info('Discovery restarted with updated network interfaces');
  } catch (e) {
    logger.error('Discovery restart failed: ' + e);
  }

  // 立即通知 UI 更新警告状态（allInterfacesDisabled/noWifiWarning 可能已变化）
  notifyChange();
  triggerStagedDiscover();
}

// 查询原生层的实际服务器状态并同步到模块状态
function syncServerState(): boolean {
  try {
    let status = nativeGetServerStatus();
    serverRunning = status.running;
    if (status.fingerprint !== undefined && status.fingerprint.length > 0) {
      setServerFingerprint(status.fingerprint);
    }
  } catch (_e) {
    // 原生查询失败——保留当前 JS 状态
  }
  return serverRunning;
}

export async function startServer(): Promise<string> {
  // 如果原生服务器报告正在运行，先干净地停止
  try {
    let status = nativeGetServerStatus();
    if (status.running) {
      await stopLocalServer();
    }
  } catch (_e) {
  }
  return await startLocalServer();
}

export async function stopServer(): Promise<void> {
  await stopLocalServer();
  syncServerState();
}

// 进行中的重启 Promise：并发调用共享同一次重启，避免 stop/start 交错
let restartInFlight: Promise<void> | undefined = undefined;

export function restartServer(): Promise<void> {
  if (restartInFlight !== undefined) {
    return restartInFlight;
  }
  let p = doRestartServer().finally(() => {
    restartInFlight = undefined;
  });
  restartInFlight = p;
  return p;
}

async function doRestartServer(): Promise<void> {
  clearServerNeedsRestart();
  // 始终执行完整的停止 + 启动以确保状态干净
  await stopLocalServer();
  try {
    await startLocalServer();
  } catch (_e) {
    // 启动失败——同步真实状态
    syncServerState();
  }
  // 昵称变更经「重启」对 MTA 生效：同步接收对外身份（失败仅记日志，不影响重启结果）
  try {
    refreshMtaReceiveIdentity();
  } catch (e) {
    logger.warn('同步 MTA 接收对外身份失败: ' + String(e));
  }
}

// ── 服务器生命周期 ──

export async function startLocalServer(): Promise<string> {
  let appContext = getAppContext();
  if (appContext === undefined) {
    logger.error('AppService not initialized');
    return '';
  }

  // 更新本地网卡列表
  updateLocalInterfaces();
  // 首次启动时确保白名单/黑名单有默认值（wifi/ethernet 入白名单，其他入黑名单）
  ensureDefaultNetworkLists(getLocalInterfaces());
  logger.info(`Local interfaces: ${getLocalInterfaces().map(i => `${i.ip}(${i.type})`).join(', ')}`);

  // 检查局域网可用性——仅在没有 WiFi 和以太网时给出警告
  let hasLan = getLocalInterfaces().some((iface: NetworkInterface) =>
  iface.type === NetworkType.wifi || iface.type === NetworkType.ethernet);
  noWifiWarning = !hasLan;
  // 检查用户是否关闭了所有接口
  let localInfo = getLocalDeviceInfo();
  allInterfacesDisabled = localInfo.interfaces.length === 0;

  let saveDir: string = getReceiveSaveDir();
  try {
    fs.mkdirSync(saveDir);
  } catch (_e) {
  }
  // 启动时清理接收临时目录中的孤儿文件（崩溃/强杀等残留），best-effort
  cleanupOrphanSandboxFiles();
  let protocol = getHttpsEnabled() ? 'https' : 'http';
  let handle: NativeServerHandle;
  try {
    handle = await nativeCreateServer({
      alias: getDeviceAlias(),
      deviceModel: getDeviceModel(),
      deviceType: getDeviceType(),
      port: getPort(),
      saveDir: saveDir,
      useHttps: getHttpsEnabled(),
      verifyChecksums: isVerifyChecksums(),
      pin: getReceivePin().length > 0 ? getReceivePin() : undefined
    });
  } catch (e) {
    serverRunning = false;
    let errorMsg = String(e);
    // 检测端口占用错误并提供用户友好的提示
    if (errorMsg.indexOf('in use') >= 0 || errorMsg.indexOf('EADDRINUSE') >= 0 ||
      errorMsg.indexOf('Address already') >= 0) {
      let portMsg = appContext !== undefined ?
        appContext.resourceManager.getStringSync($r('app.string.port_in_use_error').id)
          .replace('%d', String(getPort())) :
        'Port ' + getPort() + ' is already in use';
      serverErrorMsg = portMsg;
      logger.error(portMsg);
    } else {
      serverErrorMsg = errorMsg;
      logger.error('Server start failed: ' + errorMsg);
    }
    return '';
  }
  // 清除之前的错误
  serverErrorMsg = '';
  setServerFingerprint(handle.fingerprint);
  serverRunning = true;
  // 服务器以当前设置运行——无需重启
  clearServerNeedsRestart();
  logger.info('Server started, fingerprint=' + handle.fingerprint.substring(0, 10) + '...');

  // 启动 Rust 核心发现
  try {
    let discoveryConfig: NativeDiscoveryConfig = buildDiscoveryConfig(protocol);
    logger.debug('start v2: port=' + discoveryConfig.port + ' protocol=' + discoveryConfig.protocol +
      ' whitelist=' + JSON.stringify(discoveryConfig.networkWhitelist) +
      ' blacklist=' + JSON.stringify(discoveryConfig.networkBlacklist));
    await nativeStartDiscoveryV2(discoveryConfig);
    nativeDiscoverySetAnswerAnnouncements(true);
    lastDiscoverySignature = computeDiscoverySignature(discoveryConfig);
    logger.info('Rust discovery started');
  } catch (e) {
    logger.error('Discovery start failed: ' + e);
  }
  // 启动扫描：discover_staged 是唯一入口
  // （内部：announce + 收藏设备探测 + 宽限期后的条件子网扫描）
  // 与 LocalSend Flutter 的 StartSmartScan 行为一致
  triggerStagedDiscover();

  // 请求轮询由 AppService 门面启动（结合服务器 +
  // 传输生命周期），以避免仓库循环依赖。
  notifyChange();
  return handle.fingerprint;
}

export async function stopLocalServer(): Promise<void> {
  // 请求轮询由 AppService 门面停止（见上文）。
  try {
    nativeDiscoverySetAnswerAnnouncements(false);
    nativeDiscoveryStop();
    resetScanState();
  } catch (_e) {
  }
  try {
    await nativeStopServer();
  } catch (e) {
    // 停止失败仍继续清理本地状态（保持两侧一致性由下次启动收口），
    // 但必须留痕：Rust 侧服务器可能仍在运行占用端口，否则无从排查
    logger.error('nativeStopServer failed: ' + String(e));
  }
  if (getShareLink().length > 0) {
    await stopShareLink();
  }
  serverRunning = false;
  setServerFingerprint('');
  serverErrorMsg = '';
  clearDiscoveryState();
  logger.info('Server stopped');
  notifyChange();
}
